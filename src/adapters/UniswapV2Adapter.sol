// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {Errors} from "../libraries/Errors.sol";

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract UniswapV2Adapter is IDexAdapter {
    IUniswapV2Router02 public immutable router;

    constructor(address router_) {
        if (router_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        router = IUniswapV2Router02(router_);
    }

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

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            msg.sender,
            deadline
        );

        amountOut = amounts[amounts.length - 1];

        if (amountOut < minAmountOut) {
            revert Errors.SlippageExceeded();
        }
    }

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
