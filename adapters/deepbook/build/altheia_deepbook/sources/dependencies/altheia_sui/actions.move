/// altheia::actions
///
/// Canonical action ids for the per-agent capability allowlist. A Policy
/// stores the subset of these an agent may perform (`allowed_actions`);
/// everything not listed is denied by default. Ids are a flat global space so
/// the allowlist is venue-agnostic; each adapter references the ids for the
/// actions it implements.
///
/// Core defines the ids; adapters define what they do. New actions append
/// here (and never renumber — ids are referenced from on-chain policies).
module altheia::actions;

/// Plain policy-bounded move of funds to a recipient (transfer adapter).
public fun transfer(): u8 { 0 }

/// DeepBook market swap, Coin in/out (deepbook adapter, value-conserved).
public fun deepbook_swap(): u8 { 1 }

/// DeepBook resting limit order via a BalanceManager (deepbook adapter).
public fun deepbook_limit_order(): u8 { 2 }

/// DeepBook cancel of the agent's resting orders.
public fun deepbook_cancel(): u8 { 3 }
