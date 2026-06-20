/// altheia::registry
///
/// Admin-gated allowlist of approved adapter package-ids. Policies and
/// agent-execution paths reference it to gate which venue adapters an agent
/// may compose. This is governance, not dispatch — Move has no dynamic
/// dispatch; the registry only answers "is this adapter approved?".
///
/// Removing an adapter is a global kill-switch: every agent loses access to
/// it on the next transaction, independent of per-agent policy revocation.
module altheia::registry;

use sui::vec_set::{Self, VecSet};

public struct AdapterRegistry has key {
    id: UID,
    approved: VecSet<address>,
}

public struct RegistryAdminCap has key, store {
    id: UID,
    registry_id: ID,
}

const ENotAdmin: u64 = 1;

/// Create + share an empty registry; return the admin cap to the caller.
public fun create(ctx: &mut TxContext): RegistryAdminCap {
    let reg = AdapterRegistry { id: object::new(ctx), approved: vec_set::empty() };
    let registry_id = object::id(&reg);
    transfer::share_object(reg);
    RegistryAdminCap { id: object::new(ctx), registry_id }
}

public fun add_adapter(reg: &mut AdapterRegistry, cap: &RegistryAdminCap, pkg: address) {
    assert!(cap.registry_id == object::id(reg), ENotAdmin);
    if (!reg.approved.contains(&pkg)) reg.approved.insert(pkg);
}

public fun remove_adapter(reg: &mut AdapterRegistry, cap: &RegistryAdminCap, pkg: address) {
    assert!(cap.registry_id == object::id(reg), ENotAdmin);
    if (reg.approved.contains(&pkg)) reg.approved.remove(&pkg);
}

public fun is_approved(reg: &AdapterRegistry, pkg: address): bool {
    reg.approved.contains(&pkg)
}

#[test_only]
public fun create_for_testing(ctx: &mut TxContext): RegistryAdminCap { create(ctx) }
