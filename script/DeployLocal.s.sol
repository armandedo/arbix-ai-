// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ArbixFlashLoan} from "../src/flashloan/ArbixFlashLoan.sol";
import {ArbixExecutor} from "../src/arbitrage/ArbixExecutor.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";
import {CamelotAdapter} from "../src/adapters/CamelotAdapter.sol";

/// @notice Deploys the full Arbix stack against a local Anvil fork of
///         Arbitrum mainnet, wired to the real Aave V3 pool, SushiSwap
///         router, and Camelot router. NOT for production deployment.
contract DeployLocal is Script {
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant SUSHI_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
    address constant CAMELOT_ROUTER = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // ArbixExecutor's constructor needs ArbixFlashLoan's address, but
        // ArbixFlashLoan's constructor needs ArbixExecutor's address —
        // circular. Resolve by precomputing the address the next
        // deployment (ArbixFlashLoan, deployed immediately after) will get,
        // since CREATE addresses are deterministic from deployer + nonce.
        uint64 nonce = vm.getNonce(deployer);
        address predictedFlashLoan = vm.computeCreateAddress(deployer, nonce + 1);

        ArbixExecutor executor = new ArbixExecutor(predictedFlashLoan);
        ArbixFlashLoan flashLoan = new ArbixFlashLoan(AAVE_POOL, address(executor));

        require(address(flashLoan) == predictedFlashLoan, "address prediction mismatch");

        UniswapV2Adapter sushiAdapter = new UniswapV2Adapter(SUSHI_ROUTER);
        CamelotAdapter camelotAdapter = new CamelotAdapter(CAMELOT_ROUTER);

        vm.stopBroadcast();

        console2.log("ArbixExecutor:   ", address(executor));
        console2.log("ArbixFlashLoan:  ", address(flashLoan));
        console2.log("UniswapV2Adapter:", address(sushiAdapter));
        console2.log("CamelotAdapter:  ", address(camelotAdapter));
    }
}
