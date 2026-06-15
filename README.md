# altheia-sui

**The on-chain agent-policy substrate Sui doesn't have.**

On Solana, an operator can bound an AI agent with Swig: an on-chain session-key smart account that caps what the agent can sign. On Sui there is no equivalent. Privy ships Sui *wallets* but its policy engine is EVM/SVM-only — it does not reach MoveVM. So today there is no way, on Sui, to give an AI agent a wallet that is capped, scoped, revocable, and audited on chain.

`altheia-sui` is that primitive. Funds live in a `Balance<T>` inside a no-`store` vault; the only way out is a withdrawal that passes policy and is closed by a hot-potato receipt the transaction cannot settle without. Enforcement is **binding, not advisory** — there is no off-chain check to bypass and no fail-open path.

Import it, and any Sui agent inherits caps + scope + revocation + audit the way Solana agents inherit Swig.

**Status:** Sui Overflow 2026, Agentic Web sub-track 2 — submission **2026-06-20**. Public on submission day.

## Why this is the substrate, not an app

```
import altheia_sui;   // your agent is now bounded
```

The value is in being imported. Two unrelated reference agents in [altheia-sui-demo](https://github.com/altheia-xyz/altheia-sui-demo) — a DeepBook spread-trader and a bare transfer-bot — share zero strategy code and the same enforcement primitive. Neither writes any policy logic; both route withdrawals through this package. That is the Swig pattern: the substrate enforces, the agent just trades.

## Five objects

| Object | Abilities | Role |
|---|---|---|
| `Vault<T>` | `key` (shared) | Holds `Balance<T>`. Only exit is `withdraw_with_receipt`. No `store` → the balance can never escape as a standalone object. |
| `OwnerCap` | `key, store` | Operator's master. Mints / revokes / pauses. Transferable to a multisig or cold wallet. |
| `AgentCap` | `key` only | Per-agent capability. **No `store`** → the agent cannot transfer it away. Scopes to `(vault_id, policy_id)`. |
| `Policy` | `key` (shared) | Caps + allowed packages + expiry + revoked/paused + cumulative `spent_today`. Shared, so daily spend persists across transactions — closes the per-PTB splitting hole. |
| `WithdrawalReceipt` | **none** | Hot potato. Minted by every withdrawal, must be consumed by `attest_simple` / `attest_value_conservation` before the PTB settles, else the whole transaction aborts. This is the binding gate. |

```
withdraw_with_receipt(vault, agentcap, policy, amount, target, recipient, clock)
   ├─ assert agentcap.vault_id == vault            (EWrongVault)
   ├─ policy::check_and_consume(...)                (revoked/paused/expired/over-tx/over-day/scope)
   ├─ assert vault.balance >= amount               (EInsufficientBalance)
   └─ returns (Coin<T>, WithdrawalReceipt)         ← receipt MUST be attested or tx aborts
```

The combination — funds in a no-`store` vault, exit gated by a hot potato — is what makes policy binding. The agent never holds a `Coin<T>` without simultaneously holding an unconsumed receipt; the transaction cannot complete unless policy passed.

## Enforcement coverage

| Rule | Enforced on chain | Abort code |
|---|---|---|
| Per-tx cap | yes | `ECapExceededPerTx` (4) |
| Per-day cumulative cap | yes (shared Policy, cross-PTB) | `ECapExceededPerDay` (5) |
| Allowed-package scope | yes | `EPackageNotAllowed` (6) |
| Revocation (kill switch) | yes | `EPolicyRevoked` (1) |
| Pause / unpause | yes | `EPolicyPaused` (3) |
| Expiry | yes | `EPolicyExpired` (2) |
| Output-leg value conservation (oracled assets) | `attest_value_conservation` (DeepBook-priced) | `EUnderMinValue` |

**Honest boundary:** value-conservation binds only for assets with an on-chain price reference (DeepBook). It cannot price an un-oracled token, because nothing on chain can — a freshly-minted rug token's only price is the attacker's pool. We enforce the input leg, scope, revocation, and oracled-asset value. We do not claim to stop a swap into an un-priceable asset. No one can.

## Build + test

```bash
sui move build
sui move test     # 13/13
```

Requires `sui` CLI ≥ 1.58.

## Part of the altheia policy plane

One SDK (`@altheia-xyz/sdk`), one backend, one dashboard across substrates. Solana enforces via Swig; Sui enforces via this package. Same `altheia.guard(action, fn)` call, dispatched by `(chain, substrate)`.

## License

Apache 2.0.
