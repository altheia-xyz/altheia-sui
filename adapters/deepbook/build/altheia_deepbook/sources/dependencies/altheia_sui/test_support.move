#[test_only]
module altheia::test_support;

/// Stand-in adapter witness for core tests: approve it in the registry to
/// exercise the gated `receipt::consume_with_check` path.
public struct AdapterW has drop {}

public fun witness(): AdapterW { AdapterW {} }
