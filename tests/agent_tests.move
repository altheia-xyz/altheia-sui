#[test_only]
module altheia::agent_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use altheia::vault;
use altheia::policy;
use altheia::agent::{Self, AgentCap};

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;

#[test]
fun test_mint_agent_cap_delivers_to_agent_address() {
    let mut scenario = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (vault, owner) = vault::provision_open(ts::ctx(&mut scenario));
    let mut p = vault::mint_policy_open(&vault, &owner, b"agent-1", vector[@0x0], vector[], 1_000_000_000, ts::ctx(&mut scenario));
    vault::add_asset_cap<SUI>(&vault, &owner, &mut p, 100, 500, &clk);
    let pid = object::id(&p);
    let vid = vault::vault_id(&vault);
    vault::mint_agent_cap_for(&vault, &owner, &p, b"agent-1", AGENT, ts::ctx(&mut scenario));
    vault::share_vault(vault);
    policy::share(p);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    assert!(agent::agent_id(&cap) == b"agent-1", 0);
    assert!(agent::vault_id(&cap) == vid, 1);
    assert!(agent::policy_id(&cap) == pid, 2);
    test_utils::destroy(cap);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}
