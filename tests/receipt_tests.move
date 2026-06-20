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

// consume_with_check is the generic, protocol-agnostic value gate. Adapters
// (deepbook_adapter etc.) compute actual/min and call it. The DeepBook
// scaling math + its tests now live in the adapter (altheia-sui-demo).

#[test]
fun consume_with_check_passes_when_actual_meets_min() {
    let r = receipt::new_for_testing(b"a", 100, b"SUI", RECIPIENT, 1, 0);
    receipt::consume_with_check(r, 100, 99, RECIPIENT);
}

#[test]
#[expected_failure(abort_code = ::altheia::receipt::EUnderMinValue)]
fun consume_with_check_reverts_when_actual_below_min() {
    let r = receipt::new_for_testing(b"a", 100, b"SUI", RECIPIENT, 1, 0);
    receipt::consume_with_check(r, 50, 99, RECIPIENT);
}

#[test]
#[expected_failure(abort_code = ::altheia::receipt::ERecipientMismatch)]
fun consume_with_check_reverts_on_recipient_mismatch() {
    let r = receipt::new_for_testing(b"a", 100, b"SUI", RECIPIENT, 1, 0);
    receipt::consume_with_check(r, 100, 99, WRONG_RECIPIENT);
}
