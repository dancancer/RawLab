# RawLab X3F native bridge

This static library owns decoder output and exposes it through `rawlab_x3f.h`.
The host copies pixels before freeing the handle. Each render has its own cancel
token; cancellation does not mutate the image handle from a second thread.
Panics and decoding errors are contained at the C boundary. No SPP binary,
Python interpreter or external converter process is needed at runtime.

The decoder source is x3fuse-core commit
`00f9ef206a2d629bca35ceead4b3951833b85d3d` from
<https://github.com/sagwaco/x3fuse-core>. Both Rust and bundled native decoding
sources are pinned by `Cargo.lock`. The local
[`x3f-sys` patch](vendor/x3f-sys/RAWLAB.md) retains that source revision and
parallelizes Merrill work while preserving its ordered floating-point reductions.
Build with CMake's `SONY2FUJI_ENABLE_X3F`
option; the [rendering contract](../docs/x3f-rendering.md) defines admission,
color domains and platform limits. Cargo requires Rust 1.88 or newer. The actual
build toolchain's `rust-docs` component supplies standard-library notices.

## Frozen profile provenance

These are mathematical response parameters and metadata admission profiles,
not photographs or proprietary library code. No source RAW is included.

| Asset | Origin | SHA-256 |
| --- | --- | --- |
| `profiles/dp1s-v1.json` | DP1S empirical v2 response, stripped of experiment paths and per-body diagnostic rules | `bdf95f25f3769c94b34378b87438d9929d7f87e4cb021d3bc7348f9658913d61` |
| `profiles/merrill-neutral-v1.json` | Observed neutral saved-header extension values from the DP2 Merrill reference | `9dff225371ed255ed14a0d94e99a34d35ac10b6dc65b052f7d5176faf6f92275` |
| `profiles/quattro-neutral-v1.json` | Observed neutral SPPA parameter tables from the Quattro reference | `0d92e29df3752a7a73788f8e5c5b9bee9a9d91d01b4204779f420fb23ef2c986` |

The DP1S source parameter artifact had SHA-256
`dab740870e82c7fd275510dcf870f1ba02438b34712d02882c21c2f2bd60fe53`.
Its independent Python implementation is retained under
`experiments/x3f-spp-v1/`. `tests/fixtures/dp1s-response.json` contains synthetic
scene samples, controls and expected output from that implementation.
`tests/fixtures/quattro-neutral.sppa` contains only the 4,856-byte settings
section needed to exercise table offsets, types, unknown tags and truncation.
A profile change requires a new rendering identity and held-out validation;
matching these fixtures alone does not demonstrate SPP parity.

## Merrill performance verification

Use the same admitted, neutral Merrill source and release toolchain for both
versions. The ignored benchmark measures the complete bridge decode, before
the output hash or optional reference comparison. Keep CPU load comparable and
alternate versions when comparing timings. A small exported image still develops
the complete RAW first.

```sh
RAWLAB_X3F_BENCH_RAW=/path/to/Merrill.X3F \
RAWLAB_X3F_BENCH_OUTPUT=/temporary/baseline.f32 \
cargo test --release --locked --manifest-path lutools/x3f-bridge/Cargo.toml \
  --lib benchmark::merrill_render -- --exact --ignored --nocapture
```

Run the candidate with `RAWLAB_X3F_BENCH_REFERENCE=/temporary/baseline.f32`
instead of `RAWLAB_X3F_BENCH_OUTPUT` to compare every output byte. Use
`RAWLAB_X3F_BENCH_REPEATS` for 1–20 measurements (default 3). The separate ignored
`benchmark::merrill_cancel_does_not_publish_pixels` checks cancellation during a
real decode. Benchmark files are temporary outputs and never belong in the repo.

## Notices

`collect_licenses.py` collects license files from the exact packages resolved by
Cargo and fails if any package lacks a notice. The package list includes build
dependencies. The zune 0.4 crates omit their notice file from the crates.io
archive, so the original upstream notices are retained in `licenses/`; they
retain the Apache-2.0/MIT choice. The generated bundle contains Apache-2.0 text
and all upstream notices, plus the actual Rust runtime copyright documentation.
RawLab's bridge code follows the repository license; upstream components retain
their own licenses.

The retained zune notices were read from upstream commit
`fa2c767a01d7d9373911d0bf63e0588553d67e0e` at
<https://github.com/etemesi254/zune-image/blob/fa2c767a01d7d9373911d0bf63e0588553d67e0e/LICENSE.md>.
The exact crate versions remain those in `Cargo.lock`.
