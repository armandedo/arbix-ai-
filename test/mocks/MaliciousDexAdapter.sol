// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {ArbitrageParams} from "../../src/flashloan/FlashLoanTypes.sol";
import {ReentrancyAttacker} from "./ReentrancyAttacker.sol";

interface IMockToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
}

/// @notice Malicious adapter that attempts to reenter ArbixExecutor mid-swap,
/// via the legitimate flashLoanContract caller (ReentrancyAttacker).
contract MaliciousDexAdapter is IDexAdapter {
    ReentrancyAttacker public attacker;
    ArbitrageParams private storedParams;
    bool private paramsSet;

    function setAttacker(address attacker_) external {
        attacker = ReentrancyAttacker(attacker_);
    }

    function setReentryParams(ArbitrageParams calldata params) external {
        storedParams = params;
        paramsSet = true;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 /* minAmountOut */,
        bytes calldata /* data */
    ) external override returns (uint256 amountOut) {
        IMockToken(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        if (paramsSet) {
            attacker.reenter(storedParams);
        }

        amountOut = amountIn;
        IMockToken(tokenOut).mint(address(this), amountOut);
        IMockToken(tokenOut).transfer(msg.sender, amountOut);
    }

    function quote(
        address, address, uint256 amountIn, bytes calldata
    ) external pure override returns (uint256) {
        return amountIn;
    }
}

