// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";

interface IRealToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Simulates a second liquidity venue with a better price than the
/// primary DEX, representing a genuine cross-DEX arbitrage opportunity.
/// Pays out from a real, pre-funded token balance (via the `deal` cheat in
/// tests) rather than minting, so it works against real mainnet-fork tokens.
contract SyntheticDexAdapter is IDexAdapter {
    uint256 public rateNumerator = 1;
    uint256 public rateDenominator = 1;

    function setRate(uint256 numerator, uint256 denominator) external {
        require(denominator > 0, "SyntheticDexAdapter: zero denominator");
        rateNumerator = numerator;
        rateDenominator = denominator;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata /* data */
    ) external override returns (uint256 amountOut) {
        require(
            IRealToken(tokenIn).transferFrom(msg.sender, address(this), amountIn),
            "SyntheticDexAdapter: pull failed"
        );

        amountOut = (amountIn * rateNumerator) / rateDenominator;
        require(amountOut >= minAmountOut, "SyntheticDexAdapter: slippage");

        require(
            IRealToken(tokenOut).transfer(msg.sender, amountOut),
            "SyntheticDexAdapter: payout failed"
        );
    }

    function quote(
        address /* tokenIn */,
        address /* tokenOut */,
        uint256 amountIn,
        bytes calldata /* data */
    ) external view override returns (uint256 amountOut) {
        return (amountIn * rateNumerator) / rateDenominator;
    }
}