#[test_only]
module altheia::policy_module_tests;

use altheia::policy_module as pm;

const DAY: u64 = 86_400_000;

// FLOW: consume up to the limit; remaining tracks it.
#[test]
fun flow_consume_to_limit() {
    let mut c = pm::new_flow(500, DAY, 0);
    pm::consume(&mut c, 100, 0);
    assert!(pm::current(&c) == 100, 0);
    pm::consume(&mut c, 400, 0);
    assert!(pm::current(&c) == 500, 1);
    assert!(pm::remaining(&c) == 0, 2);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy_module::ELimitExceeded)]
fun flow_over_limit_aborts() {
    let mut c = pm::new_flow(500, DAY, 0);
    pm::consume(&mut c, 501, 0);
}

// FLOW resets once the window elapses.
#[test]
fun flow_resets_after_window() {
    let mut c = pm::new_flow(500, DAY, 0);
    pm::consume(&mut c, 500, 0);
    pm::consume(&mut c, 100, DAY); // window elapsed -> reset -> 100 ok
    assert!(pm::current(&c) == 100, 0);
}

// Checked add: a near-u64::MAX amount aborts with the clean ELimitExceeded,
// not a raw arithmetic overflow (carries the hardening fix into the primitive).
#[test]
#[expected_failure(abort_code = ::altheia::policy_module::ELimitExceeded)]
fun flow_huge_amount_clean_error() {
    let mut c = pm::new_flow(500, DAY, 0);
    pm::consume(&mut c, 100, 0);
    pm::consume(&mut c, 18446744073709551615, 0);
}

// STOCK: up to the ceiling, release brings it back down (borrow/repay).
#[test]
fun stock_up_and_down() {
    let mut c = pm::new_stock(1000);
    pm::consume(&mut c, 600, 0);
    pm::consume(&mut c, 400, 0);
    assert!(pm::current(&c) == 1000, 0);
    pm::release(&mut c, 300);
    assert!(pm::current(&c) == 700, 1);
    pm::consume(&mut c, 300, 0);
    assert!(pm::current(&c) == 1000, 2);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy_module::ELimitExceeded)]
fun stock_over_ceiling_aborts() {
    let mut c = pm::new_stock(1000);
    pm::consume(&mut c, 1001, 0);
}

// release is saturating — never underflows below zero.
#[test]
fun release_saturating() {
    let mut c = pm::new_stock(1000);
    pm::consume(&mut c, 100, 0);
    pm::release(&mut c, 500);
    assert!(pm::current(&c) == 0, 0);
}

// preserve keeps accumulated current + window when the limit is re-set.
#[test]
fun preserve_keeps_current() {
    let mut c = pm::new_flow(500, DAY, 0);
    pm::consume(&mut c, 50, 0);
    let c2 = pm::preserve(&c, 1000);
    assert!(pm::current(&c2) == 50, 0);
    assert!(pm::limit(&c2) == 1000, 1);
}

// Lowering the limit BELOW current spend -> next consume aborts cleanly (no underflow).
#[test]
#[expected_failure(abort_code = ::altheia::policy_module::ELimitExceeded)]
fun preserve_below_current_then_consume_aborts() {
    let mut c = pm::new_flow(500, DAY, 0);
    pm::consume(&mut c, 50, 0);
    let mut c2 = pm::preserve(&c, 30);
    pm::consume(&mut c2, 1, 0);
}

// would_exceed: pure check, honors the FLOW window roll, no mutation.
#[test]
fun would_exceed_flow() {
    let mut c = pm::new_flow(500, DAY, 0);
    pm::consume(&mut c, 400, 0);
    assert!(!pm::would_exceed(&c, 100, 0), 0); // 400+100 = 500 ok
    assert!(pm::would_exceed(&c, 101, 0), 1);  // 501 > 500
    assert!(!pm::would_exceed(&c, 500, DAY), 2); // window elapsed -> resets -> 500 ok
    assert!(pm::current(&c) == 400, 3);          // not mutated
}

// Thin self-contained checks.
#[test] fun max_ok() { pm::assert_max(100, 100); }
#[test] #[expected_failure(abort_code = ::altheia::policy_module::EOverMax)]
fun max_aborts() { pm::assert_max(101, 100); }
#[test] fun range_ok() { pm::assert_in_range(5, 1, 10); }
#[test] #[expected_failure(abort_code = ::altheia::policy_module::EOutOfRange)]
fun range_below_aborts() { pm::assert_in_range(0, 1, 10); }
#[test] #[expected_failure(abort_code = ::altheia::policy_module::EOutOfRange)]
fun range_above_aborts() { pm::assert_in_range(11, 1, 10); }
#[test] fun before_ok() { pm::assert_before(5, 10); }
#[test] #[expected_failure(abort_code = ::altheia::policy_module::EExpired)]
fun before_aborts() { pm::assert_before(10, 10); }
