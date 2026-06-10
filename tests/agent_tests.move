#[test_only]
module altheia::agent_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use altheia::vault::{Self, Vault};
use altheia::agent::{Self, AgentCap};

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;

#[test]
fun test_mint_agent_cap_delivers_to_agent_address() {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault<SUI>>(&scenario);
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
    vault::mint_agent_cap(&v, &owner, pid, b"agent-1", AGENT, ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    assert!(agent::agent_id(&cap) == b"agent-1", 0);
    assert!(agent::vault_id(&cap) == vault::vault_id(&v), 1);
    assert!(agent::policy_id(&cap) == pid, 2);
    test_utils::destroy(cap);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}
