# Arbix AI

Flash-loan-powered cross-DEX arbitrage on Arbitrum, built with Foundry.

**Status:** Pre-audit. Not deployed with real funds. See `AUDIT_SCOPE.md` for
the full trust model, known findings, and test coverage summary.

## Overview

Arbix AI borrows funds via an Aave V3 flash loan, executes a two-leg
arbitrage trade across two DEXs (buy on one, sell on the other), and repays
the loan — all atomically within a single transaction. If the trade isn't
profitable, the entire transaction reverts and nothing happens.

## Contracts

| Contract | Path | Role |
|---|---|---|
| `FlashLoanBase` | `src/flashloan/FlashLoanBase.sol` | Owner/pendingOwner state, two-step ownership transfer, Aave pool reference. |
| `ArbixFlashLoan` | `src/flashloan/ArbixFlashLoan.sol` | Aave V3 flash-loan entry point. Pause, timelocked executor replacement, profit withdrawal. |
| `ArbixExecutor` | `src/arbitrage/ArbixExecutor.sol` | Executes the two-leg arbitrage trade, enforces minimum profit, never holds funds at rest. |
| `UniswapV2Adapter` | `src/adapters/UniswapV2Adapter.sol` | `IDexAdapter` implementation for UniswapV2-style routers (e.g. SushiSwap). |
| `CamelotAdapter` | `src/adapters/CamelotAdapter.sol` | `IDexAdapter` implementation for Camelot's fee-on-transfer-safe router. |
| `Errors` | `src/libraries/Errors.sol` | Centralized custom errors. |
| `FlashLoanTypes` | `src/flashloan/FlashLoanTypes.sol` | `FlashLoanParams`, `ArbitrageParams` structs. |
| `IDexAdapter` | `src/interfaces/IDexAdapter.sol` | Standard interface any DEX adapter must implement. |
| `IArbitrageExecutor` | `src/interfaces/IArbitrageExecutor.sol` | Interface implemented by `ArbixExecutor`. |

## Key design decisions

**Push-based fund flow, not pull-based.** `ArbixFlashLoan` transfers borrowed funds directly to `ArbixExecutor` rather than granting it a standing approval.

**Per-leg slippage set off-chain.** `minAmountOutBuy` and `minAmountOutSell` are supplied as explicit parameters by the caller.

**Timelocked executor replacement.** `executor` is mutable, but changing it requires a two-step `proposeExecutorChange` -> wait `EXECUTOR_CHANGE_DELAY` (2 days) -> `executeExecutorChange` flow.

**Two-step ownership transfer.** `proposeOwnershipTransfer` -> `acceptOwnershipTransfer` prevents permanent loss of control to a typo'd address.

**Pause does not block profit withdrawal.** `setPaused(true)` blocks new `requestFlashLoan` calls but never blocks `withdrawProfit`.

**Reentrancy guard validated against the legitimate caller, not just an outsider.**

## Known limitations / explicitly out of scope

See `AUDIT_SCOPE.md` for the full, current list. Summary:

- Fee-on-transfer tokens require care.
- Non-standard `approve()` tokens (e.g. legacy USDT) are not explicitly hardened against.
- No off-chain trading bot is included in this repository (see the separate `arbix-bot` project).
- Only two DEX venues are integrated (SushiSwap, Camelot).

## Testing

84 tests total: unit, integration, fork, fuzz, and invariant tests.

```bash
forge test
forge test --match-path "test/unit/**"
forge test --match-path "test/fork/**" -vvvv
forge test --gas-report
```

## Deployment

`ArbixFlashLoan` and `ArbixExecutor` have a circular dependency. Deployment predicts the executor's future contract address before deploying. See `script/DeployLocal.s.sol` for a working example against a local Anvil fork.

## License

MIT
