# RawLab iOS local RUM validation

This directory is only for the explicit `RAWLAB_RUM_LOCAL` simulator build. The normal `RawLab` Debug and Release builds do not link AlibabaCloudRUM. The local app uses bundle ID `com.example.RawLab.rumlocal` and a separate `usage-consent-local.json` store.

Run the configuration and default-transport checks without a vendor framework:

```bash
bash RawLab/tests/rum-local-configuration.sh
bash RawLab/tests/rum-local-transport.sh
```

Prepare the cached official tag `2.4.2`, compile the Objective-C wrapper and build the local simulator app:

```bash
bash experiments/rum-local/ios/run.sh --build
```

Check the project license texts in a built app and in both XCFramework slices
without installing the app or starting the SDK:

```bash
bash experiments/rum-local/ios/verify-licenses.sh /path/to/RawLab.app
bash experiments/rum-local/ios/verify-licenses.sh lutools/build-ios/sony2fuji.xcframework
bash experiments/rum-local/ios/verify-licenses-test.sh
```

These checks compare the packaged GPL, linking exception and licensing notice
byte-for-byte with the current source. They do not establish third-party SDK
redistribution permission or physical-device runtime coverage.

The wrapper and copied core XCFramework are reused from `.cache/shared/aliyun-rum/ios/2.4.2/build/local`; the app DerivedData remains temporary. Probe stdout/stderr are captured at `.cache/tmp/rum-local/ios-probe-stdout.log` and `.cache/tmp/rum-local/ios-probe-stderr.log` (override with `RAWLAB_RUM_PROBE_LOG_DIR`).

The synthetic probe is intentionally opt-in. It requires a fresh UUID and sends only five fixed `UsageEvent` values; the adapter adds `validation_run` to each custom event. It does not enable daily consent or read photos:

```bash
export RAWLAB_RUM_VALIDATE=1
export RAWLAB_RUM_VALIDATION_RUN="$(uuidgen)"
export RAWLAB_RUM_LIMIT_VERIFIED=1
export RAWLAB_RUM_NETWORK=china-telecom
export RAWLAB_RUM_CONFIG_VERIFIED=1
bash experiments/rum-local/ios/run.sh --probe
```

The script refuses to run with host proxy settings or proxy environment variables. It passes runtime configuration with `SIMCTL_CHILD_*` only for the dedicated launch, leaves an already-booted simulator booted, restores a simulator that it booted itself, and terminates/uninstalls only `com.example.RawLab.rumlocal` after a bounded 35-second window. It fails if the app has not reported successful submission and SDK stop. Private diagnostic output stays under `.cache/tmp/rum-local`; remove it after diagnosis and API readback.

Startup checks the public core `isStarted` and non-empty session state after the five-second handoff delay. A fixed `RawLab Usage` logical view is opened/closed through public core `reportView`, with a random ID and empty map. SDK 2.4.2 otherwise drops custom events with `view.id is nil`; the local mask remains `512` (customEvent only), with automatic View, network, interaction and replay still disabled. Debug logging is enabled only for a synthetic validation marker. Only matching SLS readback establishes ingestion, not these readiness checks.

The pinned source archive SHA-256 is checked before preparation. iOS 2.4.2 exposes no public cache-clear API; this local validation does not claim complete withdrawal cleanup. The script removes the dedicated app sandbox by uninstalling it. The adapter does not restart the SDK after stop; re-enable requires a new process. A physical iPhone was not exercised in this validation.
