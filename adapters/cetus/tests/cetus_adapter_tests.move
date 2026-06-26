#[test_only]
module altheia_cetus::cetus_adapter_tests;

use altheia_cetus::cetus_adapter;

// Pure value-floor math: min_out = spent * min_rate / 1e9. The pool-reading
// flash-swap path is integration-tested against a live Cetus pool, not here.
#[test]
fun min_out_from_rate_scaling() {
    // rate 0.02 out/in (2e7 scaled) on 1e9 input -> 2e7 out.
    assert!(cetus_adapter::min_out_from_rate(1_000_000_000, 20_000_000) == 20_000_000, 0);
    // partial 0.476 in at floor 0.015 -> 7.14e6.
    assert!(cetus_adapter::min_out_from_rate(476_000_000, 15_000_000) == 7_140_000, 1);
    assert!(cetus_adapter::min_out_from_rate(0, 15_000_000) == 0, 2);
}
