// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CamelotAdapter} from "../../src/adapters/CamelotAdapter.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockCamelotRouter} from "../mocks/MockCamelotRouter.sol";

contract CamelotAdapterTest is Test {
    CamelotAdapter adapter;
    MockCamelotRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint256 constant AMOUNT_IN = 100e18;

    function setUp() public {
        router = new MockCamelotRouter();
        adapter = new CamelotAdapter(address(router));
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();

        tokenIn.mint(address(this), AMOUNT_IN);
        tokenIn.approve(address(adapter), AMOUNT_IN);
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    function test_Constructor_RejectsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CamelotAdapter(address(0));
    }

    function test_Constructor_SetsRouter() public view {
        assertEq(address(adapter.router()), address(router));
    }

    // ---------------------------------------------------------------
    // swap() - happy path, including the no-return-value quirk
    // ---------------------------------------------------------------

    function test_Swap_SucceedsAndReturnsCorrectAmount() public {
        router.setRate(110, 100);

        uint256 deadline = block.timestamp + 300;
        bytes memory data = abi.encode(deadline);

        uint256 amountOut = adapter.swap(
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            0,
            data
        );

        uint256 expectedOut = (AMOUNT_IN * 110) / 100;
        assertEq(amountOut, expectedOut);
        assertEq(tokenOut.balanceOf(address(this)), expectedOut);
        assertEq(tokenIn.balanceOf(address(this)), 0);
    }

    function test_Swap_DerivesAmountOutFromBalanceDelta() public {
        // Pre-fund the caller with some tokenOut before the swap, to prove
        // the adapter measures the *delta*, not the absolute balance.
        tokenOut.mint(address(this), 500e18);

        router.setRate(1, 1);
        bytes memory data = abi.encode(block.timestamp + 300);

        uint256 amountOut = adapter.swap(
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            0,
            data
        );

        assertEq(amountOut, AMOUNT_IN);
        assertEq(tokenOut.balanceOf(address(this)), 500e18 + AMOUNT_IN);
    }

    function test_Swap_PullsExactAmountInFromCaller() public {
        router.setRate(1, 1);
        bytes memory data = abi.encode(block.timestamp + 300);

        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 0, data);

        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenIn.balanceOf(address(router)), AMOUNT_IN);
    }

    // ---------------------------------------------------------------
    // swap() - deadline handling
    // ---------------------------------------------------------------

    function test_Swap_RevertsForEmptyData() public {
        vm.expectRevert(Errors.DeadlineExpired.selector);
        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 0, "");
    }

    function test_Swap_RevertsForExpiredDeadline() public {
        vm.warp(1_000_000);
        uint256 pastDeadline = block.timestamp - 1;
        bytes memory data = abi.encode(pastDeadline);

        vm.expectRevert(Errors.DeadlineExpired.selector);
        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 0, data);
    }

    // ---------------------------------------------------------------
    // swap() - slippage handling
    // ---------------------------------------------------------------

    function test_Swap_RevertsWhenRouterEnforcesSlippage() public {
        router.setRate(90, 100);

        bytes memory data = abi.encode(block.timestamp + 300);
        uint256 minAmountOut = AMOUNT_IN;

        vm.expectRevert("MockCamelotRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, minAmountOut, data);
    }

    function test_Swap_SucceedsWhenOutputMeetsMinimum() public {
        router.setRate(100, 100);

        bytes memory data = abi.encode(block.timestamp + 300);

        uint256 amountOut = adapter.swap(
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            AMOUNT_IN,
            data
        );

        assertEq(amountOut, AMOUNT_IN);
    }

    // ---------------------------------------------------------------
    // quote()
    // ---------------------------------------------------------------

    function test_Quote_ReturnsExpectedAmount() public {
        router.setRate(150, 100);

        uint256 quoted = adapter.quote(address(tokenIn), address(tokenOut), AMOUNT_IN, "");
        assertEq(quoted, (AMOUNT_IN * 150) / 100);
    }

    function test_Quote_DoesNotRequireData() public view {
        uint256 quoted = adapter.quote(address(tokenIn), address(tokenOut), AMOUNT_IN, "");
        assertEq(quoted, AMOUNT_IN);
    }
}

