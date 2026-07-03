#[test_only]
module altheia::policy_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use altheia::vault::{Self, Vault};
use altheia::policy::{Self, Policy};
use altheia::agent::AgentCap;
use altheia::actions;

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const ALLOWED_PKG: address = @0xDEEB;
const DISALLOWED_PKG: address = @0xBADD;

/// Provision a vault + policy capping SUI (per_tx, per_day), allowing the swap
/// action on ALLOWED_PKG, with an AgentCap for AGENT. Vault + policy shared.
fun setup_with_caps(per_tx: u64, per_day: u64): (ts::Scenario, vault::OwnerCap, clock::Clock) {
    let mut scenario = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (vault, owner) = vault::provision_open(ts::ctx(&mut scenario));
    let mut p = vault::mint_policy_open(&vault, &owner, b"agent-1", vector[ALLOWED_PKG], vector[actions::deepbook_swap()], 1_000_000_000, ts::ctx(&mut scenario));
    vault::add_asset_cap<SUI>(&vault, &owner, &mut p, per_tx, per_day, &clk);
    vault::mint_agent_cap_for(&vault, &owner, &p, b"agent-1", AGENT, ts::ctx(&mut scenario));
    vault::share_vault(vault);
    policy::share(p);
    (scenario, owner, clk)
}

#[test]
fun test_check_and_consume_passes_under_cap() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 50, ALLOWED_PKG, &clk);
    assert!(policy::spent_today<SUI>(&p) == 50, 0);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::ECapExceededPerTx)]
fun test_check_and_consume_aborts_over_per_tx_cap() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 101, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::EPackageNotAllowed)]
fun test_check_and_consume_aborts_on_disallowed_package() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 50, DISALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::EPolicyRevoked)]
fun test_check_and_consume_aborts_after_revoke() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_revoke_policy(&v, &owner, &mut p, &clk);
    ts::return_shared(v);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 10, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::ECapExceededPerDay)]
fun test_check_and_consume_aborts_over_per_day_cap() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let mut i = 0;
    while (i < 5) { policy::check_and_consume<SUI>(&mut p, &cap, 100, ALLOWED_PKG, &clk); i = i + 1; };
    policy::check_and_consume<SUI>(&mut p, &cap, 100, ALLOWED_PKG, &clk); // 600 > 500
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_per_tx_cap_zero_is_optional() {
    let (mut scenario, owner, clk) = setup_with_caps(0, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 400, ALLOWED_PKG, &clk);
    assert!(policy::spent_today<SUI>(&p) == 400, 0);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

/// T1: with per_tx=0 (no per-tx sub-limit), a near-u64::MAX amount must abort
/// with the clean ECapExceededPerDay, not a raw arithmetic-overflow error.
#[test]
#[expected_failure(abort_code = ::altheia::policy::ECapExceededPerDay)]
fun test_check_and_consume_daily_overflow_is_clean_cap_error() {
    let (mut scenario, owner, clk) = setup_with_caps(0, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 100, ALLOWED_PKG, &clk);
    policy::check_and_consume<SUI>(&mut p, &cap, 18446744073709551615, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

/// T2: re-setting an existing asset cap must preserve cumulative spent_today,
/// so an operator (or a compromised operator key) cannot reset the daily
/// budget by re-issuing the cap mid-day.
#[test]
fun test_add_asset_cap_reset_preserves_spent_today() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    {
        let cap = ts::take_from_sender<AgentCap>(&scenario);
        let mut p = ts::take_shared<Policy>(&scenario);
        policy::check_and_consume<SUI>(&mut p, &cap, 50, ALLOWED_PKG, &clk);
        test_utils::destroy(cap);
        ts::return_shared(p);
    };
    ts::next_tx(&mut scenario, OPERATOR);
    {
        let v = ts::take_shared<Vault>(&scenario);
        let mut p = ts::take_shared<Policy>(&scenario);
        vault::add_asset_cap<SUI>(&v, &owner, &mut p, 200, 1000, &clk);
        assert!(policy::spent_today<SUI>(&p) == 50, 0);
        ts::return_shared(v);
        ts::return_shared(p);
    };
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

/// T4: the value guard must reject nonsense params (slippage > 100%, or a
/// zero base_scalar that would divide-by-zero in the floor math).
#[test]
#[expected_failure(abort_code = ::altheia::policy::EInvalidValueGuard)]
fun test_value_guard_rejects_bps_over_10000() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_set_value_guard(&v, &owner, &mut p, 10001, 1_000_000_000, &clk);
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::EInvalidValueGuard)]
fun test_value_guard_rejects_zero_base_scalar() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_set_value_guard(&v, &owner, &mut p, 100, 0, &clk);
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_value_guard_accepts_valid_params() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_set_value_guard(&v, &owner, &mut p, 100, 1_000_000_000, &clk);
    assert!(policy::max_slippage_bps(&p) == 100, 0);
    assert!(policy::base_scalar(&p) == 1_000_000_000, 1);
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// === Debt module (lending, STOCK case) ===

#[test]
fun debt_borrow_to_ceiling_and_repay() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::set_debt_cap<SUI>(&mut p, 1000, &clk);
    policy::consume_debt<SUI>(&mut p, &cap, 600, ALLOWED_PKG, &clk);
    assert!(policy::borrowed<SUI>(&p) == 600, 0);
    policy::consume_debt<SUI>(&mut p, &cap, 400, ALLOWED_PKG, &clk); // up to ceiling
    assert!(policy::borrowed<SUI>(&p) == 1000, 1);
    policy::release_debt<SUI>(&mut p, 300); // repay
    assert!(policy::borrowed<SUI>(&p) == 700, 2);
    policy::consume_debt<SUI>(&mut p, &cap, 300, ALLOWED_PKG, &clk); // re-borrow the freed room
    assert!(policy::borrowed<SUI>(&p) == 1000, 3);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::EBorrowCapExceeded)]
fun debt_over_ceiling_aborts() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::set_debt_cap<SUI>(&mut p, 1000, &clk);
    policy::consume_debt<SUI>(&mut p, &cap, 1001, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// Default-deny: an asset with no debt cap cannot be borrowed.
#[test]
#[expected_failure(abort_code = ::altheia::policy::EBorrowNotAllowed)]
fun debt_no_cap_aborts() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::consume_debt<SUI>(&mut p, &cap, 1, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// Re-setting the debt cap preserves outstanding borrowed (can't wipe debt).
#[test]
fun debt_cap_reset_preserves_borrowed() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::set_debt_cap<SUI>(&mut p, 1000, &clk);
    policy::consume_debt<SUI>(&mut p, &cap, 500, ALLOWED_PKG, &clk);
    policy::set_debt_cap<SUI>(&mut p, 2000, &clk);
    assert!(policy::borrowed<SUI>(&p) == 500, 0);
    assert!(policy::borrow_cap<SUI>(&p) == 2000, 1);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_allowlist_allows_and_denies() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let p = ts::take_shared<Policy>(&scenario);
    assert!(policy::allows(&p, actions::deepbook_swap()), 0);
    assert!(!policy::allows(&p, actions::transfer()), 1);
    assert!(!policy::allows(&p, actions::deepbook_limit_order()), 2);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_action_params_roundtrip() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let band = vector[10u64, 1_000u64, 50u64];
    vault::admin_set_action_params(&v, &owner, &mut p, actions::deepbook_limit_order(), band, &clk);
    assert!(policy::has_action_params(&p, actions::deepbook_limit_order()), 0);
    let got = policy::action_params(&p, actions::deepbook_limit_order());
    assert!(got == vector[10u64, 1_000u64, 50u64], 1);
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::EPolicyPaused)]
fun test_check_and_consume_aborts_when_paused() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_pause_policy(&v, &owner, &mut p, &clk);
    ts::return_shared(v);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 10, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}
