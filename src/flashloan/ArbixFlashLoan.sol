// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FlashLoanBase} from "./FlashLoanBase.sol";
import {IFlashLoanSimpleReceiver} from "../interfaces/IFlashLoanSimpleReceiver.sol";
import {IArbitrageExecutor} from "../interfaces/IArbitrageExecutor.sol";
import {
    FlashLoanParams,
    ArbitrageParams
} from "./FlashLoanTypes.sol";
import {Errors} from "../libraries/Errors.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title ArbixFlashLoan
/// @notice Aave V3 flash-loan entry point for Arbix.
contract ArbixFlashLoan is
    FlashLoanBase,
    IFlashLoanSimpleReceiver
{
    /// @dev No longer immutable — replaceable via a timelocked process.
    IArbitrageExecutor public executor;

    bool public paused;

    address public pendingExecutor;
    uint256 public executorChangeUnlockTime;
    uint256 public constant EXECUTOR_CHANGE_DELAY = 2 days;

    event FlashLoanRequested(
        address indexed asset,
        uint256 amount
    );

    event FlashLoanCompleted(
        address indexed asset,
        uint256 amount,
        uint256 premium
    );

    event ProfitWithdrawn(
        address indexed asset,
        address indexed to,
        uint256 amount
    );

    event PausedStateChanged(bool paused);

    event ExecutorChangeProposed(
        address indexed newExecutor,
        uint256 unlockTime
    );

    event ExecutorChangeExecuted(
        address indexed oldExecutor,
        address indexed newExecutor
    );

    event ExecutorChangeCancelled(
        address indexed cancelledExecutor
    );

    modifier whenNotPaused() {
        if (paused) {
            revert Errors.ContractPaused();
        }
        _;
    }

    constructor(
        address pool,
        address executor_
    ) FlashLoanBase(pool) {
        if (executor_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        executor = IArbitrageExecutor(executor_);
    }

    /// @notice Request an Aave V3 simple flash loan.
    function requestFlashLoan(
        FlashLoanParams calldata params
    ) external onlyOwner whenNotPaused {
        if (params.asset == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (params.amount == 0) {
            revert Errors.InvalidAmount();
        }

        emit FlashLoanRequested(
            params.asset,
            params.amount
        );

        POOL.flashLoanSimple(
            address(this),
            params.asset,
            params.amount,
            params.data,
            0
        );
    }

    /// @notice Aave V3 flash-loan callback.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        if (msg.sender != address(POOL)) {
            revert Errors.Unauthorized();
        }
        if (initiator != address(this)) {
            revert Errors.Unauthorized();
        }

        ArbitrageParams memory arbParams =
            abi.decode(params, (ArbitrageParams));

        if (arbParams.amountIn != amount) {
            revert Errors.InvalidAmount();
        }

        if (!IERC20(asset).transfer(address(executor), amount)) {
            revert Errors.FlashLoanFailed();
        }

        executor.executeArbitrage(arbParams);

        uint256 repayment = amount + premium;

        if (
            !IERC20(asset).approve(
                address(POOL),
                repayment
            )
        ) {
            revert Errors.FlashLoanFailed();
        }

        emit FlashLoanCompleted(
            asset,
            amount,
            premium
        );

        return true;
    }

    /// @notice Withdraws accumulated arbitrage profit to a chosen address.
    function withdrawProfit(
        address asset,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (asset == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (to == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (amount == 0) {
            revert Errors.InvalidAmount();
        }
        if (IERC20(asset).balanceOf(address(this)) < amount) {
            revert Errors.InsufficientBalance();
        }

        if (!IERC20(asset).transfer(to, amount)) {
            revert Errors.FlashLoanFailed();
        }

        emit ProfitWithdrawn(asset, to, amount);
    }

    /// @notice Pauses or unpauses new flash-loan requests.
    /// @dev Does not affect withdrawProfit — the owner can always retrieve
    ///      funds, paused or not.
    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedStateChanged(value);
    }

    /// @notice Proposes a new executor. Takes effect only after
    ///         EXECUTOR_CHANGE_DELAY has elapsed and executeExecutorChange()
    ///         is called.
    function proposeExecutorChange(address newExecutor) external onlyOwner {
        if (newExecutor == address(0)) {
            revert Errors.ZeroAddress();
        }

        pendingExecutor = newExecutor;
        executorChangeUnlockTime = block.timestamp + EXECUTOR_CHANGE_DELAY;

        emit ExecutorChangeProposed(newExecutor, executorChangeUnlockTime);
    }

    /// @notice Finalizes a previously proposed executor change, once the
    ///         timelock has elapsed.
    function executeExecutorChange() external onlyOwner {
        if (pendingExecutor == address(0)) {
            revert Errors.NoPendingExecutorChange();
        }
        if (block.timestamp < executorChangeUnlockTime) {
            revert Errors.TimelockNotElapsed();
        }

        address oldExecutor = address(executor);
        executor = IArbitrageExecutor(pendingExecutor);

        pendingExecutor = address(0);
        executorChangeUnlockTime = 0;

        emit ExecutorChangeExecuted(oldExecutor, address(executor));
    }

    /// @notice Cancels a pending executor change before it takes effect.
    function cancelExecutorChange() external onlyOwner {
        if (pendingExecutor == address(0)) {
            revert Errors.NoPendingExecutorChange();
        }

        address cancelled = pendingExecutor;
        pendingExecutor = address(0);
        executorChangeUnlockTime = 0;

        emit ExecutorChangeCancelled(cancelled);
    }
}

