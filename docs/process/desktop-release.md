# Desktop release packaging

This procedure prepares macOS and Windows packages and update metadata. Running
these scripts does not authorize a release, an upload, a tag, or replacement of
a user's installed app. Use the version and build number approved for the
release branch. Ordinary development builds keep their existing defaults.

## Shared model input

Release packages contain DualDn and Restormer, with GPU neural inference only.
DualDn retains CC BY-NC 4.0; Restormer retains its Academic Public License for
noncommercial use. Keep their notices, model provenance and conversion records.
The deterministic ISP can use CPU; there is no CPU neural-inference fallback.

The complete production package includes `raw.onnx`, `isp.onnx`, `rgb.onnx`,
`blind_rgb.onnx`, the upstream notices, and the three native Core ML model
directories for macOS. `dualdn_probe --validate` checks every declared resource
before and after app packaging. No model weights or replay tensors enter Git.

The current complete model manifest SHA-256 is
`38cbd6884bb181db859ffc668cf754a55331be732592e0d4cdf9a2d41a19486a`.
The original DualDn checkpoint SHA-256 is
`9bd36c18afd6148d3b5d50c215d77cc17a745851ed2735f1b655013e71c38e1d`.
Runtime versions are ONNX Runtime 1.23.2 on macOS and ONNX Runtime DirectML
1.23.0 / DirectML 1.15.4 on Windows. Runtime archives and libraries have checksum
pins in `scripts/ci/ai-inputs.py` and `RawLabWindows/build.ps1`.

For CI, provision the licensed complete package once at
`$RAWLAB_AI_SHARED_CACHE/ai-models/<manifest-sha256>/complete`, or explicitly set
`RAWLAB_DUALDN_MODEL_DIR`. Both Mac runners use the same relative cache layout;
the default root is `~/.cache/rawlab-ci`. Windows uses its runner's shared cache
root. Provisioning is an administrator action, not an unverified public download.
A missing model makes full checks fail. CI never reads signing private keys.

## macOS

Store the fixed code-signing certificate and its private key on the release
machine, with an offline backup. The default mode is self-signed code plus a
persistent Sparkle EdDSA key. Keep EdDSA stable across future certificate changes.
Private-key paths below are local inputs, not repository or CI settings.

Set these inputs before invoking `RAWLAB_RELEASE=1 bash RawLabMac/build.sh`:

- `RAWLAB_RELEASE_VERSION` and `RAWLAB_RELEASE_BUILD`.
- `RAWLAB_CODESIGN_IDENTITY`; optionally `RAWLAB_CODESIGN_KEYCHAIN` for an isolated keychain.
- `RAWLAB_UPDATE_CERTIFICATE_SHA256` for the fixed self-signed leaf certificate.
- `RAWLAB_SPARKLE_PUBLIC_KEY`, the base64 EdDSA public key.
- `RAWLAB_DUALDN_MODEL_DIR`, `RAWLAB_DUALDN_MANIFEST_SHA256`, `RAWLAB_ONNXRUNTIME_ROOT`.
- `RAWLAB_ARCH=arm64` or `x86_64`, as appropriate for the requested package.

Release mode requires the complete model package and enables AI compilation.
The current runtime exposes AI on Apple Silicon with an available Core ML GPU;
Intel packages do not fall back to CPU AI. Intel application and updater
acceptance remains separate from Apple Silicon GPU validation.

The script builds into a fresh version/build directory, sets the public update
configuration, signs Mach-O files and nested bundles from inside out, verifies
the certificate identity and strict code signatures, and uses `ditto` to preserve
bundle symlinks in the ZIP. Self-signed mode does not enable hardened runtime or
run `spctl`. Existing release outputs are rejected rather than overwritten.

Create the architecture-specific appcast after packaging:

```bash
python3 scripts/release/macos_appcast.py \
  --app "$SIGNED_APP" --archive "$RELEASE_ZIP" --arch "$RAWLAB_ARCH" \
  --private-key "$SPARKLE_PRIVATE_KEY_FILE" --sparkle-bin "$SPARKLE_BIN" \
  --notes "$RELEASE_NOTES" --output "appcast-$RAWLAB_ARCH.xml"
```

The script signs both archive and feed with Sparkle's `sign_update`, adds the
architecture and SHA-256 fields consumed by RawLab, then independently verifies
both with the app's public key. Final feed URLs are GitHub Release
`latest/download/appcast-arm64.xml` and `appcast-x86_64.xml`; enclosure URLs bind
the version-specific Release asset.

To adopt Developer ID later, keep EdDSA unchanged, replace the signing identity,
remove `RAWLAB_UPDATE_CERTIFICATE_SHA256`, and set `RAWLAB_UPDATE_TEAM_ID`. The
existing strict runtime mode requires Developer ID trust and notarization;
notarization remains a separately authorized release operation.

## Windows

Prepare a public trust JSON with `FeedUrl` set to
`https://github.com/dancancer/RawLab/releases/latest/download/windows-stable.json`,
`PublicKey` set to the base64 P-256 SubjectPublicKeyInfo, and
`PublisherKeySha256` empty for the default signed-manifest mode. The private key
stays on the release machine. A nonempty publisher fingerprint explicitly
selects the optional Authenticode strict mode; its signed executables must be
prepared before packaging.

```powershell
./RawLabWindows/build.ps1 -ReleasePackage -ReleaseVersion $Version -ReleaseBuild $Build `
  -UpdateTrustFile $PublicTrustJson -DualDnModel $CompleteModel `
  -DualDnManifestSha256 $ManifestSha256 -ReleaseOutput $NewOutputDirectory
```

The script requires all inputs, publishes a fresh self-contained x64 app,
copies models/runtimes/licenses, validates the packaged model, and only then
runs pinned vpk 1.2.161 for `RawLab.Desktop` / `stable`. Keep the generated
current-user Setup, full nupkg and manual-install ZIP. ZIP is not eligible for
automatic installation. `-NoRumSdk` explicitly selects an offline validation
build and must be recorded when used.

Sign and verify the release description using the same verifier as the app:

```powershell
dotnet run --project scripts/release/update-manifest -c Release -- sign `
  $PublicTrustJson $PrivatePem $FullNupkg $Version $Build $MinimumVersion `
  $ExpirationUtc $ReleaseNotes windows-stable.json

dotnet run --project scripts/release/update-manifest -c Release -- verify `
  $PublicTrustJson windows-stable.json $FullNupkg $MinimumVersion
```

The tool checks private/public key agreement, P-256 signature, expiry, minimum
version, package hashes and size, embedded executable versions and architecture.
Strict mode additionally checks Authenticode. It never installs a package.

## Acceptance and publication

Before publishing, run the release plan's UI, hardware and actual update matrix.
A build or fake-adapter test is not a successful install/restart/recovery test.
No-hardware skips must remain visible; they do not establish GPU acceptance.
Use separate test keys and a prerelease source for seed-to-next-version testing.
The existing 0.8.2 release requires one manual installation of the trusted seed.

After explicit release authorization, create a draft GitHub Release and upload
all architecture packages, Setup, nupkg, signed appcasts, signed manifest, source
archive and checksums. Verify the complete asset set and all signatures with the
formal public keys before publishing the draft. Drafts are not `latest`, so
users cannot see an update whose assets are still being uploaded.
