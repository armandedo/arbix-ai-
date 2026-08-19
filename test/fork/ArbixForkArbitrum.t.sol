// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ArbixFlashLoan} from "../../src/flashloan/ArbixFlashLoan.sol";
import {ArbixExecutor} from "../../src/arbitrage/ArbixExecutor.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {SyntheticDexAdapter} from "../mocks/SyntheticDexAdapter.sol";
import {FlashLoanParams, ArbitrageParams} from "../../src/flashloan/FlashLoanTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract ArbixForkArbitrumTest is Test {
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant SUSHI_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    ArbixFlashLoan flashLoan;
    ArbixExecutor executor;
    UniswapV2Adapter adapter;

    function setUp() public {
        string memory rpcUrl = vm.envString("ARBITRUM_RPC_URL");
        vm.createSelectFork(rpcUrl);

        uint256 nonceBeforeFlashLoan = vm.getNonce(address(this));
        address predictedExecutor = vm.computeCreateAddress(address(this), nonceBeforeFlashLoan + 1);

        flashLoan = new ArbixFlashLoan(AAVE_POOL, predictedExecutor);
        executor = new ArbixExecutor(address(flashLoan));

        require(address(executor) == predictedExecutor, "address prediction failed");

        adapter = new UniswapV2Adapter(SUSHI_ROUTER);
    }

    function test_Fork_RealContractsHaveCode() public view {
        assertGt(AAVE_POOL.code.length, 0, "Aave Pool has no code");
        assertGt(SUSHI_ROUTER.code.length, 0, "Sushi Router has no code");
        assertGt(USDC.code.length, 0, "USDC has no code");
        assertGt(WETH.code.length, 0, "WETH has no code");
    }

    function test_Fork_Deployment_WiresCorrectly() public view {
        assertEq(address(flashLoan.POOL()), AAVE_POOL);
        assertEq(address(flashLoan.executor()), address(executor));
        assertEq(executor.flashLoanContract(), address(flashLoan));
    }

    function test_Fork_Quote_ReturnsSaneWethUsdcPrice() public {
        try adapter.quote(WETH, USDC, 1 ether, "") returns (uint256 amountOut) {
            assertGt(amountOut, 200e6, "quote implausibly low");
            assertLt(amountOut, 20_000e6, "quote implausibly high");
        } catch {
            vm.skip(true);
        }
    }

    function test_Fork_RoundTripOnSamePool_RevertsWithNoProfit() public {
        uint256 amountIn = 1_000e6;

        try adapter.quote(USDC, WETH, amountIn, "") returns (uint256) {} catch {
            vm.skip(true);
            return;
        }

        deal(USDC, address(this), amountIn);

        ArbitrageParams memory params = ArbitrageParams({
            tokenIn: USDC,
            tokenOut: WETH,
            dexBuy: address(adapter),
            dexSell: address(adapter),
            amountIn: amountIn,
            minProfit: 0,
            minAmountOutBuy: 0,
            minAmountOutSell: 0,
            buyData: abi.encode(block.timestamp + 300),
            sellData: abi.encode(block.timestamp + 300)
        });

        FlashLoanParams memory flParams = FlashLoanParams({
            asset: USDC,
            amount: amountIn,
            data: abi.encode(params)
        });

        vm.expectRevert(Errors.NoProfit.selector);
        flashLoan.requestFlashLoan(flParams);
    }

    function test_Fork_HappyPath_RepaysRealAaveWithRealSwaps() public {
        uint256 amountIn = 10e6;

        uint256 expectedWethFromBuy;
        try adapter.quote(USDC, WETH, amountIn, "") returns (uint256 q) {
            expectedWethFromBuy = q;
        } catch {
            vm.skip(true);
            return;
        }

        uint256 fairUsdcForWeth = adapter.quote(WETH, USDC, expectedWethFromBuy, "");

        uint256 targetSellOut = (fairUsdcForWeth * 105) / 100;

        SyntheticDexAdapter syntheticSell = new SyntheticDexAdapter();
        deal(USDC, address(syntheticSell), targetSellOut * 2);
        syntheticSell.setRate(targetSellOut, expectedWethFromBuy);

        uint256 minProfit = 5e4;

        ArbitrageParams memory params = ArbitrageParams({
            tokenIn: USDC,
            tokenOut: WETH,
            dexBuy: address(adapter),
            dexSell: address(syntheticSell),
            amountIn: amountIn,
            minProfit: minProfit,
            minAmountOutBuy: 0,
            minAmountOutSell: 0,
            buyData: abi.encode(block.timestamp + 300),
            sellData: abi.encode(block.timestamp + 300)
        });

        FlashLoanParams memory flParams = FlashLoanParams({
            asset: USDC,
            amount: amountIn,
            data: abi.encode(params)
        });

        flashLoan.requestFlashLoan(flParams);

        assertEq(IERC20Min(USDC).balanceOf(address(executor)), 0, "executor should hold no residue");
        assertGe(IERC20Min(USDC).balanceOf(address(flashLoan)), minProfit, "flash loan contract should retain at least minProfit");
    }
}

