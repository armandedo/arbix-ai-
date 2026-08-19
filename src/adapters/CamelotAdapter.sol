// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {Errors} from "../libraries/Errors.sol";

interface ICamelotRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address referrer,
        uint256 deadline
    ) external;

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title CamelotAdapter
/// @notice IDexAdapter implementation for Camelot's DEX on Arbitrum.
/// @dev Camelot's router only exposes the fee-on-transfer-safe swap
///      variant, which does not return the output amount. This adapter
///      determines amountOut by measuring the tokenOut balance delta
///      around the swap call instead of relying on a return value.
///      `data` is ABI-encoded as (uint256 deadline) — same convention as
///      UniswapV2Adapter. No referrer is set (address(0)).
contract CamelotAdapter is IDexAdapter {
    ICamelotRouter public immutable router;

    constructor(address router_) {
        if (router_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        router = ICamelotRouter(router_);
    }

    /// @inheritdoc IDexAdapter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override returns (uint256 amountOut) {
        uint256 deadline = _decodeDeadline(data);

        if (!IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn)) {
            revert Errors.SwapFailed();
        }

        if (!IERC20(tokenIn).approve(address(router), amountIn)) {
            revert Errors.SwapFailed();
        }

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(msg.sender);

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            minAmountOut,
            path,
            msg.sender,
            address(0), // no referrer
            deadline
        );

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(msg.sender);

        if (balanceAfter <= balanceBefore) {
            revert Errors.SwapFailed();
        }

        amountOut = balanceAfter - balanceBefore;

        if (amountOut < minAmountOut) {
            revert Errors.SlippageExceeded();
        }
    }

    /// @inheritdoc IDexAdapter
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata /* data */
    ) external view override returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts = router.getAmountsOut(amountIn, path);
        amountOut = amounts[amounts.length - 1];
    }

    function _decodeDeadline(bytes calldata data) internal view returns (uint256 deadline) {
        if (data.length == 0) {
            revert Errors.DeadlineExpired();
        }

        deadline = abi.decode(data, (uint256));

        if (deadline < block.timestamp) {
            revert Errors.DeadlineExpired();
        }
    }
}

