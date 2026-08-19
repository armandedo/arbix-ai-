// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IArbitrageExecutor} from "../../src/interfaces/IArbitrageExecutor.sol";
import {ArbitrageParams} from "../../src/flashloan/FlashLoanTypes.sol";

interface IMockToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

contract MockArbitrageExecutor is IArbitrageExecutor {
    bool public shouldRevert;
    uint256 public executionCount;
    uint256 public profitToReturn;

    ArbitrageParams public lastParams;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setProfitToReturn(uint256 value) external {
        profitToReturn = value;
    }

    function executeArbitrage(
        ArbitrageParams calldata params
    ) external override {
        if (shouldRevert) {
            revert("Mock executor failure");
        }

        executionCount++;
        lastParams = params;

        // Simulate a profitable round-trip: mint the configured profit,
        // then return everything received to the caller (ArbixFlashLoan).
        if (profitToReturn > 0) {
            IMockToken(params.tokenIn).mint(address(this), profitToReturn);
        }

        uint256 balance = IMockToken(params.tokenIn).balanceOf(address(this));
        IMockToken(params.tokenIn).transfer(msg.sender, balance);
    }
}
