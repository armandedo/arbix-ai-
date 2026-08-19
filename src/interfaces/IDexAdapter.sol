// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DEX Adapter Interface
/// @notice Standard interface for DEX swap adapters.
interface IDexAdapter {
    /// @notice Execute a token swap.
    /// @param tokenIn Token being sold.
    /// @param tokenOut Token being purchased.
    /// @param amountIn Amount of tokenIn.T
    /// @param minAmountOut Minimum acceptable tokenOut amount.
    /// @param data Adapter-specific swap parameters.
    /// @return amountOut Amount of tokenOut received.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external returns (uint256 amountOut);

    /// @notice Get an estimated swap output.
    /// @param tokenIn Token being sold.
    /// @param tokenOut Token being purchased.
    /// @param amountIn Amount of tokenIn.
    /// @param data Adapter-specific quote parameters.
    /// @return amountOut Estimated tokenOut amount.
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external view returns (uint256 amountOut);
}

