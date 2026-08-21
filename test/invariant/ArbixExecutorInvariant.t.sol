// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArbixExecutor} from "../../src/arbitrage/ArbixExecutor.sol";
import {ArbitrageParams} from "../../src/flashloan/FlashLoanTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDexAdapter} from "../mocks/MockDexAdapter.sol";

/// @notice Drives randomized executeArbitrage calls as the flash-loan
///         contract (the only address ArbixExecutor accepts calls from).
/// @dev Funding (mint) and the arbitrage attempt are wrapped in a single
///      external self-call so that a revert (e.g. NoProfit on unprofitable
///      random rates) rolls back the mint too. This mirrors production,
///      where ArbixFlashLoan funds the executor and calls it within one
///      atomic transaction — if the call reverts, so does the funding.
///      Without this, the handler would leave test-only orphaned balances
///      in the executor on every reverted attempt, producing a false
///      invariant violation that has no real-world counterpart.
contract ArbixExecutorHandler is Test {
    ArbixExecutor public executor;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockDexAdapter public buyAdapter;
    MockDexAdapter public sellAdapter;

    uint256 public callCount;
    uint256 public successCount;

    constructor(
        MockERC20 _tokenA,
        MockERC20 _tokenB,
        MockDexAdapter _buyAdapter,
        MockDexAdapter _sellAdapter
    ) {
        tokenA = _tokenA;
        tokenB = _tokenB;
        buyAdapter = _buyAdapter;
        sellAdapter = _sellAdapter;
    }

    function setExecutor(ArbixExecutor _executor) external {
        executor = _executor;
    }

    function executeArbitrage(
        uint96 amountInRaw,
        uint32 buyNum,
        uint32 buyDenom,
        uint32 sellNum,
        uint32 sellDenom
    ) public {
        callCount++;
        try this._attempt(amountInRaw, buyNum, buyDenom, sellNum, sellDenom) {
            successCount++;
        } catch {
            // Expected outcome for unprofitable random rate combinations;
            // rolls back atomically, including the funding mint below.
        }
    }

    function _attempt(
        uint96 amountInRaw,
        uint32 buyNum,
        uint32 buyDenom,
        uint32 sellNum,
        uint32 sellDenom
    ) external {
        require(msg.sender == address(this), "internal only");

        uint256 amountIn = bound(uint256(amountInRaw), 1, 1e24);
        buyDenom = uint32(bound(uint256(buyDenom), 1, 1e6));
        sellDenom = uint32(bound(uint256(sellDenom), 1, 1e6));
        buyNum = uint32(bound(uint256(buyNum), 1, 1e6));
        sellNum = uint32(bound(uint256(sellNum), 1, 1e6));

        buyAdapter.setRate(buyNum, buyDenom);
        sellAdapter.setRate(sellNum, sellDenom);

        tokenA.mint(address(executor), amountIn);

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

        executor.executeArbitrage(params);
    }
}

contract ArbixExecutorInvariantTest is Test {
    ArbixExecutor executor;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockDexAdapter buyAdapter;
    MockDexAdapter sellAdapter;
    ArbixExecutorHandler handler;

    function setUp() public {
        tokenA = new MockERC20();
        tokenB = new MockERC20();
        buyAdapter = new MockDexAdapter();
        sellAdapter = new MockDexAdapter();

        handler = new ArbixExecutorHandler(tokenA, tokenB, buyAdapter, sellAdapter);
        executor = new ArbixExecutor(address(handler));
        handler.setExecutor(executor);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.executeArbitrage.selector;
        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }

    /// @notice The executor must never hold a resting tokenIn balance
    ///         between calls — every attempt either fully sweeps funds
    ///         back to the flash-loan contract or reverts entirely.
    function invariant_ExecutorNeverHoldsTokenInAtRest() public view {
        assertEq(tokenA.balanceOf(address(executor)), 0);
    }

    /// @notice Same guarantee for the intermediate tokenOut leg.
    function invariant_ExecutorNeverHoldsTokenOutAtRest() public view {
        assertEq(tokenB.balanceOf(address(executor)), 0);
    }
}
