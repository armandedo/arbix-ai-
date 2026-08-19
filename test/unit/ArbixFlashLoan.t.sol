// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArbixFlashLoan} from "../../src/flashloan/ArbixFlashLoan.sol";
import {FlashLoanParams, ArbitrageParams} from "../../src/flashloan/FlashLoanTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockArbitrageExecutor} from "../mocks/MockArbitrageExecutor.sol";

contract ArbixFlashLoanTest is Test {
    ArbixFlashLoan flashLoan;
    MockAavePool pool;
    MockERC20 token;
    MockArbitrageExecutor executor;

    address owner = address(this);
    address stranger = address(0xBEEF);

    function setUp() public {
        pool = new MockAavePool();
        token = new MockERC20();
        executor = new MockArbitrageExecutor();

        flashLoan = new ArbixFlashLoan(address(pool), address(executor));
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    function test_Constructor_RejectsZeroPool() public {
        vm.expectRevert("Invalid pool");
        new ArbixFlashLoan(address(0), address(executor));
    }

    function test_Constructor_RejectsZeroExecutor() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ArbixFlashLoan(address(pool), address(0));
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(flashLoan.owner(), owner);
    }

    function test_Constructor_SetsPool() public view {
        assertEq(address(flashLoan.POOL()), address(pool));
    }

    function test_Constructor_SetsExecutor() public view {
        assertEq(address(flashLoan.executor()), address(executor));
    }

    // ---------------------------------------------------------------
    // requestFlashLoan
    // ---------------------------------------------------------------

    function test_RequestFlashLoan_RevertsForNonOwner() public {
        FlashLoanParams memory params = FlashLoanParams({
            asset: address(token),
            amount: 1000,
            data: ""
        });

        vm.prank(stranger);
        vm.expectRevert("Not owner");
        flashLoan.requestFlashLoan(params);
    }

    function test_RequestFlashLoan_RevertsForZeroAsset() public {
        FlashLoanParams memory params = FlashLoanParams({
            asset: address(0),
            amount: 1000,
            data: ""
        });

        vm.expectRevert(Errors.ZeroAddress.selector);
        flashLoan.requestFlashLoan(params);
    }

    function test_RequestFlashLoan_RevertsForZeroAmount() public {
        FlashLoanParams memory params = FlashLoanParams({
            asset: address(token),
            amount: 0,
            data: ""
        });

        vm.expectRevert(Errors.InvalidAmount.selector);
        flashLoan.requestFlashLoan(params);
    }

    function test_RequestFlashLoan_EmitsEvent() public {
        uint256 amount = 1000;
        ArbitrageParams memory arbParams = _buildArbParams(amount);
        bytes memory data = abi.encode(arbParams);

        FlashLoanParams memory params = FlashLoanParams({
            asset: address(token),
            amount: amount,
            data: data
        });

        vm.expectEmit(true, false, false, true);
        emit ArbixFlashLoan.FlashLoanRequested(address(token), amount);

        flashLoan.requestFlashLoan(params);
    }

    // ---------------------------------------------------------------
    // executeOperation
    // ---------------------------------------------------------------

    function test_ExecuteOperation_RevertsForUnauthorizedCaller() public {
        ArbitrageParams memory arbParams = _buildArbParams(1000);
        bytes memory data = abi.encode(arbParams);

        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        flashLoan.executeOperation(address(token), 1000, 9, address(flashLoan), data);
    }

    function test_ExecuteOperation_RevertsForWrongInitiator() public {
        ArbitrageParams memory arbParams = _buildArbParams(1000);
        bytes memory data = abi.encode(arbParams);

        vm.prank(address(pool));
        vm.expectRevert(Errors.Unauthorized.selector);
        flashLoan.executeOperation(address(token), 1000, 9, stranger, data);
    }

    // ---------------------------------------------------------------
    // Full integration: requestFlashLoan -> pool -> executeOperation -> executor
    // ---------------------------------------------------------------

    function test_Integration_FullFlashLoanFlow() public {
        uint256 loanAmount = 1_000e18;
        ArbitrageParams memory arbParams = _buildArbParams(loanAmount);
        bytes memory data = abi.encode(arbParams);

        uint256 expectedPremium = (loanAmount * pool.premiumBps()) / 10_000;

        executor.setProfitToReturn(expectedPremium);

        FlashLoanParams memory params = FlashLoanParams({
            asset: address(token),
            amount: loanAmount,
            data: data
        });

        flashLoan.requestFlashLoan(params);

        assertEq(executor.executionCount(), 1);

        (address tokenIn, , , , uint256 amountIn, , , , , ) = executor.lastParams();
        assertEq(tokenIn, arbParams.tokenIn);
        assertEq(amountIn, arbParams.amountIn);

        assertEq(token.balanceOf(address(flashLoan)), 0);
    }

    function test_Integration_RevertsWhenExecutorFails() public {
        executor.setShouldRevert(true);

        uint256 loanAmount = 1_000e18;
        ArbitrageParams memory arbParams = _buildArbParams(loanAmount);
        bytes memory data = abi.encode(arbParams);

        FlashLoanParams memory params = FlashLoanParams({
            asset: address(token),
            amount: loanAmount,
            data: data
        });

        vm.expectRevert("Mock executor failure");
        flashLoan.requestFlashLoan(params);
    }

    // ---------------------------------------------------------------
    // withdrawProfit
    // ---------------------------------------------------------------

    function test_WithdrawProfit_RevertsForNonOwner() public {
        token.mint(address(flashLoan), 1000);

        vm.prank(stranger);
        vm.expectRevert("Not owner");
        flashLoan.withdrawProfit(address(token), stranger, 1000);
    }

    function test_WithdrawProfit_RevertsForZeroAsset() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        flashLoan.withdrawProfit(address(0), owner, 1000);
    }

    function test_WithdrawProfit_RevertsForZeroRecipient() public {
        token.mint(address(flashLoan), 1000);

        vm.expectRevert(Errors.ZeroAddress.selector);
        flashLoan.withdrawProfit(address(token), address(0), 1000);
    }

    function test_WithdrawProfit_RevertsForZeroAmount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        flashLoan.withdrawProfit(address(token), owner, 0);
    }

    function test_WithdrawProfit_RevertsForInsufficientBalance() public {
        vm.expectRevert(Errors.InsufficientBalance.selector);
        flashLoan.withdrawProfit(address(token), owner, 1000);
    }

    function test_WithdrawProfit_SucceedsAndEmitsEvent() public {
        token.mint(address(flashLoan), 1000);

        vm.expectEmit(true, true, false, true);
        emit ArbixFlashLoan.ProfitWithdrawn(address(token), owner, 1000);

        flashLoan.withdrawProfit(address(token), owner, 1000);

        assertEq(token.balanceOf(owner), 1000);
        assertEq(token.balanceOf(address(flashLoan)), 0);
    }

    function test_WithdrawProfit_CanSendToArbitraryAddress() public {
        token.mint(address(flashLoan), 500);

        address treasury = address(0xCAFE);
        flashLoan.withdrawProfit(address(token), treasury, 500);

        assertEq(token.balanceOf(treasury), 500);
    }

    // ---------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------

    function test_SetPaused_RevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        flashLoan.setPaused(true);
    }

    function test_SetPaused_BlocksRequestFlashLoan() public {
        flashLoan.setPaused(true);

        FlashLoanParams memory params = FlashLoanParams({
            asset: address(token),
            amount: 1000,
            data: ""
        });

        vm.expectRevert(Errors.ContractPaused.selector);
        flashLoan.requestFlashLoan(params);
    }

    function test_SetPaused_DoesNotBlockWithdrawProfit() public {
        token.mint(address(flashLoan), 1000);
        flashLoan.setPaused(true);

        flashLoan.withdrawProfit(address(token), owner, 1000);
        assertEq(token.balanceOf(owner), 1000);
    }

    function test_SetPaused_UnpausingAllowsRequestsAgain() public {
        flashLoan.setPaused(true);
        flashLoan.setPaused(false);

        uint256 amount = 1000;
        ArbitrageParams memory arbParams = _buildArbParams(amount);
        FlashLoanParams memory params = FlashLoanParams({
            asset: address(token),
            amount: amount,
            data: abi.encode(arbParams)
        });

        flashLoan.requestFlashLoan(params); // should not revert
    }

    // ---------------------------------------------------------------
    // Timelocked executor replacement
    // ---------------------------------------------------------------

    function test_ProposeExecutorChange_RevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        flashLoan.proposeExecutorChange(address(0xCAFE));
    }

    function test_ProposeExecutorChange_RevertsForZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        flashLoan.proposeExecutorChange(address(0));
    }

    function test_ProposeExecutorChange_SetsPendingStateAndUnlockTime() public {
        address newExecutor = address(0xCAFE);
        flashLoan.proposeExecutorChange(newExecutor);

        assertEq(flashLoan.pendingExecutor(), newExecutor);
        assertEq(flashLoan.executorChangeUnlockTime(), block.timestamp + flashLoan.EXECUTOR_CHANGE_DELAY());
    }

    function test_ExecuteExecutorChange_RevertsWithNoPendingChange() public {
        vm.expectRevert(Errors.NoPendingExecutorChange.selector);
        flashLoan.executeExecutorChange();
    }

    function test_ExecuteExecutorChange_RevertsBeforeTimelockElapses() public {
        address newExecutor = address(0xCAFE);
        flashLoan.proposeExecutorChange(newExecutor);

        vm.expectRevert(Errors.TimelockNotElapsed.selector);
        flashLoan.executeExecutorChange();
    }

    function test_ExecuteExecutorChange_SucceedsAfterTimelockElapses() public {
        address newExecutor = address(0xCAFE);
        flashLoan.proposeExecutorChange(newExecutor);

        vm.warp(block.timestamp + flashLoan.EXECUTOR_CHANGE_DELAY());

        flashLoan.executeExecutorChange();

        assertEq(address(flashLoan.executor()), newExecutor);
        assertEq(flashLoan.pendingExecutor(), address(0));
        assertEq(flashLoan.executorChangeUnlockTime(), 0);
    }

    function test_CancelExecutorChange_RevertsWithNoPendingChange() public {
        vm.expectRevert(Errors.NoPendingExecutorChange.selector);
        flashLoan.cancelExecutorChange();
    }

    function test_CancelExecutorChange_ClearsPendingState() public {
        flashLoan.proposeExecutorChange(address(0xCAFE));
        flashLoan.cancelExecutorChange();

        assertEq(flashLoan.pendingExecutor(), address(0));
        assertEq(flashLoan.executorChangeUnlockTime(), 0);

        assertEq(address(flashLoan.executor()), address(executor));
    }

    function test_ExecuteExecutorChange_RevertsForNonOwner() public {
        flashLoan.proposeExecutorChange(address(0xCAFE));
        vm.warp(block.timestamp + flashLoan.EXECUTOR_CHANGE_DELAY());

        vm.prank(stranger);
        vm.expectRevert("Not owner");
        flashLoan.executeExecutorChange();
    }

    // ---------------------------------------------------------------
    // Two-step ownership transfer
    // ---------------------------------------------------------------

    function test_ProposeOwnershipTransfer_RevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        flashLoan.proposeOwnershipTransfer(address(0xCAFE));
    }

    function test_ProposeOwnershipTransfer_RevertsForZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        flashLoan.proposeOwnershipTransfer(address(0));
    }

    function test_ProposeOwnershipTransfer_SetsPendingOwner() public {
        address newOwner = address(0xCAFE);
        flashLoan.proposeOwnershipTransfer(newOwner);

        assertEq(flashLoan.pendingOwner(), newOwner);
        assertEq(flashLoan.owner(), owner);
    }

    function test_AcceptOwnershipTransfer_RevertsWithNoPendingTransfer() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert(Errors.NoPendingOwnershipTransfer.selector);
        flashLoan.acceptOwnershipTransfer();
    }

    function test_AcceptOwnershipTransfer_RevertsForWrongCaller() public {
        address newOwner = address(0xCAFE);
        flashLoan.proposeOwnershipTransfer(newOwner);

        vm.prank(stranger);
        vm.expectRevert(Errors.NotPendingOwner.selector);
        flashLoan.acceptOwnershipTransfer();
    }

    function test_AcceptOwnershipTransfer_SucceedsAndTransfersOwnership() public {
        address newOwner = address(0xCAFE);
        flashLoan.proposeOwnershipTransfer(newOwner);

        vm.prank(newOwner);
        flashLoan.acceptOwnershipTransfer();

        assertEq(flashLoan.owner(), newOwner);
        assertEq(flashLoan.pendingOwner(), address(0));
    }

    function test_AcceptOwnershipTransfer_OldOwnerLosesAccess() public {
        address newOwner = address(0xCAFE);
        flashLoan.proposeOwnershipTransfer(newOwner);

        vm.prank(newOwner);
        flashLoan.acceptOwnershipTransfer();

        vm.expectRevert("Not owner");
        flashLoan.setPaused(true);
    }

    function test_AcceptOwnershipTransfer_NewOwnerCanUseAdminFunctions() public {
        address newOwner = address(0xCAFE);
        flashLoan.proposeOwnershipTransfer(newOwner);

        vm.prank(newOwner);
        flashLoan.acceptOwnershipTransfer();

        vm.prank(newOwner);
        flashLoan.setPaused(true);
        assertTrue(flashLoan.paused());
    }

    function test_CancelOwnershipTransfer_RevertsForNonOwner() public {
        flashLoan.proposeOwnershipTransfer(address(0xCAFE));

        vm.prank(stranger);
        vm.expectRevert("Not owner");
        flashLoan.cancelOwnershipTransfer();
    }

    function test_CancelOwnershipTransfer_RevertsWithNoPendingTransfer() public {
        vm.expectRevert(Errors.NoPendingOwnershipTransfer.selector);
        flashLoan.cancelOwnershipTransfer();
    }

    function test_CancelOwnershipTransfer_ClearsPendingOwnerAndBlocksAcceptance() public {
        address proposedOwner = address(0xCAFE);
        flashLoan.proposeOwnershipTransfer(proposedOwner);
        flashLoan.cancelOwnershipTransfer();

        assertEq(flashLoan.pendingOwner(), address(0));

        vm.prank(proposedOwner);
        vm.expectRevert(Errors.NoPendingOwnershipTransfer.selector);
        flashLoan.acceptOwnershipTransfer();
    }

    function test_TypoAddress_CannotAcceptAndOwnershipRemainsSafe() public {
        address typoAddress = address(0xDEAD);
        flashLoan.proposeOwnershipTransfer(typoAddress);

        flashLoan.setPaused(true);
        assertTrue(flashLoan.paused());
        assertEq(flashLoan.owner(), owner);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _buildArbParams(uint256 amountIn) internal view returns (ArbitrageParams memory) {
        return ArbitrageParams({
            tokenIn: address(token),
            tokenOut: address(0x2222),
            dexBuy: address(0x3333),
            dexSell: address(0x4444),
            amountIn: amountIn,
            minProfit: 1e18,
            minAmountOutBuy: 0,
            minAmountOutSell: 0,
            buyData: "",
            sellData: ""
        });
    }
}
