// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IArbitrageExecutor} from "../interfaces/IArbitrageExecutor.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {ArbitrageParams} from "../flashloan/FlashLoanTypes.sol";
import {Errors} from "../libraries/Errors.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title ArbixExecutor
/// @notice Executes a two-leg arbitrage (buy then sell) and enforces a minimum profit
///         before returning funds to the flash-loan contract.
/// @dev Fee-on-transfer tokens are NOT explicitly supported. tokenIn transfers
///      that deduct a fee will correctly revert via the balanceBefore check
///      below, since the executor won't receive the full amountIn. However,
///      tokenOut fee-on-transfer behavior during the buy/sell legs is only
///      safe when using an adapter (like CamelotAdapter) that measures actual
///      balance deltas rather than trusting router return values. Do not
///      route arbitrage through tokens known to charge transfer fees without
///      first auditing each adapter's specific handling.
contract ArbixExecutor is IArbitrageExecutor {
    address public immutable flashLoanContract;

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private reentrancyStatus = NOT_ENTERED;

    event ArbitrageExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 profit
    );

    modifier onlyFlashLoanContract() {
        if (msg.sender != flashLoanContract) {
            revert Errors.Unauthorized();
        }
        _;
    }

    modifier nonReentrant() {
        if (reentrancyStatus == ENTERED) {
            revert Errors.Unauthorized();
        }
        reentrancyStatus = ENTERED;
        _;
        reentrancyStatus = NOT_ENTERED;
    }

    constructor(address flashLoanContract_) {
        if (flashLoanContract_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        flashLoanContract = flashLoanContract_;
    }

    /// @inheritdoc IArbitrageExecutor
    function executeArbitrage(
        ArbitrageParams calldata params
    ) external override onlyFlashLoanContract nonReentrant {
        IERC20 tokenIn = IERC20(params.tokenIn);

        uint256 balanceBefore = tokenIn.balanceOf(address(this));

        if (balanceBefore < params.amountIn) {
            revert Errors.InsufficientBalance();
        }

        // Leg 1: buy tokenOut using tokenIn.
        if (!IERC20(params.tokenIn).approve(params.dexBuy, params.amountIn)) {
            revert Errors.SwapFailed();
        }

        uint256 tokenOutReceived = IDexAdapter(params.dexBuy).swap(
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            params.minAmountOutBuy,
            params.buyData
        );

        // Leg 2: sell tokenOut back into tokenIn.
        if (!IERC20(params.tokenOut).approve(params.dexSell, tokenOutReceived)) {
            revert Errors.SwapFailed();
        }

        IDexAdapter(params.dexSell).swap(
            params.tokenOut,
            params.tokenIn,
            tokenOutReceived,
            params.minAmountOutSell,
            params.sellData
        );

        uint256 balanceAfter = tokenIn.balanceOf(address(this));

        if (balanceAfter <= balanceBefore) {
            revert Errors.NoProfit();
        }

        uint256 profit = balanceAfter - balanceBefore;

        if (profit < params.minProfit) {
            revert Errors.NoProfit();
        }

        // Sweep everything back to the flash-loan contract. The executor
        // never holds a balance at rest.
        if (!tokenIn.transfer(flashLoanContract, balanceAfter)) {
            revert Errors.FlashLoanFailed();
        }

        emit ArbitrageExecuted(params.tokenIn, params.tokenOut, params.amountIn, profit);
    }
}
