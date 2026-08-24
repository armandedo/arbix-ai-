# Arbix AI

Flash-loan arbitrage protocol built on Aave V3, targeting decentralized exchanges on Arbitrum One.

Arbix borrows an asset from Aave V3 with no collateral, executes a two-leg arbitrage trade across two independent DEX venues, repays the loan plus premium, and retains any resulting profit — all within a single atomic transaction. If the trade would not be profitable, the entire transaction reverts and no funds are ever at risk.

**Status:** Feature-complete, extensively tested against both a local Foundry environment and a live Arbitrum mainnet fork. **Not yet audited. Do not deploy with real funds until an independent security audit has been completed.**

---

## Architecture

```
Owner
  │
  │ requestFlashLoan(asset, amount, arbitrageParams)
  ▼
ArbixFlashLoan ──────────────────────────────► Aave V3 Pool
  │                                                  │
  │ (Aave calls back)                                │
  │ ◄────────────────────────────────────────────────┘
  │
  │ executeOperation(asset, amount, premium, ...)
  │   1. Verify caller is Aave Pool
  │   2. Verify initiator is this contract
  │   3. Push `amount` of `asset` to ArbixExecutor
  ▼
ArbixExecutor
  │
  │ executeArbitrage(params)
  │   1. Buy tokenOut using tokenIn via dexBuy adapter
  │   2. Sell tokenOut back to tokenIn via dexSell adapter
  │   3. Require profit >= minProfit, else revert
  │   4. Sweep entire balance back to ArbixFlashLoan
  ▼
IDexAdapter (UniswapV2Adapter / CamelotAdapter)
  │
  │ swap(tokenIn, tokenOut, amountIn, minAmountOut, data)
  ▼
Real DEX Router (SushiSwap / Camelot)
```

Back in `ArbixFlashLoan.executeOperation`: the contract approves the Aave Pool for `amount + premium` and returns `true`, at which point Aave pulls the repayment. Any surplus above the repayment amount remains in `ArbixFlashLoan` as retained profit, withdrawable by the owner at any time via `withdrawProfit`.

## Contracts

| Contract | Path | Purpose |
|---|---|---|
| `ArbixFlashLoan` | `src/flashloan/ArbixFlashLoan.sol` | Aave V3 flash-loan entry point. Requests loans, handles the repayment callback, holds and releases profit, owns pause and executor-replacement controls. |
| `ArbixExecutor` | `src/arbitrage/ArbixExecutor.sol` | Executes the two-leg arbitrage trade and enforces the minimum-profit safety check. |
| `UniswapV2Adapter` | `src/adapters/UniswapV2Adapter.sol` | `IDexAdapter` implementation for SushiSwap (Uniswap V2-compatible router) on Arbitrum. |
| `CamelotAdapter` | `src/adapters/CamelotAdapter.sol` | `IDexAdapter` implementation for Camelot's DEX on Arbitrum. Uses balance-delta measurement since Camelot's router does not return swap output amounts. |
| `FlashLoanBase` | `src/flashloan/FlashLoanBase.sol` | Shared owner and Aave Pool reference. |
| `Errors` | `src/libraries/Errors.sol` | Centralized custom errors. |
| `FlashLoanTypes` | `src/flashloan/FlashLoanTypes.sol` | Shared structs (`FlashLoanParams`, `ArbitrageParams`). |
| `IDexAdapter` | `src/interfaces/IDexAdapter.sol` | Standard interface any DEX adapter must implement. |
| `IArbitrageExecutor` | `src/interfaces/IArbitrageExecutor.sol` | Interface implemented by `ArbixExecutor`. |

## Key design decisions

**Push-based fund flow, not pull-based.** `ArbixFlashLoan` transfers borrowed funds directly to `ArbixExecutor` rather than granting it a standing approval. This avoids leaving an approval live while the executor makes external calls to DEX adapters, reducing reentrancy and approval-exploitation surface.

**Per-leg slippage set off-chain.** `minAmountOutBuy` and `minAmountOutSell` are supplied as explicit parameters by the caller (the off-chain bot / owner), rather than derived on-chain from a fixed tolerance or from the same adapter's own quote. This keeps gas costs low and avoids a self-referential slippage check (an adapter validating its own execution against its own quote).

**Timelocked executor replacement.** `executor` is mutable, but changing it requires a two-step `proposeExecutorChange` → wait `EXECUTOR_CHANGE_DELAY` (2 days) → `executeExecutorChange` flow. This allows the owner to fix bugs or upgrade routing logic without redeploying the entire system, while preventing an instant, unannounced redirection of future flash-loaned funds — including in the event the owner key is compromised.

**Pause does not block profit withdrawal.** `setPaused(true)` blocks new `requestFlashLoan` calls but never blocks `withdrawProfit`, so the owner retains access to accumulated funds under all circumstances.

**Reentrancy guard validated against the legitimate caller, not just an outsider.** The test suite includes a dedicated attack harness (`ReentrancyAttacker` / `MaliciousDexAdapter`) that reenters `ArbixExecutor` through its own authorized `flashLoanContract` address — the scenario a simple `onlyFlashLoanContract` check alone would not catch.

## Known limitations / explicitly out of scope

- **Fee-on-transfer tokens are not supported.** `tokenIn` transfers that deduct a fee will correctly cause `Errors.InsufficientBalance()` in `ArbixExecutor` rather than silently miscalculating profit — see the `@dev` note on `ArbixExecutor` for detail. `tokenOut` fee-on-transfer behavior during the swap legs is only safe with adapters (like `CamelotAdapter`) that measure real balance deltas; `UniswapV2Adapter` does not currently do this and should not be pointed at fee-on-transfer `tokenOut` assets.
- **Ownership is currently immutable**, set once at deployment (`FlashLoanBase` constructor). There is no ownership-transfer mechanism. For production use with meaningful capital, consider deploying with a multisig as the initial owner rather than an EOA.
- **No off-chain trading bot is included.** These contracts only execute a trade when explicitly instructed via `requestFlashLoan` with pre-computed parameters. Identifying profitable opportunities, computing safe slippage bounds, and submitting transactions (ideally via a private/MEV-protected relay) is a separate system not covered by this repository.
- **No gas optimization pass has been performed.** The contracts are written for clarity and correctness first.
- **Only two DEX venues are integrated** (SushiSwap, Camelot). Both are Uniswap V2-style AMMs; no concentrated-liquidity (Uniswap V3-style) adapter exists yet.

## Testing

The test suite has two tiers:

**Unit tests** (`test/unit/`, `test/fork/` excluded) — run entirely against local Foundry mocks, no network required:
```bash
forge test --match-path "test/unit/**"
```

**Fork tests** (`test/fork/`) — run against a live Arbitrum mainnet fork, exercising real Aave V3, real SushiSwap, and real Camelot contracts:
```bash
export ARBITRUM_RPC_URL="<your RPC URL>"
forge test --match-path "test/fork/**" -vvvv
```

Run everything:
```bash
forge test -vv
```

As of the last full run: **68/68 tests passing** (62 unit, 6 fork).

Fork tests are inherently dependent on real-time on-chain conditions (liquidity depth, current prices). Tests that require a specific liquidity pool to exist are written to skip gracefully (`vm.skip(true)`) rather than fail if that pool is unavailable at test time. The cross-DEX arbitrage fork test (`ArbixForkCrossDex.t.sol`) determines its own expected outcome from live quotes rather than assuming a fixed result — it is expected, and correct, for it to observe "no profitable edge exists right now" on most runs.

## Deployment

`ArbixFlashLoan` and `ArbixExecutor` have a circular dependency (each holds an immutable/initial reference to the other). Deployment must predict the executor's future contract address before deploying the flash-loan contract:

```solidity
uint256 nonceBeforeFlashLoan = vm.getNonce(deployer);
address predictedExecutor = vm.computeCreateAddress(deployer, nonceBeforeFlashLoan + 1);

flashLoan = new ArbixFlashLoan(AAVE_POOL, predictedExecutor);
executor = new ArbixExecutor(address(flashLoan));

require(address(executor) == predictedExecutor, "address prediction failed");
```

This pattern is exercised directly in `test/fork/ArbixForkArbitrum.t.sol` and `test/fork/ArbixForkCrossDex.t.sol`.

## License

MIT

