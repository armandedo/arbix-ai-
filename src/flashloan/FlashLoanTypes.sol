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

    bytes buyData;
    bytes sellData;
}