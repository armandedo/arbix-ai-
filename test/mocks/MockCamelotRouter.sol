// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMockToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
}

/// @notice Mock of Camelot's router. Mirrors the real router's lack of a
/// return value on the fee-on-transfer-safe swap function, and its extra
/// `referrer` parameter.
contract MockCamelotRouter {
    uint256 public rateNumerator = 1;
    uint256 public rateDenominator = 1;
    bool public shouldRevertOnSwap;

    function setRate(uint256 numerator, uint256 denominator) external {
        require(denominator > 0, "MockCamelotRouter: zero denominator");
        rateNumerator = numerator;
        rateDenominator = denominator;
    }

    function setShouldRevertOnSwap(bool value) external {
        shouldRevertOnSwap = value;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address /* referrer */,
        uint256 /* deadline */
    ) external {
        if (shouldRevertOnSwap) {
            revert("MockCamelotRouter: forced revert");
        }

        require(path.length == 2, "MockCamelotRouter: bad path");

        address tokenIn = path[0];
        address tokenOut = path[1];

        require(
            IMockToken(tokenIn).transferFrom(msg.sender, address(this), amountIn),
            "MockCamelotRouter: pull failed"
        );

        uint256 amountOut = (amountIn * rateNumerator) / rateDenominator;
        require(amountOut >= amountOutMin, "MockCamelotRouter: INSUFFICIENT_OUTPUT_AMOUNT");

        IMockToken(tokenOut).mint(address(this), amountOut);
        require(
            IMockToken(tokenOut).transfer(to, amountOut),
            "MockCamelotRouter: payout failed"
        );
        // Deliberately no return value, matching the real router.
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        require(path.length == 2, "MockCamelotRouter: bad path");

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = (amountIn * rateNumerator) / rateDenominator;
    }
}

