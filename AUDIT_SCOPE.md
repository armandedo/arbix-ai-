# Arbix AI — Audit Scope

**Status:** Pre-audit. Not deployed with real funds. This document summarizes the
system for an external auditor: what each contract does, the trust model,
known findings and how they were resolved or accepted, test coverage, and
explicit out-of-scope items.

---

## 1. System Overview

Arbix AI executes atomic cross-DEX arbitrage on Arbitrum using Aave V3 flash
loans. Flow:

1. Owner calls `ArbixFlashLoan.requestFlashLoan()` with an asset, amount, and
   ABI-encoded `ArbitrageParams`.
2. Aave V3's pool calls back into `ArbixFlashLoan.executeOperation()`.
3. `ArbixFlashLoan` forwards the borrowed funds to `ArbixExecutor` and calls
   `executeArbitrage()`.
4. `ArbixExecutor` performs two swaps (buy leg, sell leg) via `IDexAdapter`
   implementations, requires a strictly positive profit meeting
   `minProfit`, sweeps all funds back to `ArbixFlashLoan`, and reverts
   entirely if unprofitable.
5. `ArbixFlashLoan` repays Aave (amount + premium) from the swept funds.

## 2. Contract Inventory

| Contract | Role |
|---|---|
| `FlashLoanBase.sol` | Base contract: owner/pendingOwner state, two-step ownership transfer, Aave pool reference. |
| `ArbixFlashLoan.sol` | Aave V3 flash-loan entry point. Owns pause, timelocked executor replacement, profit withdrawal. |
| `ArbixExecutor.sol` | Executes the two-leg arbitrage trade and enforces minimum profit. Never holds funds at rest (see §5). |
| `UniswapV2Adapter.sol` | `IDexAdapter` implementation for standard UniswapV2-style routers. Trusts router return values. |
| `CamelotAdapter.sol` | `IDexAdapter` implementation for Camelot (fee-on-transfer-safe router variant). Measures output via balance delta instead of trusting a return value, since Camelot's FOT-safe function returns nothing. |
| `Errors.sol` | Centralized custom errors. |
| `FlashLoanTypes.sol` | `FlashLoanParams`, `ArbitrageParams` structs. |
| `IDexAdapter.sol` | Standard adapter interface (`swap`, `quote`). |

## 3. Trust Model / Assumptions

These are relied upon by the design and should be treated as explicit
assumptions for the audit, not gaps:

- **`owner` is fully trusted.** Only `owner` can call `requestFlashLoan()`,
  and `owner` supplies the ABI-encoded `data` that becomes `ArbitrageParams`
  — including `dexBuy` and `dexSell` addresses. A malicious or compromised
  owner could point these at an attacker-controlled adapter. This is
  accepted as in-scope for a trusted-operator model, not a bug; auditors
  should confirm this assumption is acceptable for the intended deployment
  and flag if it should instead be hardened (e.g. an allowlist of approved
  adapter addresses).
- **`ArbixExecutor` only accepts calls from `flashLoanContract`**, set
  immutably at deployment. `ArbixFlashLoan`'s own `executor` reference is
  mutable via a 2-day-timelocked, owner-gated process
  (`proposeExecutorChange` / `executeExecutorChange` / `cancelExecutorChange`).
- **Ownership transfer is two-step** (`proposeOwnershipTransfer` /
  `acceptOwnershipTransfer` / `cancelOwnershipTransfer`), preventing loss of
  control to a typo'd address — see
  `test_TypoAddress_CannotAcceptAndOwnershipRemainsSafe`.
- **DEX adapters (`UniswapV2Adapter`, `CamelotAdapter`) are stateless** —
  no persistent storage beyond the immutable `router` address, no custody of
  funds across transactions. This underlies the accepted reentrancy findings
  in §4.

## 4. Static Analysis (Slither) — Findings and Resolution

Slither 0.11.6 was run via `slither . --exclude-dependencies`. Final result:
11 findings, all resolved or explicitly accepted below.

### 4.1 Fixed

| Finding | Location | Fix |
|---|---|---|
| `unused-return` | `ArbixExecutor.executeArbitrage` | Sell-leg `IDexAdapter.swap()` return value was previously discarded. Now captured as `tokenInReceived` and checked against `params.minAmountOutSell` before proceeding, as defense-in-depth alongside the existing balance-based profit check. |
| `reentrancy-events` (×2) | `ArbixFlashLoan.executeOperation`, `ArbixFlashLoan.withdrawProfit` | `emit FlashLoanCompleted` / `emit ProfitWithdrawn` moved to occur before their respective external `transfer`/`approve`/`executeArbitrage` calls, following checks-effects-interactions. All emitted values are known from function inputs prior to the external calls, so no behavioral change; purely closes the window where a reentrant call could execute before the event fires. |

### 4.2 Accepted (no code change; documented reasoning)

| Finding | Location | Reasoning |
|---|---|---|
| `reentrancy-balance` (×4) | `ArbixExecutor.executeArbitrage` | Function is protected by a `nonReentrant` guard (custom, non-OpenZeppelin implementation using a `NOT_ENTERED`/`ENTERED` status flag — see `test_ReentrancyGuard_BlocksReentrantCall`) and is only callable by `onlyFlashLoanContract`. `dexBuy`/`dexSell` are only ever set by the trusted `owner` via `requestFlashLoan` (see §3). Slither's static heuristic does not fully account for the reentrancy guard's effect. |
| `reentrancy-balance` | `CamelotAdapter.swap` | No reentrancy guard or access control on this function, but it is safe by construction: `balanceBefore`/`balanceAfter` are local (stack) variables scoped to a single call frame, not storage — a reentrant call gets an independent copy and cannot corrupt the outer call's accounting. The adapter holds no funds across transactions (pulled from and paid to `msg.sender` within one atomic call). **Caveat for future changes:** this reasoning holds only while the adapter remains stateless. Any future addition of persistent storage (fees, pause flags, owner) without also adding a reentrancy guard would invalidate this analysis. `UniswapV2Adapter` shares this same stateless design and the same reasoning applies, though it did not independently trigger this Slither detector. |
| `timestamp` (×3) | `UniswapV2Adapter._decodeDeadline`, `CamelotAdapter._decodeDeadline`, `ArbixFlashLoan.executeExecutorChange` | Expected, correct use of `block.timestamp` for swap deadlines and the executor-change timelock. Miner/validator manipulation is bounded to seconds and immaterial at these timescales. Not a vulnerability. |
| `naming-convention` | `FlashLoanBase.POOL` | ALL_CAPS naming for an immutable is a deliberate, common convention (matches patterns used by OpenZeppelin and others), not an oversight. |

## 5. Fuzz and Invariant Testing

Beyond static analysis and hand-written unit tests, dynamic testing was added
to `test/unit/ArbixExecutor.t.sol` and `test/invariant/ArbixExecutorInvariant.t.sol`.
Config: `[fuzz] runs = 1000`, `[invariant] runs = 256, depth = 100` (see
`foundry.toml`).

### 5.1 Fuzz tests (profit math)

- **`testFuzz_ExecuteArbitrage_ProfitMatchesCalculatedDelta`** — randomizes
  `amountIn` and both leg swap rates across 1000 runs. Independently
  recomputes the expected two-leg output using the same floor-division
  formula as the mock adapters, then asserts the executor's outcome (revert
  for break-even/loss, or exact swept amount for profit) matches. Confirms
  no rounding or overflow divergence between expected and actual profit
  accounting across a wide input space.
- **`testFuzz_ExecuteArbitrage_RevertsWhenProfitBelowRequestedMinimum`** —
  constructs a guaranteed-profitable trade, then sets `minProfit` strictly
  above the true profit. Confirms the minimum-profit gate cannot be
  bypassed by any rate/amount combination in the fuzzed space.

### 5.2 Invariant tests (balance-at-rest guarantee)

`ArbixExecutorInvariant.t.sol` uses a handler contract that repeatedly calls
`executeArbitrage` with randomized `amountIn` and swap rates (this is the
sole fuzz target — restricted via `targetSelector` to avoid the fuzzer also
calling test-scaffolding functions like `setExecutor`). Funding and the
arbitrage attempt are wrapped in a single external self-call so a revert
(e.g. `NoProfit` on unprofitable random rates) rolls back the funding mint
too, mirroring how a reverted flash-loan transaction rolls back atomically
in production.

- **`invariant_ExecutorNeverHoldsTokenInAtRest`** — asserts
  `tokenIn.balanceOf(executor) == 0` after every call in the sequence.
- **`invariant_ExecutorNeverHoldsTokenOutAtRest`** — same guarantee for the
  intermediate `tokenOut` leg.

Both held across 25,600 handler calls each (256 runs × depth 100), zero
violations. This directly verifies the design guarantee stated in
`ArbixExecutor`'s contract-level NatSpec: *"the executor never holds a
balance at rest."*

## 6. Test Suite Summary

84 tests total, all passing as of the latest commit:

- 45 unit tests — `ArbixFlashLoan` (ownership transfer, pause, timelocked
  executor replacement, withdrawals, constructor validation)
- 9 tests — `ArbixExecutor` (7 unit + 2 fuzz)
- 11 unit tests — `UniswapV2Adapter`
- 11 unit tests — `CamelotAdapter`
- 2 invariant tests — `ArbixExecutor` balance-at-rest guarantee
- 6 fork tests — against live Arbitrum mainnet state (real Aave V3 pool,
  real SushiSwap, real Camelot), covering deployment wiring, a happy-path
  flash loan with real swaps, and confirming a same-pool round-trip
  correctly reverts with `NoProfit`.

## 7. Known Limitations / Explicitly Out of Scope for This Audit

- **Fee-on-transfer tokens are not explicitly supported end-to-end.**
  `ArbixExecutor`'s NatSpec documents that `tokenIn` fee-on-transfer
  behavior is caught by the `balanceBefore` check (executor won't receive
  the full `amountIn`, causing a revert), but `tokenOut` FOT behavior during
  the swap legs is only safe when using an adapter that measures actual
  balance deltas (`CamelotAdapter` does this; `UniswapV2Adapter` trusts the
  router's return value instead and should not be used with FOT tokens).
  Do not route arbitrage through FOT tokens without auditing each adapter's
  specific handling first.
  - **Non-standard `approve()` tokens (e.g. legacy USDT) are not explicitly
  hardened against.** `ArbixExecutor` and both DEX adapters call
  `approve()` with a fresh non-zero allowance each trade without first
  resetting to zero. Some older tokens revert on a non-zero-to-non-zero
  approval change. This is considered low-risk given (a) the executor
  never holds a resting balance or stale allowance between transactions —
  confirmed by the invariant tests in §5.2 — and (b) each approval is
  fully consumed within the same atomic transaction it's created in. Not
  hardened with an approve-to-zero-first pattern to avoid the added gas
  cost on every trade. Flagged here as an explicit, accepted trade-off
  rather than an oversight; auditors should confirm this reasoning holds
  and flag if a specific token in the intended trading set requires the
  defensive pattern.
- **Off-chain trading/execution bot is not yet built.** This audit scope
  covers on-chain contracts only.
- **Gas/MEV hardening not yet implemented** — no private mempool
  submission (e.g. Flashbots Protect / MEV-Share) integration yet; current
  testing assumes public mempool submission is out of scope for this audit
  pass.
- **Additional DEX adapters** (Uniswap V3, Balancer, Curve, etc.) are not
  yet implemented; only `UniswapV2Adapter` and `CamelotAdapter` exist today.
- **No monitoring/ops tooling** (alerting, dashboards) exists yet.

## 8. Open Questions for the Auditor

1. Is the fully-trusted-owner model (§3) acceptable for the intended
   deployment, or should `dexBuy`/`dexSell` be constrained to an allowlist
   set by owner in advance, rather than accepted freely per-call?
2. Does the custom `nonReentrant` implementation in `ArbixExecutor`
   (status-flag based, not OpenZeppelin's `ReentrancyGuard`) have any subtle
   difference in gas or behavior worth flagging versus the standard
   implementation?
3. Any edge cases in the two-leg profit calculation
   (`balanceAfter - balanceBefore`) under extreme but not-yet-considered
   token behaviors (e.g. rebasing tokens, tokens with transfer hooks)?
4. Confirm the accepted reentrancy reasoning in §4.2 for the stateless
   adapters — particularly whether any indirect exploitation path exists
   that doesn't require persistent adapter storage.
5. Confirm whether any specific token planned for arbitrage requires the
   approve-to-zero-first pattern (see §7) before it's added to the trading
   set — this is a per-token compatibility check, not a general contract
   flaw.