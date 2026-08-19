// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ArbixFlashLoan} from "../../src/flashloan/ArbixFlashLoan.sol";
import {ArbixExecutor} from "../../src/arbitrage/ArbixExecutor.sol";
import {UniswapV2Adapter} from "../../src/adapters/UniswapV2Adapter.sol";
import {CamelotAdapter} from "../../src/adapters/CamelotAdapter.sol";
import {FlashLoanParams, ArbitrageParams} from "../../src/flashloan/FlashLoanTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
}

contract ArbixForkCrossDexTest is Test {
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant SUSHI_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
    address constant CAMELOT_ROUTER = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    ArbixFlashLoan flashLoan;
    ArbixExecutor executor;
    UniswapV2Adapter sushiAdapter;
    CamelotAdapter camelotAdapter;

    uint256 constant AMOUNT_IN = 10e6;

    function setUp() public {
        string memory rpcUrl = vm.envString("ARBITRUM_RPC_URL");
        vm.createSelectFork(rpcUrl);

        uint256 nonceBeforeFlashLoan = vm.getNonce(address(this));
        address predictedExecutor = vm.computeCreateAddress(address(this), nonceBeforeFlashLoan + 1);

        flashLoan = new ArbixFlashLoan(AAVE_POOL, predictedExecutor);
        executor = new ArbixExecutor(address(flashLoan));

        require(address(executor) == predictedExecutor, "address prediction failed");

        sushiAdapter = new UniswapV2Adapter(SUSHI_ROUTER);
        camelotAdapter = new CamelotAdapter(CAMELOT_ROUTER);
    }

    function _estimateFinalUsdc(
        address dexBuy,
        address dexSell
    ) internal returns (uint256 finalUsdc) {
        uint256 wethOut;

        if (dexBuy == address(sushiAdapter)) {
            wethOut = sushiAdapter.quote(USDC, WETH, AMOUNT_IN, "");
        } else {
            wethOut = camelotAdapter.quote(USDC, WETH, AMOUNT_IN, "");
        }

        if (dexSell == address(sushiAdapter)) {
            finalUsdc = sushiAdapter.quote(WETH, USDC, wethOut, "");
        } else {
            finalUsdc = camelotAdapter.quote(WETH, USDC, wethOut, "");
        }
    }

    function test_Fork_CrossDex_RealArbitrageOutcome() public {
        try sushiAdapter.quote(USDC, WETH, AMOUNT_IN, "") returns (uint256) {} catch {
            vm.skip(true);
            return;
        }
        try camelotAdapter.quote(USDC, WETH, AMOUNT_IN, "") returns (uint256) {} catch {
            vm.skip(true);
            return;
        }

        uint256 finalUsdcBuySushiSellCamelot = _estimateFinalUsdc(address(sushiAdapter), address(camelotAdapter));
        uint256 finalUsdcBuyCamelotSellSushi = _estimateFinalUsdc(address(camelotAdapter), address(sushiAdapter));

        bool sushiToBetterCamelot = finalUsdcBuySushiSellCamelot > finalUsdcBuyCamelotSellSushi;

        address bestDexBuy = sushiToBetterCamelot ? address(sushiAdapter) : address(camelotAdapter);
        address bestDexSell = sushiToBetterCamelot ? address(camelotAdapter) : address(sushiAdapter);
        uint256 bestFinalUsdc = sushiToBetterCamelot ? finalUsdcBuySushiSellCamelot : finalUsdcBuyCamelotSellSushi;

        uint256 estimatedPremium = (AMOUNT_IN * 5) / 10_000;
        uint256 minProfit = 1;
        bool expectedProfitable = bestFinalUsdc > AMOUNT_IN + estimatedPremium + minProfit;

        ArbitrageParams memory params = ArbitrageParams({
            tokenIn: USDC,
            tokenOut: WETH,
            dexBuy: bestDexBuy,
            dexSell: bestDexSell,
            amountIn: AMOUNT_IN,
            minProfit: minProfit,
            minAmountOutBuy: 0,
            minAmountOutSell: 0,
            buyData: abi.encode(block.timestamp + 300),
            sellData: abi.encode(block.timestamp + 300)
        });

        FlashLoanParams memory flParams = FlashLoanParams({
            asset: USDC,
            amount: AMOUNT_IN,
            data: abi.encode(params)
        });

        if (expectedProfitable) {
            uint256 flashLoanBalanceBefore = IERC20Min(USDC).balanceOf(address(flashLoan));

            flashLoan.requestFlashLoan(flParams);

            uint256 flashLoanBalanceAfter = IERC20Min(USDC).balanceOf(address(flashLoan));
            assertGt(
                flashLoanBalanceAfter,
                flashLoanBalanceBefore,
                "expected profit was not realized despite favorable quotes"
            );

            console2.log("Cross-DEX arbitrage succeeded. Buy venue:", bestDexBuy);
            console2.log("Sell venue:", bestDexSell);
            console2.log("Profit realized (USDC, 6 decimals):", flashLoanBalanceAfter - flashLoanBalanceBefore);
        } else {
            vm.expectRevert(Errors.NoProfit.selector);
            flashLoan.requestFlashLoan(flParams);

            console2.log("No profitable cross-DEX edge currently exists between SushiSwap and Camelot for this pair/size - trade correctly reverted.");
        }
    }
}
