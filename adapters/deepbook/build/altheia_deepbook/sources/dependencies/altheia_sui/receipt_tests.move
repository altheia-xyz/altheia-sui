#[test_only]
module altheia::receipt_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::coin;
use altheia::receipt;
use altheia::registry::{Self, AdapterRegistry};
use altheia::test_support::{Self, AdapterW};

const ADMIN: address = @0xA1;
const RECIPIENT: address = @0xFACE;
const WRONG_RECIPIENT: address = @0xDEAD;

/// Build a registry that approves the test adapter witness, run `body`, clean up.
fun with_approved_registry(approve: bool): (ts::Scenario, AdapterRegistry, registry::RegistryAdminCap) {
    let mut s = ts::begin(ADMIN);
    let cap = registry::create(ts::ctx(&mut s));
    ts::next_tx(&mut s, ADMIN);
    let mut reg = ts::take_shared<AdapterRegistry>(&s);
    if (approve) registry::add_adapter<AdapterW>(&mut reg, &cap);
    (s, reg, cap)
}

#[test]
fun consume_passes_when_approved_and_actual_meets_min() {
    let (mut s, reg, cap) = with_approved_registry(true);
    let r = receipt::new_for_testing(b"a", 100, b"SUI", RECIPIENT, 1, 0);
    let c = coin::mint_for_testing<SUI>(100, ts::ctx(&mut s));
    receipt::consume_with_check<AdapterW, SUI>(test_support::witness(), &reg, r, &c, 99, RECIPIENT);
    test_utils::destroy(c);
    ts::return_shared(reg);
    test_utils::destroy(cap);
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = ::altheia::receipt::ENotApprovedAdapter)]
fun consume_reverts_when_witness_not_approved() {
    let (mut s, reg, cap) = with_approved_registry(false);
    let r = receipt::new_for_testing(b"a", 100, b"SUI", RECIPIENT, 1, 0);
    let c = coin::mint_for_testing<SUI>(100, ts::ctx(&mut s));
    receipt::consume_with_check<AdapterW, SUI>(test_support::witness(), &reg, r, &c, 99, RECIPIENT);
    test_utils::destroy(c);
    ts::return_shared(reg);
    test_utils::destroy(cap);
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = ::altheia::receipt::EUnderMinValue)]
fun consume_reverts_when_actual_below_min() {
    let (mut s, reg, cap) = with_approved_registry(true);
    let r = receipt::new_for_testing(b"a", 100, b"SUI", RECIPIENT, 1, 0);
    let c = coin::mint_for_testing<SUI>(50, ts::ctx(&mut s));
    receipt::consume_with_check<AdapterW, SUI>(test_support::witness(), &reg, r, &c, 99, RECIPIENT);
    test_utils::destroy(c);
    ts::return_shared(reg);
    test_utils::destroy(cap);
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = ::altheia::receipt::ERecipientMismatch)]
fun consume_reverts_on_recipient_mismatch() {
    let (mut s, reg, cap) = with_approved_registry(true);
    let r = receipt::new_for_testing(b"a", 100, b"SUI", RECIPIENT, 1, 0);
    let c = coin::mint_for_testing<SUI>(100, ts::ctx(&mut s));
    receipt::consume_with_check<AdapterW, SUI>(test_support::witness(), &reg, r, &c, 99, WRONG_RECIPIENT);
    test_utils::destroy(c);
    ts::return_shared(reg);
    test_utils::destroy(cap);
    ts::end(s);
}
