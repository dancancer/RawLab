# RawLab decoder patch

This directory retains the `crates/x3f-sys` source and synthetic test fixtures
from x3fuse-core commit `00f9ef206a2d629bca35ceead4b3951833b85d3d`.
`LICENSE` and `README.md` come from that repository's root. The package metadata
in `Cargo.toml` expands the original workspace values so the crate can build
independently. The original Apache-2.0 license remains in force.

RawLab's bridge applies this crate with Cargo's source patch mechanism. It does
not edit Cargo's shared checkout or require a patched upstream download.

The local changes preserve the existing Merrill arithmetic and output identity:

- `src/cr_offset.rs`: calculate each of the eight workers' row contributions in
  parallel, then accumulate each contribution in the original scale, worker and
  patch order. Workers' windows overlap, so neither concurrent writes nor summing
  each worker's contributions before merging is valid. Single-worker pools and
  wasm retain serial execution. Scratch ownership stays within each worker.
- `src/float_front.rs`: run the final highlight repair on independent rows after
  the ordered saturation cleanup and donor LUT accumulation have finished; detect
  despeckle records in parallel and join them in worker order before the original
  sequential repair. Run the pinned highlight and despeckle oracles at one, two
  and four threads.
- `src/cr_offset/parallel_tests.rs`: compare serial and parallel pixels and
  statistics for a synthetic image with overlapping workers and nonzero offsets,
  at one, two and four threads, with the original pixel hash also pinned on
  ARM64 macOS. The explicitly ignored scalability benchmark is
  a manual check for an idle machine, not a timing gate in CI.
- `src/float_front/parallel_tests.rs`: compare all highlight pixels, saturation
  and dense maps, and all despeckle records and repaired pixels across thread
  counts, including row padding and nonzero repairs.

All other source and fixtures are unchanged. The original stage and kernel
regressions remain available from the bridge's locked dependency graph:

```sh
cargo test --release --locked --manifest-path lutools/x3f-bridge/Cargo.toml -p x3f-sys --lib
```

The CMake `x3f_parallel_contracts` test runs the thread-count regressions on all
supported desktop targets. `x3f_decoder_contracts` also runs the complete original
oracle suite on ARM64 macOS, where those reference hashes were recorded. Some
unmodified upstream oracle hashes differ with Windows' software FMA/libm; they
are not portable exact-output expectations. Real-image comparisons use an
unmodified baseline built on the same platform, without loosening the byte
comparison. The upstream tests that require external photographs still report
their missing fixture coverage separately.
