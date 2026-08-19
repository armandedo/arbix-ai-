// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMockToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
}

contract MockUniswapV2Router {
    uint256 public rateNumerator = 1;
    uint256 public rateDenominator = 1;
    bool public shouldRevertOnSwap;
    string public revertMessage = "MockUniswapV2Router: forced revert";

    function setRate(uint256 numerator, uint256 denominator) external {
        require(denominator > 0, "MockUniswapV2Router: zero denominator");
        rateNumerator = numerator;
        rateDenominator = denominator;
    }

    function setShouldRevertOnSwap(bool value) external {
        shouldRevertOnSwap = value;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        if (shouldRevertOnSwap) {
            revert(revertMessage);
        }

        require(path.length == 2, "MockUniswapV2Router: bad path");

        address tokenIn = path[0];
        address tokenOut = path[1];

        require(
            IMockToken(tokenIn).transferFrom(msg.sender, address(this), amountIn),
            "MockUniswapV2Router: pull failed"
        );

        uint256 amountOut = (amountIn * rateNumerator) / rateDenominator;
        require(amountOut >= amountOutMin, "MockUniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");

        IMockToken(tokenOut).mint(address(this), amountOut);
        require(
            IMockToken(tokenOut).transfer(to, amountOut),
            "MockUniswapV2Router: payout failed"
        );

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        require(path.length == 2, "MockUniswapV2Router: bad path");

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = (amountIn * rateNumerator) / rateDenominator;
    }
}
