#[test_only]
/// Property + unit tests for altheia::policy.
///
/// Status: placeholder. Tests land May 25-28 (basic cap flow), Jun 16-17
/// (property tests on caps + revocation + expiry + transfer-blocking)
/// per altheia-plan/01_PHASES/sui/SHIP_PLAN_2026_05_22.md.
module altheia::policy_tests;

// TODO(May 25): basic capability flow
//   - mint policy with caps + scope + expiry
//   - assert version == 0, !revoked
//   - mint AgentCap
//   - consume under cap allowed
//   - consume over per_tx_cap aborts ECapExceeded
//   - consume to disallowed package aborts EPackageNotAllowed
//   - revoke
//   - consume after revoke aborts EPolicyRevoked

// TODO(Jun 16-17): property tests
//   - any sequence of (consume <= per_tx_cap) totaling > per_day_cap is rejected
//   - daily window rolls correctly across epoch boundaries
//   - revocation is idempotent (revoke twice doesn't blow up)
//   - expiry is honored at boundary (now_ms == expires_at_ms aborts)
//   - update_caps bumps version monotonically
//   - policy object cannot be transferred away from owner
