# altheia-sui

Move implementation of the `(sui, move-policy-object)` substrate under altheia's chain-agnostic + substrate-agnostic policy plane.

This repo implements the 4-method substrate-adapter contract v1.0. The same policy DSL above the substrate compiles to Swig session keys on Solana (see [altheia-program](https://github.com/altheia-xyz/altheia-program)) and to the Move policy objects defined here for Sui.

**Status:** active build, target submission Sui Overflow 2026 Agentic Web sub-track 2 — **2026-06-20**. This repo flips from private to public on submission day.

## Modules

| Module | Role |
|---|---|
| `altheia::policy` | Per-agent capability object encoding caps + scope + expiry + revocation. Implements `provision` + `revoke` from the adapter contract. |
| `altheia::agent` | `AgentCap` the agent's signing path consumes. Routes through `policy::consume` for on-chain enforcement. |
| `altheia::audit` | On-chain event emission. Every policy decision (allowed / denied / revoked / updated) emits an event with policy version at decision time. Required for data-lineage / incident-replay downstream. |

## Demo

Demo agent is a spread trader on DeepBook v3 — lives in [altheia-sui-demo](https://github.com/altheia-xyz/altheia-sui-demo) (sibling repo). Six demo scenarios target submission day:

1. Allowed trade under cap
2. Per-tx cap denial
3. Per-day cap denial
4. Disallowed package denial
5. Paused agent denial
6. Revoked agent denial

## Substrate-adapter contract

| Method (TS surface in altheia-sdk) | Move equivalent | Notes |
|---|---|---|
| `provision(policy) -> SessionToken` | `altheia::policy::mint(...) -> OwnerCap` + shared Policy object | Operator gets OwnerCap, agent reads shared Policy |
| `enforce(action, policy) -> Allowed \| Denied` | SDK-side mirror of `consume` logic | Off-chain pre-flight, no network |
| `revoke(token) -> Tx` | `altheia::policy::revoke(policy, owner_cap)` | Atomic, bumps version, emits `PolicyRevoked` |
| `decodeEvent(rawEvent) -> AuditEvent` | TS adapter parses `AllowedAction` / `DeniedAction` / `PolicyRevoked` / `PolicyUpdated` events | Off-chain in altheia-sdk |

Full contract: [altheia-plan / 02_SRS / substrate-adapter / CONTRACT.md](https://github.com/altheia-xyz/altheia-plan/blob/main/02_SRS/substrate-adapter/CONTRACT.md).

## Build + test

```bash
sui move build
sui move test
```

Requires `sui` CLI ≥ 1.58.

## License

Apache 2.0 (LICENSE pending — added before public-flip on Jun 20).

## Roadmap

| Date | Milestone |
|---|---|
| May 28 | All three modules compile, basic capability flow tests pass |
| Jun 4 | Modules wired end-to-end; single script exercises `mint -> consume -> emit` |
| Jun 10 | Demo agent live on testnet hitting real DeepBook v3 |
| Jun 16 | Six demo scenarios reproducible from clean clone |
| Jun 19 | Property tests green |
| Jun 20 | Submission. Repo flips public. |

See [SHIP_PLAN_2026_05_22.md](https://github.com/altheia-xyz/altheia-plan/blob/main/01_PHASES/sui/SHIP_PLAN_2026_05_22.md) for the week-by-week.
