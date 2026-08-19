// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockUniswapV2Router} from "../mocks/MockUniswapV2Router.sol";

contract UniswapV2AdapterTest is Test {
    UniswapV2Adapter adapter;
    MockUniswapV2Router router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint256 constant AMOUNT_IN = 100e18;

    function setUp() public {
        router = new MockUniswapV2Router();
        adapter = new UniswapV2Adapter(address(router));
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();

        // The adapter pulls tokenIn from msg.sender via transferFrom, so this
        // test contract (acting as the caller, e.g. ArbixExecutor) needs both
        // a balance and an approval.
        tokenIn.mint(address(this), AMOUNT_IN);
        tokenIn.approve(address(adapter), AMOUNT_IN);
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    function test_Constructor_RejectsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new UniswapV2Adapter(address(0));
    }

    function test_Constructor_SetsRouter() public view {
        assertEq(address(adapter.router()), address(router));
    }

    // ---------------------------------------------------------------
    // swap() - happy path
    // ---------------------------------------------------------------

    function test_Swap_SucceedsAndReturnsCorrectAmount() public {
        router.setRate(110, 100); // 10% gain

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

    function test_Swap_PullsExactAmountInFromCaller() public {
        router.setRate(1, 1);

        uint256 deadline = block.timestamp + 300;
        bytes memory data = abi.encode(deadline);

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

    function test_Swap_SucceedsAtExactDeadline() public {
        router.setRate(1, 1);
        bytes memory data = abi.encode(block.timestamp);

        // deadline == block.timestamp should be treated as valid (not expired)
        uint256 amountOut = adapter.swap(
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            0,
            data
        );

        assertEq(amountOut, AMOUNT_IN);
    }

    // ---------------------------------------------------------------
    // swap() - slippage handling
    // ---------------------------------------------------------------

    function test_Swap_RevertsWhenRouterEnforcesSlippage() public {
        router.setRate(90, 100); // returns less than requested minimum

        uint256 deadline = block.timestamp + 300;
        bytes memory data = abi.encode(deadline);

        uint256 minAmountOut = AMOUNT_IN; // demand at least 1:1, router only gives 0.9:1

        vm.expectRevert("MockUniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, minAmountOut, data);
    }

    function test_Swap_SucceedsWhenOutputMeetsMinimum() public {
        router.setRate(100, 100); // exactly 1:1

        uint256 deadline = block.timestamp + 300;
        bytes memory data = abi.encode(deadline);

        uint256 amountOut = adapter.swap(
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            AMOUNT_IN, // minAmountOut == exact expected output
            data
        );

        assertEq(amountOut, AMOUNT_IN);
    }

    // ---------------------------------------------------------------
    // quote()
    // ---------------------------------------------------------------

    function test_Quote_ReturnsExpectedAmount() public {
        router.setRate(150, 100); // 50% gain

        uint256 quoted = adapter.quote(address(tokenIn), address(tokenOut), AMOUNT_IN, "");
        assertEq(quoted, (AMOUNT_IN * 150) / 100);
    }

    function test_Quote_DoesNotRequireData() public view {
        // quote() should work with empty data, unlike swap() which requires a deadline
        uint256 quoted = adapter.quote(address(tokenIn), address(tokenOut), AMOUNT_IN, "");
        assertEq(quoted, AMOUNT_IN); // default rate is 1:1
    }
}
