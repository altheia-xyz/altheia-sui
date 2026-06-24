#[test_only]
module altheia::audit_tests;

// Audit events are emit-only. Their correctness is verified indirectly
// through the other test suites — each policy/receipt path emits an event
// at decision time. This file is a compile-time pin for the audit
// module's package-visible surface: if the emit signatures drift, the
// other test suites won't compile.

use altheia::audit;

#[test]
fun test_audit_emit_signatures_link() {
    audit::emit_allowed(b"agent-1", 1, 100, @0x0, 0);
    audit::emit_revoked(b"agent-1", 1, 0);
    audit::emit_changed(b"agent-1", audit::kind_pause(), 1, 2, 0);
    audit::emit_withdrawal_attested(b"agent-1", 100, 95, @0x1, 1, 0);
}

/// The five PolicyChanged discriminants must be distinct, else they can't
/// disambiguate the change classes they name.
#[test]
fun test_policy_change_kinds_distinct() {
    let kinds = vector[
        audit::kind_pause(), audit::kind_unpause(), audit::kind_cap(),
        audit::kind_value_guard(), audit::kind_actions(),
    ];
    let mut i = 0;
    while (i < kinds.length()) {
        let mut j = i + 1;
        while (j < kinds.length()) {
            assert!(kinds[i] != kinds[j], 0);
            j = j + 1;
        };
        i = i + 1;
    };
}
