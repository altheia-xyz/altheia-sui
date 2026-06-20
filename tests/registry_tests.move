#[test_only]
module altheia::registry_tests;

use sui::test_scenario as ts;
use sui::test_utils;
use altheia::registry::{Self, AdapterRegistry};

const ADMIN: address = @0xA1;
const PKG: address = @0xDEEB;

#[test]
fun add_remove_approved() {
    let mut s = ts::begin(ADMIN);
    let cap = registry::create(ts::ctx(&mut s));
    ts::next_tx(&mut s, ADMIN);
    let mut reg = ts::take_shared<AdapterRegistry>(&s);
    assert!(!registry::is_approved(&reg, PKG), 0);
    registry::add_adapter(&mut reg, &cap, PKG);
    assert!(registry::is_approved(&reg, PKG), 1);
    registry::remove_adapter(&mut reg, &cap, PKG);
    assert!(!registry::is_approved(&reg, PKG), 2);
    ts::return_shared(reg);
    test_utils::destroy(cap);
    ts::end(s);
}
