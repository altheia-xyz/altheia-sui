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
    audit::emit_denied(b"agent-1", 1, 100, @0x0, b"per_tx_cap", 0);
    audit::emit_revoked(b"agent-1", 1, 0);
    audit::emit_updated(b"agent-1", 1, 2, 0);
    audit::emit_withdrawal_attested(b"agent-1", 100, 95, @0x1, 1, 0);
}
