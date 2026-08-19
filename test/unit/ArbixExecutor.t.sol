// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArbixExecutor} from "../../src/arbitrage/ArbixExecutor.sol";
import {ArbitrageParams} from "../../src/flashloan/FlashLoanTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDexAdapter} from "../mocks/MockDexAdapter.sol";
import {MaliciousDexAdapter} from "../mocks/MaliciousDexAdapter.sol";
import {ReentrancyAttacker} from "../mocks/ReentrancyAttacker.sol";

contract ArbixExecutorTest is Test {
    ArbixExecutor executor;
    MockERC20 tokenA; // arbitrage tokenIn
    MockERC20 tokenB; // arbitrage tokenOut
    MockDexAdapter buyAdapter;
    MockDexAdapter sellAdapter;

    address stranger = address(0xBEEF);
    uint256 constant AMOUNT_IN = 100e18;

    function setUp() public {
        tokenA = new MockERC20();
        tokenB = new MockERC20();
        buyAdapter = new MockDexAdapter();
        sellAdapter = new MockDexAdapter();

        executor = new ArbixExecutor(address(this));
    }

    function _buildParams(uint256 minProfit) internal view returns (ArbitrageParams memory) {
        return ArbitrageParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexBuy: address(buyAdapter),
            dexSell: address(sellAdapter),
            amountIn: AMOUNT_IN,
            minProfit: minProfit,
            minAmountOutBuy: 0,
            minAmountOutSell: 0,
            buyData: "",
            sellData: ""
        });
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    function test_Constructor_RejectsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ArbixExecutor(address(0));
    }

    // ---------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------

    function test_ExecuteArbitrage_RevertsForUnauthorizedCaller() public {
        ArbitrageParams memory params = _buildParams(0);

        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        executor.executeArbitrage(params);
    }

    // ---------------------------------------------------------------
    // Balance checks
    // ---------------------------------------------------------------

    function test_ExecuteArbitrage_RevertsForInsufficientBalance() public {
        ArbitrageParams memory params = _buildParams(0);

        vm.expectRevert(Errors.InsufficientBalance.selector);
        executor.executeArbitrage(params);
    }

    // ---------------------------------------------------------------
    // Profit logic
    // ---------------------------------------------------------------

    function test_ExecuteArbitrage_ProfitableTrade_SweepsFundsAndEmitsEvent() public {
        buyAdapter.setRate(1, 1);
        sellAdapter.setRate(110, 100);

        tokenA.mint(address(executor), AMOUNT_IN);

        uint256 expectedProfit = AMOUNT_IN / 10;
        uint256 expectedReturn = AMOUNT_IN + expectedProfit;

        ArbitrageParams memory params = _buildParams(expectedProfit);

        vm.expectEmit(true, true, false, true);
        emit ArbixExecutor.ArbitrageExecuted(address(tokenA), address(tokenB), AMOUNT_IN, expectedProfit);

        executor.executeArbitrage(params);

        assertEq(tokenA.balanceOf(address(this)), expectedReturn);
        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenB.balanceOf(address(executor)), 0);
    }

    function test_ExecuteArbitrage_RevertsWhenProfitBelowMinimum() public {
        buyAdapter.setRate(1, 1);
        sellAdapter.setRate(110, 100);

        tokenA.mint(address(executor), AMOUNT_IN);

        ArbitrageParams memory params = _buildParams(AMOUNT_IN / 5);

        vm.expectRevert(Errors.NoProfit.selector);
        executor.executeArbitrage(params);
    }

    function test_ExecuteArbitrage_RevertsWhenTradeLosesMoney() public {
        buyAdapter.setRate(1, 1);
        sellAdapter.setRate(90, 100);

        tokenA.mint(address(executor), AMOUNT_IN);

        ArbitrageParams memory params = _buildParams(0);

        vm.expectRevert(Errors.NoProfit.selector);
        executor.executeArbitrage(params);
    }

    // ---------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------

    function test_ReentrancyGuard_BlocksReentrantCall() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker();
        ArbixExecutor reentrantExecutor = new ArbixExecutor(address(attacker));
        attacker.setExecutor(address(reentrantExecutor));

        MaliciousDexAdapter maliciousAdapter = new MaliciousDexAdapter();
        maliciousAdapter.setAttacker(address(attacker));

        ArbitrageParams memory params = ArbitrageParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexBuy: address(maliciousAdapter),
            dexSell: address(sellAdapter),
            amountIn: AMOUNT_IN,
            minProfit: 1,
            minAmountOutBuy: 0,
            minAmountOutSell: 0,
            buyData: "",
            sellData: ""
        });

        maliciousAdapter.setReentryParams(params);

        tokenA.mint(address(reentrantExecutor), AMOUNT_IN);

        vm.expectRevert(Errors.Unauthorized.selector);
        attacker.attack(params);
    }
}
