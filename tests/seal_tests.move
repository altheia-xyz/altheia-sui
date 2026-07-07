#[test_only]
module altheia::seal_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use altheia::vault::{Self, Vault};
use altheia::policy::{Self, Policy};
use altheia::actions;

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const DEVICE: address = @0xD0E;      // the Seal unseal authority (device/runtime key)
const ATTACKER: address = @0xBADD;
const ALLOWED_PKG: address = @0xDEEB;
const EXPIRY: u64 = 1_000_000_000;

/// Provision a vault + policy with a Seal unseal authority (DEVICE) registered.
fun setup(): (ts::Scenario, vault::OwnerCap, clock::Clock) {
    let mut scenario = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (v, owner) = vault::provision_open(ts::ctx(&mut scenario));
    let mut p = vault::mint_policy_open(&v, &owner, b"agent-1", vector[ALLOWED_PKG], vector[actions::deepbook_swap()], EXPIRY, ts::ctx(&mut scenario));
    vault::add_asset_cap<SUI>(&v, &owner, &mut p, 100, 500, &clk);
    vault::admin_set_seal_custody(&v, &owner, &mut p, DEVICE, &clk);
    vault::mint_agent_cap_for(&v, &owner, &p, b"agent-1", AGENT, ts::ctx(&mut scenario));
    vault::share_vault(v);
    policy::share(p);
    (scenario, owner, clk)
}

/// A well-formed Seal id: the policy object-id prefix + a suffix.
fun sealed_id(p: &Policy): vector<u8> {
    let mut id = policy::id_bytes(p);
    id.push_back(0xAB);
    id.push_back(0xCD);
    id
}

fun teardown(scenario: ts::Scenario, owner: vault::OwnerCap, p: Policy, clk: clock::Clock) {
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun seal_authorizes_when_live_authority_and_prefixed() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, DEVICE);
    let p = ts::take_shared<Policy>(&scenario);
    assert!(policy::has_seal_custody(&p), 0);
    assert!(policy::seal_unseal_authority(&p) == DEVICE, 1);
    assert!(policy::seal_authorized(&p, DEVICE, sealed_id(&p), &clk), 2);
    teardown(scenario, owner, p, clk);
}

#[test]
fun seal_denies_wrong_sender() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, DEVICE);
    let p = ts::take_shared<Policy>(&scenario);
    assert!(!policy::seal_authorized(&p, ATTACKER, sealed_id(&p), &clk), 0);
    teardown(scenario, owner, p, clk);
}

#[test]
fun seal_denies_wrong_prefix() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, DEVICE);
    let p = ts::take_shared<Policy>(&scenario);
    let bad_id = vector[0x01, 0x02, 0x03, 0x04]; // not this policy's object id
    assert!(!policy::seal_authorized(&p, DEVICE, bad_id, &clk), 0);
    teardown(scenario, owner, p, clk);
}

#[test]
fun seal_denies_when_revoked() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_revoke_policy(&v, &owner, &mut p, &clk);
    assert!(!policy::seal_authorized(&p, DEVICE, sealed_id(&p), &clk), 0);
    ts::return_shared(v);
    teardown(scenario, owner, p, clk);
}

#[test]
fun seal_denies_when_paused() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_pause_policy(&v, &owner, &mut p, &clk);
    assert!(!policy::seal_authorized(&p, DEVICE, sealed_id(&p), &clk), 0);
    ts::return_shared(v);
    teardown(scenario, owner, p, clk);
}

#[test]
fun seal_denies_when_expired() {
    let (mut scenario, owner, mut clk) = setup();
    ts::next_tx(&mut scenario, DEVICE);
    let p = ts::take_shared<Policy>(&scenario);
    clock::set_for_testing(&mut clk, EXPIRY + 1);
    assert!(!policy::seal_authorized(&p, DEVICE, sealed_id(&p), &clk), 0);
    teardown(scenario, owner, p, clk);
}

#[test]
fun seal_denies_when_no_custody_set() {
    // A policy WITHOUT admin_set_seal_custody has no unseal authority => never authorized.
    let mut scenario = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (v, owner) = vault::provision_open(ts::ctx(&mut scenario));
    let p = vault::mint_policy_open(&v, &owner, b"agent-1", vector[ALLOWED_PKG], vector[actions::deepbook_swap()], EXPIRY, ts::ctx(&mut scenario));
    assert!(!policy::has_seal_custody(&p), 0);
    let mut id = policy::id_bytes(&p);
    id.push_back(0xAB);
    assert!(!policy::seal_authorized(&p, DEVICE, id, &clk), 1);
    vault::share_vault(v);
    policy::share(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun set_seal_custody_replaces_authority() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_set_seal_custody(&v, &owner, &mut p, ATTACKER, &clk);
    assert!(!policy::seal_authorized(&p, DEVICE, sealed_id(&p), &clk), 0);   // old authority out
    assert!(policy::seal_authorized(&p, ATTACKER, sealed_id(&p), &clk), 1);  // new authority in
    ts::return_shared(v);
    teardown(scenario, owner, p, clk);
}
