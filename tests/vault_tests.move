#[test_only]
module altheia::vault_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use sui::coin;
use altheia::vault::{Self, Vault, OwnerCap};
use altheia::policy::Policy;
use altheia::agent::AgentCap;
use altheia::receipt::{Self, WithdrawalReceipt};

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const RECIPIENT: address = @0xFACE;

#[test]
fun test_provision_creates_vault_and_returns_owner() {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_deposit_increases_balance() {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let c = coin::mint_for_testing<SUI>(1_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, c);
    assert!(vault::balance(&v) == 1_000, 0);
    ts::return_shared(v);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_withdraw_with_receipt_returns_coin_and_receipt() {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let funds = coin::mint_for_testing<SUI>(1_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, funds);
    let pid = vault::mint_policy(
        &v,
        &owner,
        b"agent-1",
        100,
        500,
        vector[@0x0],
        1_000_000_000,
        &clk,
        ts::ctx(&mut scenario),
    );
    vault::mint_agent_cap(
        &v,
        &owner,
        pid,
        b"agent-1",
        AGENT,
        ts::ctx(&mut scenario),
    );
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let (coin_out, r) = vault::withdraw_with_receipt(
        &mut v,
        &cap,
        &mut p,
        50,
        @0x0,
        RECIPIENT,
        b"SUI",
        &clk,
        ts::ctx(&mut scenario),
    );
    receipt::attest_simple(r, RECIPIENT);
    test_utils::destroy(coin_out);
    test_utils::destroy(cap);
    ts::return_shared(p);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}
