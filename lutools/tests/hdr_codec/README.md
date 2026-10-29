# Apple HDR codec probe

This is the HDR-00 feasibility harness, separate from the shipping SDR decoder.
It does not enable HDR import, advertise client support, or change existing rendering.
The [technical design](../../../docs/design/hdr-photos/technical-design.md) owns the intended product contract.

## Reproduce

Use the primary workspace's shared download/source cache and a task-owned temporary
build directory. The runner verifies the pinned dependency archives, builds
static JPEG/Ultra HDR for the selected architecture/SDK/minimum OS, checks the link
closure, and saves licenses, logs and provenance under the supplied build directory.
The product and harness pins live in `lutools/cmake/hdr-codec-dependencies.json`;
both use `hdr_sources.py` to verify and share downloaded sources.
It never selects, boots, resets or deletes a device.

```sh
python3 lutools/tests/hdr_codec/run.py \
  --target macos-arm64 \
  --cache-root "$RAWLAB_PRIMARY_WORKSPACE/.cache/shared" \
  --build-root "$RAWLAB_PRIMARY_WORKSPACE/.cache/tmp/hdr-codec" \
  --run-tests
```

Set `RAWLAB_PRIMARY_WORKSPACE` to the main checkout, not another project's checkout.
Targets: `macos-arm64`, `macos-x86_64`, `ios-arm64`,
`ios-simulator-arm64`, `ios-simulator-x86_64`. Device arm64 is build-only here.
Simulator runs additionally require `--device-udid` for an explicitly task-owned,
already booted simulator. A translated x86_64 run on arm64 is not physical Intel acceptance.
Current SDK compilation is not minimum-OS runtime acceptance.

Add `--fixture-dir` only for an explicitly authorized, read-only directory of HDR
phone HEIC/JPEG files. Each input becomes a separate CTest case. SDR files should
not be placed in this positive-only external set. Originals are neither rewritten
nor copied into source; record their hash and provenance in task evidence.

Public Android originals are pinned in `public-fixtures.json` with source pages,
attribution, license URLs, capture claims and hashes. Fetch only missing originals
into the primary shared cache; existing files with a mismatched hash are rejected.

```sh
python3 lutools/tests/hdr_codec/public_fixtures.py \
  --directory "$RAWLAB_PRIMARY_WORKSPACE/.cache/shared/hdr-photos/public-v1" --fetch
```

Pass that directory as `--public-fixture-dir` to `run.py`. It checks the manifest,
physical XMP namespace and dimensions before testing, and verifies original hashes
and timestamps afterward. `public_fixtures.py --test-binary <hdr_image_tests>` also
runs the production preview decoder. Neither path certifies A08 round-trip quality.
Use `--final-fixture <original>` separately for full-resolution production identity
and exposure checks. Keep the resulting logs/provenance outside the repository.

## Coverage

- Generated ISO JPEG and HEIC, scalar/RGB gain maps, EXIF rotation, truncated auxiliary data.
- Explicit HDR expansion versus the system's default SDR representation, finite float
  output and distinct HDR/SDR canvases.
- Pinned libultrahdr JPEG encoding with ISO/XMP and an explicit authored capacity;
  native and library decoders provide separate observations.
- The production `hdr_image_decode` test additionally runs `numeric_acceptance.h`:
  16 authored RGB32F bars, quality 95, a two-pixel boundary exclusion, and all six
  sRGB/P3 × ISO-only/XMP-only/dual-metadata paths. It enforces A08 HDR luminance EV
  P95 and target-primary SDR RGB8 MAE/P99 limits with an actual output ICC profile.
  Product and probe disable libultrahdr intrinsics because the pinned arm64 P3 path
  fails this vector; scalar execution preserves the same acceptance thresholds.
- Optional authentic phone fixtures are sampled at at most 1024 pixels on the long edge
  for codec inspection. This is not full-size processing or visual HDR acceptance.

Tests require macOS15/iOS18 APIs and return CTest skip code 77 on older runtimes.
Skipped cases do not satisfy the HDR plan. Real iPhone/iPad/Intel HDR, minimum OS,
unknown protocol admission, allocation failures and complete client editing/export
remain separate acceptance gates. Synthetic files are generated from project-authored
float pixels; they do not replace authentic phone protocol coverage.
