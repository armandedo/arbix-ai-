// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAavePool} from "../interfaces/IAavePool.sol";

abstract contract FlashLoanBase {

    IAavePool public immutable POOL;

    address public immutable owner;

    event FlashLoanExecuted(
        address indexed asset,
        uint256 amount,
        uint256 premium
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
}