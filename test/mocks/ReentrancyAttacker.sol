// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IArbitrageExecutor} from "../../src/interfaces/IArbitrageExecutor.sol";
import {ArbitrageParams} from "../../src/flashloan/FlashLoanTypes.sol";

/// @notice Stands in as the `flashLoanContract` for a dedicated ArbixExecutor
/// instance. Used only to prove the executor's reentrancy guard works even
/// when the reentrant call comes from the legitimate authorized caller.
contract ReentrancyAttacker {
    IArbitrageExecutor public executor;
    bool public reentered;

    function setExecutor(address executor_) external {
        executor = IArbitrageExecutor(executor_);
    }

    function attack(ArbitrageParams calldata params) external {
        executor.executeArbitrage(params);
    }

    /// @dev Called by MaliciousDexAdapter mid-swap to attempt a reentrant call.
    function reenter(ArbitrageParams calldata params) external {
        reentered = true;
        executor.executeArbitrage(params);
    }
}
