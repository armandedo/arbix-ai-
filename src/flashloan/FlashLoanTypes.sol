// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Parameters for requesting a flash loan.
struct FlashLoanParams {
    address asset;
    uint256 amount;
    bytes data;
}

/// @notice Parameters describing an arbitrage opportunity.
struct ArbitrageParams {
    address tokenIn;
    address tokenOut;

    address dexBuy;
    address dexSell;

    uint256 amountIn;
    uint256 minProfit;

    uint256 minAmountOutBuy;   // per-leg slippage floor for the buy swap
    uint256 minAmountOutSell;  // per-leg slippage floor for the sell swap

    bytes buyData;
    bytes sellData;
}
