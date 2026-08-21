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

    // ---------------------------------------------------------------
    // Fuzzing: profit math
    // ---------------------------------------------------------------

    /// @dev Independently recomputes the two-leg swap math using the same
    ///      floor-division formula as MockDexAdapter, then asserts the
    ///      executor's outcome (revert vs. exact swept amount) matches it
    ///      across randomized amounts and rates.
    function testFuzz_ExecuteArbitrage_ProfitMatchesCalculatedDelta(
        uint96 amountInRaw,
        uint32 buyNum,
        uint32 buyDenom,
        uint32 sellNum,
        uint32 sellDenom
    ) public {
        uint256 amountIn = bound(uint256(amountInRaw), 1, 1e24);
        buyDenom = uint32(bound(uint256(buyDenom), 1, 1e6));
        sellDenom = uint32(bound(uint256(sellDenom), 1, 1e6));
        buyNum = uint32(bound(uint256(buyNum), 1, 1e6));
        sellNum = uint32(bound(uint256(sellNum), 1, 1e6));

        buyAdapter.setRate(buyNum, buyDenom);
        sellAdapter.setRate(sellNum, sellDenom);

        tokenA.mint(address(executor), amountIn);

        uint256 tokenOutReceived = (amountIn * buyNum) / buyDenom;
        uint256 tokenInReceived = (tokenOutReceived * sellNum) / sellDenom;

        ArbitrageParams memory params = ArbitrageParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexBuy: address(buyAdapter),
            dexSell: address(sellAdapter),
            amountIn: amountIn,
            minProfit: 0,
            minAmountOutBuy: 0,
            minAmountOutSell: 0,
            buyData: "",
            sellData: ""
        });

        if (tokenInReceived <= amountIn) {
            // Break-even or losing trade: must always revert, never
            // silently sweep a non-positive "profit" back to the caller.
            vm.expectRevert(Errors.NoProfit.selector);
            executor.executeArbitrage(params);
            return;
        }

        uint256 expectedProfit = tokenInReceived - amountIn;

        executor.executeArbitrage(params);

        assertEq(tokenA.balanceOf(address(this)), amountIn + expectedProfit);
        assertEq(tokenA.balanceOf(address(executor)), 0);
        assertEq(tokenB.balanceOf(address(executor)), 0);
    }

    /// @dev Constructs a guaranteed-profitable trade, then sets minProfit
    ///      strictly above the true profit to confirm the minimum-profit
    ///      gate can't be bypassed by rounding or edge-case rates.
    function testFuzz_ExecuteArbitrage_RevertsWhenProfitBelowRequestedMinimum(
        uint96 amountInRaw,
        uint32 sellNumRaw,
        uint32 sellDenomRaw,
        uint256 minProfitRaw
    ) public {
        uint256 amountIn = bound(uint256(amountInRaw), 1e6, 1e24);
        uint256 sellDenom = bound(uint256(sellDenomRaw), 1, 1e6);
        // Bias sellNum strictly above sellDenom so the trade is profitable
        // in isolation before we force minProfit above that true profit.
        uint256 sellNum = bound(uint256(sellNumRaw), sellDenom + 1, sellDenom * 2);

        buyAdapter.setRate(1, 1);
        sellAdapter.setRate(sellNum, sellDenom);

        tokenA.mint(address(executor), amountIn);

        uint256 actualProfit = (amountIn * sellNum) / sellDenom - amountIn;
        uint256 minProfit = bound(minProfitRaw, actualProfit + 1, actualProfit + 1e24);

        ArbitrageParams memory params = ArbitrageParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexBuy: address(buyAdapter),
            dexSell: address(sellAdapter),
            amountIn: amountIn,
            minProfit: minProfit,
            minAmountOutBuy: 0,
            minAmountOutSell: 0,
            buyData: "",
            sellData: ""
        });

        vm.expectRevert(Errors.NoProfit.selector);
        executor.executeArbitrage(params);
    }
}
