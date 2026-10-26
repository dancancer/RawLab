# Desktop release packaging

This procedure prepares macOS and Windows packages and update metadata. Running
these scripts does not authorize a release, an upload, a tag, or replacement of
a user's installed app. Use the version and build number approved for the
release branch. Ordinary development builds keep their existing defaults.

## Shared model input

Apple Silicon macOS and Windows release packages contain DualDn and Restormer,
with GPU neural inference only. Intel macOS packages contain no AI component.
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
`RAWLAB_DUALDN_MODEL_DIR`. Within the macOS matrix, only the Apple Silicon full job provisions AI inputs; its default cache
root is `~/.cache/rawlab-ci`. Intel full shards still build and run their native
suites without AI models or CPU neural inference. Windows uses its runner's shared cache root. Provisioning is an administrator action, not an unverified public download.
A missing model fails AI-enabled Apple Silicon macOS and Windows full checks.
Intel full checks do not require these models. CI never reads signing private keys.

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
- For `arm64` only: `RAWLAB_DUALDN_MODEL_DIR`, `RAWLAB_DUALDN_MANIFEST_SHA256`,
  `RAWLAB_ONNXRUNTIME_ROOT`.
- `RAWLAB_ARCH=arm64` or `x86_64`, as appropriate for the requested package.

Apple Silicon release mode requires the complete model package and enables AI
compilation; the runtime exposes AI when a Core ML GPU is available. Intel has no
supported GPU backend, so an `x86_64` release build disables AI compilation and
omits the models, ONNX Runtime and AI controls; it rejects `RAWLAB_DUALDN=1`.
Intel application and updater acceptance remains separate from Apple Silicon GPU
validation.

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
current-user Setup, full nupkg and manual-install ZIP
(`RawLab-Windows-<version>-x64.zip`). ZIP is not eligible for automatic
installation. `-NoRumSdk` explicitly selects an offline validation build and
must be recorded when used.

Velopack also writes `RawLab.Desktop-stable-Portable.zip`, `RELEASES-stable`,
`releases.stable.json` and `assets.stable.json`. Do not upload them: the
updater trusts only the signed `windows-stable.json`, and the portable package
duplicates the manual-install ZIP.

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

### Windows descriptor lifetime and renewal

Use a **365-day UTC validity period** for a stable descriptor and renew it at
least **30 days before `ExpiresAt`**, even when no new desktop binary is planned.
These are release maintenance rules, not limits imposed by the wire format.
Record the expiry and the responsible release owner in the release checklist.
The app rejects expired descriptors; a successful download does not override
expiry. Keep the signing key available for maintenance throughout the supported
lifetime of the trusted seed.

For a renewal, retain the same P-256 public key, desktop version/build, minimum
version, nupkg bytes, filename and versioned package URL. Generate a new envelope
with a new `IssuedAt` and `ExpiresAt`; do not edit signed JSON fields by hand:

```powershell
$ExpirationUtc = [DateTimeOffset]::UtcNow.AddDays(365).ToString("o")
dotnet run --project scripts/release/update-manifest -c Release -- sign `
  $PublicTrustJson $PrivatePem $FullNupkg $Version $Build $MinimumVersion `
  $ExpirationUtc $ReleaseNotes windows-stable.json.new

dotnet run --project scripts/release/update-manifest -c Release -- verify `
  $PublicTrustJson windows-stable.json.new $FullNupkg $MinimumVersion
```

After the public-key verification succeeds and replacement is authorized, keep
both the old and renewed envelopes locally, rename the renewed file to
`windows-stable.json`, and replace that asset in the Release currently serving
`latest`. The descriptor continues to point to the original desktop version's
nupkg. For a mutable Release, the command is:

```bash
gh release upload "$LATEST_RELEASE_TAG" windows-stable.json \
  --repo dancancer/RawLab --clobber
```

[`--clobber`](https://cli.github.com/manual/gh_release_upload) deletes the old
asset before uploading. Perform the operation before the expiry window, then
immediately fetch the latest URL and verify the downloaded envelope and package
with the production public key. If upload fails, restore the still-valid old
asset or retry the verified renewed asset immediately; do not leave the latest
URL missing. Retain the resulting asset hashes in the release record. If Release
immutability is enabled, replacement is unavailable: publish a new authorized
maintenance Release containing the renewed metadata before the old one expires.

## Acceptance and publication

The updater publishes backups only after their copy and manifest are complete.
On a healthy startup, unreferenced complete backups are removed; unpublished
`.staging-<UUID>` copies older than 24 hours are removed. Legacy incomplete
backups move to `IncompleteBackups/`, and unreferenced recovery directories move
to `RecoveryArchives/`. These archives retain all files because they can contain
the only copy of edits made before recovery. They are not caches and must not be
deleted automatically. The current recovery receipt and its data remain in
`Recoveries/` so the application's recovery link stays valid. An active recovery
journal or unresolved installation state still blocks settings repair and cleanup.

Before publishing, run the release plan's UI, hardware and actual update matrix.
A build or fake-adapter test is not a successful install/restart/recovery test.
No-hardware skips must remain visible; they do not establish GPU acceptance.
Use separate test keys and a prerelease source for seed-to-next-version testing.
The existing 0.8.2 release requires one manual installation of the trusted seed.

For a desktop Release, after explicit release authorization, create a draft GitHub Release and upload
all architecture packages, Setup, nupkg, signed appcasts, signed manifest, source
archive and checksums. Verify the complete asset set and all signatures with the
formal public keys before publishing the draft. Drafts are not `latest`, so
users cannot see an update whose assets are still being uploaded.

Every stable Release that can become GitHub `latest`, including a mobile-only
Release, must contain all three desktop update metadata assets:

- `appcast-arm64.xml`
- `appcast-x86_64.xml`
- `windows-stable.json`

For a mobile-only Release, carry forward the previous desktop's signed appcasts
without changing their bytes. Carry forward the Windows envelope only if it has
at least 30 days remaining; otherwise renew it with the same desktop package
using the procedure above. Copy the three metadata assets into the new draft
before publication. Keep the original versioned desktop archives/nupkg available:
the metadata refers to those URLs, so the old packages do not need to be copied
or renamed into the mobile Release. Do not regenerate desktop metadata using the
mobile version or silently remove a supported architecture.

GitHub resolves each [`latest/download/<asset>` URL](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
against the current latest Release; it does not fall back to an older Release
when an asset is absent. Immediately after every stable publication or metadata
replacement, fetch all three URLs into an isolated verification directory:

```bash
verification_dir=$(mktemp -d)
trap 'rm -rf "$verification_dir"' EXIT
for asset in appcast-arm64.xml appcast-x86_64.xml windows-stable.json; do
  curl --fail --location --silent --show-error \
    -o "$verification_dir/$asset" \
    "https://github.com/dancancer/RawLab/releases/latest/download/$asset"
done
```

Verify the downloaded files, using the established public keys and the exact
desktop nupkg referenced by the Windows descriptor:

```bash
for arch in arm64 x86_64; do
  swift scripts/release/verify-sparkle.swift "$RAWLAB_SPARKLE_PUBLIC_KEY" \
    "$verification_dir/appcast-$arch.xml" feed
done
dotnet run --project scripts/release/update-manifest -c Release -- verify \
  "$PublicTrustJson" "$verification_dir/windows-stable.json" "$FullNupkg" "$MinimumVersion"
```

Strict Authenticode verification must run on Windows. Also verify each referenced
versioned package remains downloadable and matches its signed size/hash. Record
the results; the shell exit trap removes the temporary verification directory.
A missing, expired or invalid feed blocks release acceptance even when that
Release only changes a mobile client.
