// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";

interface IRealToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

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
        bytes calldata
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
        address,
        address,
        uint256 amountIn,
        bytes calldata
    ) external view override returns (uint256 amountOut) {
        return (amountIn * rateNumerator) / rateDenominator;
    }
}
