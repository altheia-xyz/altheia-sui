# altheia-sui

Move implementation of altheia's `(sui, move-policy-object)` substrate. altheia is a non-custodial control plane for on-chain AI agents: an operator grants an agent a capped, scoped, expiring, revocable budget, and every action the agent takes is checked on chain before funds move. This repository is the Sui implementation of that policy plane — a set of Move packages in which a `Policy` object holds the rules, a `Vault` holds the funds, an `AgentCap` identifies the agent, an `AdapterRegistry` allowlists the venues, and a DeepBook adapter runs policy-gated swaps. Enforcement is binding: an over-budget or out-of-scope call aborts on chain, and there is no off-chain check to bypass.

## Architecture

Two published packages. The core package is venue-agnostic and depends on no DeepBook code; venue integrations are separate adapter packages that call back into core through a witness gate.

### Core package — `altheia` (`sources/`)

| Module | Owns |
|---|---|
| `altheia::policy` | The `Policy` object: per-asset caps, allowed packages, allowed actions, expiry, pause, revoke, version, value-guard params. `check_and_consume<T>` is the enforcement gate. |
| `altheia::vault` | The `Vault` object holding `Balance<T>` per coin type in dynamic fields, plus the `OwnerCap`. The only agent exit is `withdraw_with_receipt<T>`. |
| `altheia::agent` | The `AgentCap` the agent holds. `key`-only (no `store`), so the agent cannot transfer it away. Binds `(vault_id, policy_id)`. |
| `altheia::receipt` | The `WithdrawalReceipt` hot potato. No abilities; the only way to close it is `consume_with_check`, which requires an approved adapter's witness. |
| `altheia::registry` | The `AdapterRegistry`: an admin-gated allowlist of approved adapter witness types. Removing an adapter is a global kill switch. |
| `altheia::audit` | Event emission. Every policy decision and attestation emits an event the off-chain indexer turns into an audit log. |
| `altheia::actions` | Canonical action ids for the capability allowlist (`transfer` = 0, `deepbook_swap` = 1, `deepbook_limit_order` = 2, `deepbook_cancel` = 3). |

Objects and abilities:

| Object | Abilities | Role |
|---|---|---|
| `vault::Vault` | `key` (shared) | Holds `Balance<T>` per coin type in dynamic fields. Agent exit only through `withdraw_with_receipt`. |
| `vault::OwnerCap` | `key, store` | Operator's master capability. Mints policies/caps, revokes, pauses, drains. Transferable to a multisig or cold wallet. |
| `agent::AgentCap` | `key` only | Per-agent capability. No `store`, so it cannot be transferred away. Scopes to `(vault_id, policy_id)`. |
| `policy::Policy` | `key` (shared) | Caps + allowed packages + allowed actions + expiry + revoked/paused + per-asset cumulative spend. Shared, so daily spend persists across transactions. |
| `receipt::WithdrawalReceipt` | none | Hot potato minted by every withdrawal; must be consumed by `consume_with_check` before the PTB settles, or the whole transaction aborts. |
| `registry::AdapterRegistry` | `key` (shared) | Allowlist of approved adapter witness `TypeName`s. |
| `registry::RegistryAdminCap` | `key, store` | Authority to add/remove adapters. |

### DeepBook adapter — `altheia_deepbook` (`adapters/deepbook/`)

| Module | Owns |
|---|---|
| `altheia_deepbook::deepbook_adapter` | Policy-gated DeepBook v3 market swaps. `execute_swap_quote_for_base` / `execute_swap_base_for_quote`. Carries `DeepBookWitness`, the registry key core checks before closing the receipt. |
| `altheia_deepbook::trading_account` | The `TradingAccount` wrapper holding a user-minted DeepBook `TradeCap` bound to a `Policy`. Lets the agent place/cancel resting limit orders without ever extracting the cap or withdrawing funds. |

The adapter depends on `altheia_sui` (local) and `deepbook` (Mysten `testnet-v17.0.0`). Core has no dependency on either; the relationship is one-way.

## Policy model

A `Policy` is a shared object. Its fields (all operator-set; the agent supplies none of them):

- **Per-asset caps** — `caps: VecMap<TypeName, AssetCap>`. Each `AssetCap` carries `per_tx_cap`, `per_day_cap`, `spent_today`, and `day_window_started_ms`. An asset with no cap entry is default-deny for outbound transfer; for swaps it is treated as a position acquired via a prior permitted swap and may be unwound without a cap. Because `Policy` is shared, `spent_today` accumulates across PTBs, so a daily cap cannot be split across transactions.
- **Allowed packages** — `allowed_packages: vector<address>`. A withdrawal's `target_package` must be in this list.
- **Allowed actions** — `allowed_actions: VecSet<u8>` over the `actions` ids. Default-deny; checked by `assert_allows`.
- **Expiry** — `expires_at_ms`. After it, every gated call aborts.
- **Pause / unpause** — `paused: bool`. Operator can freeze and resume without revoking.
- **Revoke** — `revoked: bool`. One-way kill switch.
- **Value-guard params** — `max_slippage_bps`, `base_scalar`, and per-action `vector<u64>` params stored in dynamic fields. The DeepBook adapter reads these to compute its swap floor.

### On-chain enforcement

`policy::check_and_consume<T>` is the gate, called inside `vault::withdraw_with_receipt<T>` before any `Coin<T>` leaves the vault. It asserts, in order, and aborts on failure:

| Rule | Abort constant | Code |
|---|---|---|
| Policy id matches the AgentCap's `policy_id` | `EWrongPolicy` | 7 |
| Not revoked | `EPolicyRevoked` | 1 |
| Not paused | `EPolicyPaused` | 3 |
| Not expired (`now < expires_at_ms`) | `EPolicyExpired` | 2 |
| Target package is allowed | `EPackageNotAllowed` | 6 |
| Amount within per-tx cap (capped assets) | `ECapExceededPerTx` | 4 |
| Cumulative spend within per-day cap (capped assets) | `ECapExceededPerDay` | 5 |

Related guards: `assert_allows` aborts `ENotAllowedAction` (8) for a disallowed action id; `assert_transferable<T>` aborts `EAssetNotAllowed` (10) when a transfer targets an uncapped asset; `action_params` aborts `EActionConfigMissing` (9) when per-action params are unset. The receipt gate (`receipt::consume_with_check`) aborts `ENotApprovedAdapter` (3), `ERecipientMismatch` (1), and `EUnderMinValue` (2).

The binding combination is funds in a no-`store` vault whose only exit mints a no-ability hot-potato receipt. The agent never holds a `Coin<T>` without simultaneously holding an unconsumed `WithdrawalReceipt`, and the receipt can be closed only by an adapter whose witness type is in the registry. A withdrawal cannot settle unless policy passed and an approved adapter measured the output.

Value conservation binds only for assets with an on-chain price reference. The DeepBook adapter computes a fair-rate floor (`compute_min_out` / `min_out_from_rate`) and core measures the received coin against it; it cannot price an un-oracled token. The input leg, scope, caps, revocation, pause, and expiry bind unconditionally.

## Deployed addresses (Sui testnet)

| Object | Address |
|---|---|
| core (`altheia`) | `0x786dfa134ccb4d5144bacf0998b356aafdef0c99121d8a35ed237627d173d917` |
| deepbook adapter (`altheia_deepbook`) | `0xac114631b134549c489b4f00ee693b1096a38027473202865bde52b7259ee8b7` |
| registry (`AdapterRegistry`) | `0xe057edccd17e284c7c1307c7d2b260c29d72d4594bed5f49785f91daa5760d12` |
| deepbook pool (DEEP/SUI) | `0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f` |

Package publish metadata lives in `Published.toml` (core) and `adapters/deepbook/Published.toml`.

## Build, test, publish

Requires the `sui` CLI. Core and adapter are separate packages built from their own directories.

Core:

```bash
sui move build                 # from the repo root
sui move test                  # runs the core + adapter unit tests
sui client publish --gas-budget 200000000
```

DeepBook adapter (publish core first; the adapter resolves `altheia_sui` as a local dependency):

```bash
cd adapters/deepbook
sui move build
sui client publish --gas-budget 200000000
```

`[addresses]` is `0x0` in both `Move.toml` files so the packages republish cleanly; `published-at` is set per network at publish time.

## Ecosystem

- **SDK** — [`@altheia-xyz/sui`](https://www.npmjs.com/package/@altheia-xyz/sui) on npm. TypeScript SDK that builds the policy-gated transactions; an agent author writes roughly five lines to provision a vault/policy and route a swap.
- **Demo agent** — [altheia-sui-demo](https://github.com/altheia-xyz/altheia-sui-demo). A minimal agent that trades DeepBook under a policy; it needs only the agent's key. The vault, policy, and registry already enforce on chain.

## Sui Overflow 2026 — sub-track 2

The sub-track 2 spec describes a Move policy object that grants an agent a capped budget and a protocol scope, enforced on chain. This repository is that implementation: `policy::Policy` holds the budget and scope, `vault::Vault` holds the funds, and `policy::check_and_consume` enforces both before any spend.

## License

Proprietary. All rights reserved. The source is available for review only; no use, deployment, or derivative works without prior written permission. See [LICENSE](LICENSE).
