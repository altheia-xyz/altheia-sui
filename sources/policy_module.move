/// altheia::policy_module
///
/// Generic, reusable policy primitives that adapter-specific bounds compose
/// from. Pure + self-contained (no Policy/Vault dependency) so they unit-test
/// in isolation and any adapter can reuse them without a core struct change.
/// Design: altheia-plan/01_PHASES/sui/POLICY_MODULE_DESIGN.md.
///
/// The BoundedCounter is the heart: one type, two modes —
///   FLOW  — resets each window (spend/day caps).
///   STOCK — cumulative up/down against a ceiling (debt, perp/option notional).
/// It carries the audit-hardening invariants forward: the checked-add form
/// (no overflow) and preserve-on-reset (re-issuing a cap can't wipe the budget).
module altheia::policy_module;

// === Errors ===
const ELimitExceeded: u64 = 1; // consume past the ceiling (or over-cap already)
const EOverMax: u64 = 2;       // assert_max
const EOutOfRange: u64 = 3;    // assert_in_range
const EExpired: u64 = 4;       // assert_before

const MODE_FLOW: u8 = 0;
const MODE_STOCK: u8 = 1;

public struct BoundedCounter has store, copy, drop {
    mode: u8,
    limit: u64,
    current: u64,
    window_ms: u64,          // FLOW only
    window_started_ms: u64,  // FLOW only
}

public fun new_flow(limit: u64, window_ms: u64, now: u64): BoundedCounter {
    BoundedCounter { mode: MODE_FLOW, limit, current: 0, window_ms, window_started_ms: now }
}

public fun new_stock(limit: u64): BoundedCounter {
    BoundedCounter { mode: MODE_STOCK, limit, current: 0, window_ms: 0, window_started_ms: 0 }
}

/// Consume `amount` against the counter. FLOW rolls its window first if elapsed.
/// Checked form: reject if already over-cap, then `amount <= limit - current`
/// (no overflow, clean ELimitExceeded even for a near-u64::MAX amount or a limit
/// lowered below current spend).
public fun consume(c: &mut BoundedCounter, amount: u64, now: u64) {
    if (c.mode == MODE_FLOW && now >= c.window_started_ms + c.window_ms) {
        c.window_started_ms = now;
        c.current = 0;
    };
    assert!(c.current <= c.limit, ELimitExceeded);
    assert!(amount <= c.limit - c.current, ELimitExceeded);
    c.current = c.current + amount;
}

/// Pure: would consuming `amount` exceed the counter, accounting for a FLOW
/// window roll at `now`? Does not mutate. Lets a caller attach its OWN abort
/// code (e.g. a per-day cap error) instead of the generic ELimitExceeded, then
/// apply the state change with `consume`.
public fun would_exceed(c: &BoundedCounter, amount: u64, now: u64): bool {
    let cur = if (c.mode == MODE_FLOW && now >= c.window_started_ms + c.window_ms) 0 else c.current;
    cur > c.limit || amount > c.limit - cur
}

/// STOCK: reduce outstanding (repay/close). Saturating — never underflows.
public fun release(c: &mut BoundedCounter, amount: u64) {
    c.current = if (amount >= c.current) 0 else c.current - amount;
}

/// Re-set the limit while preserving accumulated `current` (and the FLOW window).
/// Re-issuing a cap must not reset the budget.
public fun preserve(old: &BoundedCounter, new_limit: u64): BoundedCounter {
    BoundedCounter {
        mode: old.mode,
        limit: new_limit,
        current: old.current,
        window_ms: old.window_ms,
        window_started_ms: old.window_started_ms,
    }
}

// Thin self-contained checks (the other taxonomy shapes).
public fun assert_max(amount: u64, max: u64) { assert!(amount <= max, EOverMax); }
public fun assert_in_range(v: u64, min: u64, max: u64) { assert!(v >= min && v <= max, EOutOfRange); }
public fun assert_before(now: u64, deadline_ms: u64) { assert!(now < deadline_ms, EExpired); }

// === Accessors (tests + SDK reads) ===
public fun current(c: &BoundedCounter): u64 { c.current }
public fun limit(c: &BoundedCounter): u64 { c.limit }
public fun remaining(c: &BoundedCounter): u64 { if (c.current >= c.limit) 0 else c.limit - c.current }
public fun mode(c: &BoundedCounter): u8 { c.mode }
public fun is_flow(c: &BoundedCounter): bool { c.mode == MODE_FLOW }
