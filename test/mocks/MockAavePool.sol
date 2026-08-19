// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFlashLoanSimpleReceiver} from "../../src/interfaces/IFlashLoanSimpleReceiver.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockAavePool {
    uint256 public premiumBps = 9; // 0.09%, matches real Aave default

    function setPremiumBps(uint256 bps) external {
        premiumBps = bps;
    }

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 /* referralCode */
    ) external {
        uint256 premium = (amount * premiumBps) / 10_000;

        // Fund the receiver with the borrowed amount
        MockERC20(asset).mint(receiverAddress, amount);

        bool success = IFlashLoanSimpleReceiver(receiverAddress).executeOperation(
            asset,
            amount,
            premium,
            msg.sender,
            params
        );
        require(success, "MockAavePool: executeOperation failed");

        // Pull repayment via the approval the receiver granted
        MockERC20(asset).transferFrom(receiverAddress, address(this), amount + premium);
    }
}
