// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Arbix Custom Errors
/// @notice Centralized custom errors used across the protocol.
library Errors {
    error ZeroAddress();
    error InvalidAmount();
    error Unauthorized();
    error FlashLoanFailed();
    error SwapFailed();
    error NoProfit();
    error InsufficientBalance();
    error UnsupportedDex();
    error InvalidRoute();
    error DeadlineExpired();
    error SlippageExceeded();
    error ContractPaused();
    error NoPendingExecutorChange();
    error TimelockNotElapsed();
    error NoPendingOwnershipTransfer();
    error NotPendingOwner();
}
