// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";

interface IMockToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

/// @notice Configurable DEX adapter mock. amountOut = amountIn * rateNumerator / rateDenominator.
contract MockDexAdapter is IDexAdapter {
    uint256 public rateNumerator = 1;
    uint256 public rateDenominator = 1;

    function setRate(uint256 numerator, uint256 denominator) external {
        require(denominator > 0, "MockDexAdapter: zero denominator");
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
            IMockToken(tokenIn).transferFrom(msg.sender, address(this), amountIn),
            "MockDexAdapter: pull failed"
        );

        amountOut = (amountIn * rateNumerator) / rateDenominator;
        require(amountOut >= minAmountOut, "MockDexAdapter: slippage");

        IMockToken(tokenOut).mint(address(this), amountOut);
        require(
            IMockToken(tokenOut).transfer(msg.sender, amountOut),
            "MockDexAdapter: payout failed"
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
