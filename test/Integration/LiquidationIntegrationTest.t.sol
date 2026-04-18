// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Corn} from "../../src/Corn.sol";
import {CornDEX} from "../../src/CornDEX.sol";
import {
    IFlashLoanRecipient,
    Lending,
    Lending__NotLiquidatable,
    Lending__UnsafePositionRatio
} from "../../src/Lending.sol";
import {FlashLoanLiquidator} from "../../src/FlashLoanLiquidator.sol";
import {MovePrice} from "../../src/MovePrice.sol";

contract LiquidationIntegrationTest is Test {
    uint256 internal constant INITIAL_DEX_ETH = 1_000 ether;
    uint256 internal constant INITIAL_DEX_CORN = 1_000_000 ether;
    uint256 internal constant INITIAL_LENDING_CORN = 1_000_000 ether;
    uint256 internal constant COLLATERAL_AMOUNT = 10 ether;
    uint256 internal constant BORROW_AMOUNT = 5_000 ether;
    uint256 internal constant PRICE_MOVE_SIZE = 450 ether;

    Corn internal corn;
    CornDEX internal cornDex;
    Lending internal lending;

    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");
    address internal secondaryUser = makeAddr("secondaryUser");

    function setUp() public {
        vm.deal(address(this), 20_000 ether);
        vm.deal(borrower, 100 ether);
        vm.deal(liquidator, 100 ether);
        vm.deal(secondaryUser, 100 ether);

        corn = new Corn();
        cornDex = new CornDEX(address(corn));
        lending = new Lending(address(cornDex), address(corn));

        corn.mintTo(address(this), INITIAL_DEX_CORN);
        corn.approve(address(cornDex), INITIAL_DEX_CORN);
        cornDex.init{value: INITIAL_DEX_ETH}(INITIAL_DEX_CORN);

        corn.mintTo(address(lending), INITIAL_LENDING_CORN);
    }

    function _openPosition(address user, uint256 collateralAmount, uint256 borrowAmount) internal {
        vm.startPrank(user);
        lending.addCollateral{value: collateralAmount}();
        lending.borrowCorn(borrowAmount);
        vm.stopPrank();
    }

    function _crashEthPrice() internal returns (MovePrice movePrice, uint256 priceBeforeCrash) {
        movePrice = new MovePrice(address(cornDex), address(corn));
        vm.deal(address(movePrice), PRICE_MOVE_SIZE);
        corn.mintTo(address(movePrice), 50_000 ether);

        priceBeforeCrash = cornDex.currentPrice();
        movePrice.movePrice(int256(PRICE_MOVE_SIZE));
    }

    function _startGracePeriod(address user) internal {
        vm.prank(liquidator);
        lending.liquidate(user);
    }

    function _enableWorkingFlashLoanLiquidator() internal returns (FlashLoanLiquidator flashLoanLiquidator) {
        corn.transferOwnership(address(lending));
        flashLoanLiquidator = new FlashLoanLiquidator(address(lending), address(cornDex), address(corn));
        vm.deal(address(flashLoanLiquidator), 2 ether);
    }

    function testMovePriceUsesMovePriceToCrashEthPrice() public {
        _openPosition(borrower, COLLATERAL_AMOUNT, BORROW_AMOUNT);

        (, uint256 priceBeforeCrash) = _crashEthPrice();

        assertLt(cornDex.currentPrice(), priceBeforeCrash);
        assertTrue(lending.isLiquidatable(borrower));
        assertLt(lending.getUserHealthFactor(borrower), 1 ether);
    }

    function testFlashLoanLiquidatorFailsOnLiquidatingImmediately() public {
        _openPosition(borrower, COLLATERAL_AMOUNT, BORROW_AMOUNT);
        _crashEthPrice();
        _startGracePeriod(borrower);

        FlashLoanLiquidator flashLoanLiquidator = _enableWorkingFlashLoanLiquidator();

        uint256 borrowerDebtBefore = lending.s_userBorrowed(borrower);
        uint256 borrowerCollateralBefore = lending.s_userCollateral(borrower);
        uint256 liquidatorBalanceBefore = liquidator.balance;

        vm.prank(liquidator);
        vm.expectRevert(Lending__NotLiquidatable.selector);
        lending.flashLoan(IFlashLoanRecipient(address(flashLoanLiquidator)), BORROW_AMOUNT, borrower);

        assertEq(lending.s_userBorrowed(borrower), borrowerDebtBefore);
        assertEq(lending.s_userCollateral(borrower), borrowerCollateralBefore);
        assertEq(corn.balanceOf(address(flashLoanLiquidator)), 0);
        assertEq(address(flashLoanLiquidator).balance, 2 ether);
        assertEq(liquidator.balance, liquidatorBalanceBefore);
    }

    function testFlashLoanLiquidatorWorksAfterTwentyFiveHours() public {
        _openPosition(borrower, COLLATERAL_AMOUNT, BORROW_AMOUNT);
        _crashEthPrice();
        _startGracePeriod(borrower);

        FlashLoanLiquidator flashLoanLiquidator = _enableWorkingFlashLoanLiquidator();

        uint256 borrowerCollateralBefore = lending.s_userCollateral(borrower);
        uint256 liquidatorBalanceBefore = liquidator.balance;

        vm.warp(block.timestamp + 25 hours);

        vm.prank(liquidator);
        lending.flashLoan(IFlashLoanRecipient(address(flashLoanLiquidator)), BORROW_AMOUNT, borrower);

        assertEq(lending.s_userBorrowed(borrower), 0);
        assertLt(lending.s_userCollateral(borrower), borrowerCollateralBefore);
        assertEq(corn.balanceOf(address(flashLoanLiquidator)), 0);
        assertEq(address(flashLoanLiquidator).balance, 0);
        assertGt(liquidator.balance, liquidatorBalanceBefore);
    }

    function testHandle18DecimalPrecisionCorrectlyWhenComparingEthAndCorn() public {
        vm.prank(borrower);
        lending.addCollateral{value: COLLATERAL_AMOUNT}();

        uint256 maxBorrowAmount = lending.getMaxBorrowAmount(COLLATERAL_AMOUNT);

        vm.prank(borrower);
        lending.borrowCorn(maxBorrowAmount);

        assertFalse(lending.isLiquidatable(borrower));
        assertEq(
            lending.getUserHealthFactor(borrower),
            (lending.calculateCollateralValue(borrower) * 1 ether) / maxBorrowAmount
        );

        vm.prank(secondaryUser);
        lending.addCollateral{value: COLLATERAL_AMOUNT}();

        vm.prank(secondaryUser);
        vm.expectRevert(Lending__UnsafePositionRatio.selector);
        lending.borrowCorn(maxBorrowAmount + 1);
    }

    function testTwentyFourHourClockResetsCorrectlyWhenUserAddsCollateral() public {
        _openPosition(borrower, COLLATERAL_AMOUNT, BORROW_AMOUNT);
        _crashEthPrice();
        _startGracePeriod(borrower);

        uint256 firstGracePeriodTimestamp = lending.lastLowHealthFactorTimestamp(borrower);
        assertGt(firstGracePeriodTimestamp, 0);

        vm.warp(block.timestamp + 1 hours);

        vm.prank(borrower);
        lending.addCollateral{value: 3 ether}();

        assertEq(lending.lastLowHealthFactorTimestamp(borrower), 0);
        assertFalse(lending.isLiquidatable(borrower));

        cornDex.swap{value: 200 ether}(200 ether);

        vm.prank(liquidator);
        lending.liquidate(borrower);

        assertGt(lending.lastLowHealthFactorTimestamp(borrower), firstGracePeriodTimestamp);

        vm.warp(block.timestamp + 24 hours - 1);

        vm.prank(liquidator);
        vm.expectRevert(Lending__NotLiquidatable.selector);
        lending.liquidate(borrower);
    }
}
