// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAavePool} from "../interfaces/IAavePool.sol";
import {Errors} from "../libraries/Errors.sol";

abstract contract FlashLoanBase {

    IAavePool public immutable POOL;

    address public owner;

    address public pendingOwner;

    event FlashLoanExecuted(
        address indexed asset,
        uint256 amount,
        uint256 premium
    );

    event OwnershipTransferProposed(
        address indexed currentOwner,
        address indexed proposedOwner
    );

    event OwnershipTransferAccepted(
        address indexed previousOwner,
        address indexed newOwner
    );

    event OwnershipTransferCancelled(
        address indexed cancelledProposedOwner
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address pool) {
        require(pool != address(0), "Invalid pool");

        owner = msg.sender;
        POOL = IAavePool(pool);
    }

    function proposeOwnershipTransfer(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert Errors.ZeroAddress();
        }

        pendingOwner = newOwner;

        emit OwnershipTransferProposed(owner, newOwner);
    }

    function acceptOwnershipTransfer() external {
        if (pendingOwner == address(0)) {
            revert Errors.NoPendingOwnershipTransfer();
        }
        if (msg.sender != pendingOwner) {
            revert Errors.NotPendingOwner();
        }

        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);

        emit OwnershipTransferAccepted(previousOwner, owner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) {
            revert Errors.NoPendingOwnershipTransfer();
        }

        address cancelled = pendingOwner;
        pendingOwner = address(0);

        emit OwnershipTransferCancelled(cancelled);
    }
}
