// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArbitrageParams} from "../flashloan/FlashLoanTypes.sol";

/// @title Arbitrage Executor Interface
interface IArbitrageExecutor {
    /// @notice Executes an arbitrage trade.
    /// @param params Arbitrage parameters.
    function executeArbitrage(
        ArbitrageParams calldata params
    ) external;
}