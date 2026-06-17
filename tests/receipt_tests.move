#[test_only]
module altheia::receipt_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use sui::coin;
use altheia::vault::{Self, Vault};
use altheia::policy::Policy;
use altheia::agent::AgentCap;
use altheia::receipt;

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const RECIPIENT: address = @0xFACE;
const WRONG_RECIPIENT: address = @0xDEAD;
const ALLOWED_PKG: address = @0xDEEB;

fun mint_simple_receipt(scenario: &mut ts::Scenario, clk: &clock::Clock) {
    let mut v = ts::take_shared<Vault<SUI>>(scenario);
    let cap = ts::take_from_sender<AgentCap>(scenario);
    let mut p = ts::take_shared<Policy>(scenario);
    let (coin_out, r) = vault::withdraw_with_receipt(
        &mut v,
        &cap,
        &mut p,
        50,
        ALLOWED_PKG,
        RECIPIENT,
        b"SUI",
        clk,
        ts::ctx(scenario),
    );
    receipt::attest_simple(r, RECIPIENT);
    test_utils::destroy(coin_out);
    test_utils::destroy(cap);
    ts::return_shared(p);
    ts::return_shared(v);
}

fun setup(): (ts::Scenario, vault::OwnerCap, clock::Clock) {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let funds = coin::mint_for_testing<SUI>(1_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, funds);
    let pid = vault::mint_policy(
        &v, &owner, b"agent-1", 100, 500, vector[ALLOWED_PKG],
        1_000_000_000, &clk, ts::ctx(&mut scenario),
    );
    vault::mint_agent_cap(&v, &owner, pid, b"agent-1", AGENT, ts::ctx(&mut scenario));
    ts::return_shared(v);
    (scenario, owner, clk)
}

#[test]
fun test_attest_simple_closes_receipt_when_recipient_matches() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    mint_simple_receipt(&mut scenario, &clk);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::receipt::ERecipientMismatch)]
fun test_attest_simple_aborts_on_recipient_mismatch() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let (coin_out, r) = vault::withdraw_with_receipt(
        &mut v, &cap, &mut p, 50, ALLOWED_PKG, RECIPIENT, b"SUI", &clk, ts::ctx(&mut scenario),
    );
    receipt::attest_simple(r, WRONG_RECIPIENT);
    test_utils::destroy(coin_out);
    test_utils::destroy(cap);
    ts::return_shared(p);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// Value-conservation MATH (the bug-prone part) is unit-tested as a pure
// function — no DeepBook Pool to construct. The Pool-reading wrapper
// (attest_value_conservation) is integration-tested on testnet against the
// real SUI/DBUSDC pool. Numbers below are testnet-verified (mid_price=794000,
// SUI base_scalar=1e9 → SUI ≈ 0.794 DBUSDC).

#[test]
fun compute_min_out_matches_deepbook_scaling() {
    // 1 SUI (1e9 base) @ 0 slippage -> 794000 DBUSDC base (= 0.794 USDC)
    assert!(receipt::compute_min_out(1_000_000_000, 794_000, 1_000_000_000, 0) == 794_000, 0);
    // 1% slippage -> 794000 * 0.99 = 786060
    assert!(receipt::compute_min_out(1_000_000_000, 794_000, 1_000_000_000, 100) == 786_060, 1);
    // half a SUI -> half the floor
    assert!(receipt::compute_min_out(500_000_000, 794_000, 1_000_000_000, 0) == 397_000, 2);
}

#[test]
fun compute_min_out_zero_amount_is_zero() {
    assert!(receipt::compute_min_out(0, 794_000, 1_000_000_000, 100) == 0, 0);
}

#[test]
fun compute_min_out_no_overflow_large() {
    // 1e12 * 794000 = 7.94e17 (fits u128); /1e9 = 794_000_000; *0.995 = 790_030_000
    assert!(receipt::compute_min_out(1_000_000_000_000, 794_000, 1_000_000_000, 50) == 790_030_000, 0);
}
