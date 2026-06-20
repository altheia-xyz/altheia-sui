#[test_only]
module altheia_deepbook::deepbook_adapter_tests;

use altheia_deepbook::deepbook_adapter;

// Pure scaling math (testnet-verified: SUI base_scalar 1e9, mid_price 794000
// -> SUI ~ 0.794 DBUSDC). The pool-reading attest is integration-tested.

#[test]
fun min_out_scaling() {
    assert!(deepbook_adapter::compute_min_out(1_000_000_000, 794_000, 1_000_000_000, 0) == 794_000, 0);
    assert!(deepbook_adapter::compute_min_out(1_000_000_000, 794_000, 1_000_000_000, 100) == 786_060, 1);
    assert!(deepbook_adapter::compute_min_out(500_000_000, 794_000, 1_000_000_000, 0) == 397_000, 2);
}

#[test]
fun min_out_zero_amount() {
    assert!(deepbook_adapter::compute_min_out(0, 794_000, 1_000_000_000, 100) == 0, 0);
}

#[test]
fun min_out_no_overflow() {
    assert!(deepbook_adapter::compute_min_out(1_000_000_000_000, 794_000, 1_000_000_000, 50) == 790_030_000, 0);
}

// quote->base direction: base_out = quote_in * 1e9 / mid_price.
#[test]
fun min_base_out_scaling() {
    // mid_price == 1e9 => 1:1; slippage 0 returns the full expected.
    assert!(deepbook_adapter::compute_min_base_out(1_000_000_000, 1_000_000_000, 0) == 1_000_000_000, 0);
    // 1% slippage floor.
    assert!(deepbook_adapter::compute_min_base_out(1_000_000_000, 1_000_000_000, 100) == 990_000_000, 1);
    // DEEP/SUI testnet-shaped: 0.5 SUI spent at mid 2.362e10 -> ~21.16 DEEP.
    assert!(deepbook_adapter::compute_min_base_out(500_000_000, 23_620_000_000, 0) == 21_168_501, 2);
}
