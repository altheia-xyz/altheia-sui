/// altheia::registry
///
/// Admin-gated allowlist of approved adapter witnesses. The hot-potato
/// `receipt::WithdrawalReceipt` can only be closed by an adapter whose
/// witness type is in this set, so the registry decides which venue
/// adapters an agent may route through.
///
/// Keyed by witness `TypeName`, not raw address: the witness type binds to
/// the exact adapter module (and carries its package id), and Move can read
/// it on-chain via `type_name::get<W>()` — no address parsing, no dynamic
/// dispatch. Removing an adapter is a global kill-switch: every agent loses
/// access on its next transaction, independent of per-agent policy revocation.
module altheia::registry;

use std::type_name::{Self, TypeName};
use sui::vec_set::{Self, VecSet};

public struct AdapterRegistry has key {
    id: UID,
    approved: VecSet<TypeName>,
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

/// Approve adapter witness `W` (e.g. `add_adapter<DeepBookWitness>`).
public fun add_adapter<W>(reg: &mut AdapterRegistry, cap: &RegistryAdminCap) {
    assert!(cap.registry_id == object::id(reg), ENotAdmin);
    let tn = type_name::get<W>();
    if (!reg.approved.contains(&tn)) reg.approved.insert(tn);
}

/// Revoke adapter witness `W` — global kill-switch for that venue.
public fun remove_adapter<W>(reg: &mut AdapterRegistry, cap: &RegistryAdminCap) {
    assert!(cap.registry_id == object::id(reg), ENotAdmin);
    let tn = type_name::get<W>();
    if (reg.approved.contains(&tn)) reg.approved.remove(&tn);
}

/// Read path used by `receipt::consume_with_check`: is this witness approved?
public fun is_approved(reg: &AdapterRegistry, tn: &TypeName): bool {
    reg.approved.contains(tn)
}

/// Convenience for off-chain / test callers that hold the witness type.
public fun is_approved_type<W>(reg: &AdapterRegistry): bool {
    reg.approved.contains(&type_name::get<W>())
}

#[test_only]
public fun create_for_testing(ctx: &mut TxContext): RegistryAdminCap { create(ctx) }
