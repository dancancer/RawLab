# Install RawLab on Your Own iPhone

[English](ios-installation.md) | [Simplified Chinese](ios-installation.zh-CN.md)

You need a computer, a USB cable that supports data transfer, and your own Apple
Account (formerly Apple ID). **No jailbreak or paid developer membership is
required.** RawLab requires iOS 18 or later and currently supports iPhone.

RawLab is released as an **unsigned IPA**, an app package that is not yet signed
for installation. You cannot install it by tapping the file on your phone. A
tool on your computer must sign it using your account before installing it on
your iPhone. The current package is not an App Store or TestFlight release. See
the [project installation notes](installation.md).

## Choose an Installation Method

| Your situation | Method |
| --- | --- |
| You have Windows or a Mac and want the released version | Follow the Sideloadly steps below; no source build is needed |
| You have a Mac and Xcode and prefer not to use a third-party signing tool, or want to install the current source | Follow the Xcode workflow below |
| You only have an iPhone, with no computer | This guide does not provide a phone-only installation method for the current package; you will need access to a computer |

Apps signed with a free account **need to be re-signed after 7 days**. Each
device can have up to 3 such apps installed. To renew the signature, use the
same account to re-sign and install over the existing app; you do not need to
delete it first. Avoid repeatedly changing the app's bundle identifier, which
can use up your free account's App ID allowance. See
[Apple's free account limits](https://developer.apple.com/help/account/basics/about-your-developer-account).

## Method 1 Install the Release With Sideloadly

Sideloadly is a third-party tool, not an Apple tool. It requires you to sign in
to your Apple Account inside the tool on your computer. If you prefer not to do
this, use Method 2. Enter passwords, verification codes, and your phone's
passcode yourself; do not send them to an AI agent.

### 1 Download the App and Installer

1. Open the [latest RawLab release](https://github.com/dancancer/RawLab/releases/latest). Under `Assets`, download the file whose name includes `iOS` and `unsigned.ipa`. Do not download the Android APK, Mac ZIP, or source archive.
2. Download and install the version for your computer from the [Sideloadly website](https://sideloadly.io/). Do not use unknown mirrors or online signing services.

On Windows, also follow Sideloadly's setup instructions for the **web-download
versions of iTunes and iCloud**. Its website states that the Microsoft Store
versions are not suitable for this workflow. If you already have these apps,
check their versions and any backup requirements before replacing them. Do not
let an agent uninstall them without your approval. Do not apply the Windows
requirements to a Mac. See
[Sideloadly's installation requirements](https://sideloadly.io/).

### 2 Connect Your iPhone

Connect your iPhone to the computer with the USB cable and unlock it. If the
phone asks **Trust This Computer?**, tap **Trust** and enter your passcode. Keep
it connected and select **your iPhone** in Sideloadly's device list, not the
Apple Silicon Mac itself.

If the computer cannot see your phone, check the cable first and confirm that
Finder on Mac or iTunes on Windows can detect it.

### 3 Sign and Install

1. Open Sideloadly and drag the downloaded `.ipa` file into it.
2. Confirm that your iPhone is selected, then enter your Apple Account in the `Apple ID` field.
3. Keep the normal Apple ID installation mode and default settings. Click `Start` and enter your password and any two-factor authentication code yourself. Do not select a mode that only exports an IPA.
4. Wait for the tool to report a successful installation. If it fails, keep the error message instead of repeatedly retrying or switching accounts.

There is no need to change the minimum iOS version, inject plugins, remove
embedded frameworks, or disable system security protections. See
[Sideloadly's basic workflow](https://sideloadly.io/).

### 4 Enable Developer Mode

On your iPhone, open **Settings > Privacy & Security > Developer Mode**. Turn it
on and restart when prompted. After restarting, tap **Enable** and enter your
passcode to finish. If the installation tool asks for Developer Mode earlier,
complete this step before continuing the installation.

If the switch is missing, follow the installation tool's prompts to install a
development-signed app, then check Settings again. On a Mac, you can also start
device pairing in Xcode. Apple explains that connecting to Xcode or installing
a development-signed app can make the setting appear. If the tool cannot
continue and the switch is still missing, stop and troubleshoot instead of
downloading an unknown unlocking tool. See
[Apple's Developer Mode introduction](https://developer.apple.com/videos/play/wwdc2022/110344/).
Developer Mode reduces some security protections; enable it only to run apps
you trust. See
[Apple's instructions for enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

### 5 Open RawLab

Open RawLab from the Home Screen or App Library. **Only if you see an
Untrusted Developer message**, open **Settings > General > VPN & Device
Management**, select the account you just used for signing, and follow the
prompts to trust it. This is not a required step for every installation. See
[Sideloadly's trust and troubleshooting instructions](https://sideloadly.io/faq).

If RawLab opens and stays on its main screen without immediately closing,
installation and first launch have succeeded. To check photo processing,
import a RAW photo you are willing to use for testing, preview it, and export
a JPEG. Successful installation does not establish support for every camera,
large-image processing, or physical-device performance.

### 6 Renew the Signature After Seven Days

Reconnect your phone to the computer and install again using **the same Apple
Account and the same bundle identifier (Bundle ID)**. Export important finished
photos first. Do not uninstall RawLab before renewing; uninstalling may delete
data stored inside the app.

You can also configure automatic refreshing by following
[Sideloadly's auto-refresh instructions](https://sideloadly.io/faq). The computer
must run the required background program and be able to reach the phone over
USB or a configured Wi-Fi connection. This is not a permanent signature that
keeps working independently of the computer.

## Method 2 Build and Install With Xcode

This method is for Mac only and uses Apple's tools to build and install the
app. **It does not mean dragging the unsigned IPA into Xcode.** You will install
the current source. To match a particular release, obtain that version's source
separately; do not reset an existing working directory.

1. Install full Xcode from the Mac App Store or [Apple's developer website](https://developer.apple.com/xcode/). On first launch, install iOS support components when prompted. Xcode must support your phone's current iOS version; Command Line Tools alone are not enough.
2. Prepare the [repository source](https://github.com/dancancer/RawLab) and CMake. If you already have the source, open a terminal at its repository root. Otherwise, run the following commands in a suitable directory to create a separate checkout:

```bash
git clone https://github.com/dancancer/RawLab.git RawLab-source
cd RawLab-source
```

From the repository root, run these two commands to build and verify the image
processing framework. If CMake is missing and Homebrew is already installed on
your Mac, you can run `brew install cmake`.

```bash
bash lutools/build.sh ios
bash lutools/platform/ios/verify-framework.sh
```

3. Run `open RawLab/RawLab.xcodeproj`. Sign in to your own account under **Xcode > Settings > Apple Accounts** (called `Accounts` in some older versions).
4. Select **RawLab target > Signing & Capabilities**, enable `Automatically manage signing`, and choose your own `Team`. A free account appears as `Personal Team`. Set a unique bundle identifier, such as `com.yourname.rawlab`, replacing `yourname` with your own identifier. **Do not keep someone else's Team from the project or use the example identifier unchanged.** These are local signing settings and should not be committed to the repository.
5. Connect your iPhone over USB and trust the computer. At the top of Xcode, select **the RawLab scheme and your physical iPhone**, not a simulator or `Any iOS Device`. Wait for pairing and debugging support to finish. On the phone, enable **Settings > Privacy & Security > Developer Mode**, restart, and confirm again. Then click Xcode's Run button.
6. Once RawLab opens on your phone, installation is complete. When a free account's signature expires, run and install again using the same account and bundle identifier.

Xcode handles signing the app and its embedded framework; you do not need to
add the framework again manually. See the
[repository's iOS build guide](../../lutools/platform/ios/README.md) for build
requirements and
[Apple's physical-device workflow](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
for running the app.

## Instructions for AI Agents

This section is for agents authorized to operate on the user's computer. If the
user only asks you to write documentation, do not install anything. Once the
user explicitly requests installation, follow these steps in order and wait
whenever the user needs to enter information or confirm a device prompt.

### Confirm the Setup and Boundaries

- Confirm whether the computer runs Windows or macOS, which iPhone is the target, whether it runs iOS 18 or later, and whether the user wants the release or the current source. Do not ask again when these answers are already clear.
- Use Method 1 for a release installation. Use Method 2 when the user wants the source version or prefers not to use a third-party signing tool and has a Mac, the repository, and full Xcode.
- The user must enter passwords, verification codes, and the phone passcode, and complete Trust This Computer and Developer Mode restart confirmations. Do not read, record, or request these secrets.
- Do not buy a developer membership, upload to TestFlight, jailbreak, install enterprise profiles, or disable SIP or Gatekeeper. Do not uninstall existing apps, drivers, or account certificates without authorization.
- Preserve existing code changes. Do not switch or reset branches, and do not commit personal signing settings, certificates, provisioning profiles, device information, or generated artifacts.

### Release Installation Workflow

1. Find the actual unsigned IPA and `SHA256SUMS.txt` for the same version on the latest release page. Download them and verify the SHA-256 of **that IPA**; stop if it does not match. On Mac, use `shasum -a 256 "/path/to/RawLab-iOS-version-unsigned.ipa"`. In Windows PowerShell, use `Get-FileHash -Algorithm SHA256 "C:\path\RawLab-iOS-version-unsigned.ipa"`. Replace example paths with the actual downloaded file. Do not compare checksums for another platform's package.
2. Check and open Sideloadly, then follow Method 1. This is a desktop UI workflow: do not invent commands such as `sideloadly install`. Use desktop automation tools, if available, to operate the visible interface.
3. Hand control to the user before authentication. When resuming, verify the selected phone, IPA, and installation mode. If Developer Mode is already visible, ask the user to enable it first. Otherwise, follow the installation tool's prompts, pausing if it requires Developer Mode. Do not treat an interrupted installation as successful.
4. After the tool reports success, ask the user to finish Developer Mode and any necessary trust confirmation, then verify that RawLab opens on the phone. Record the actual Bundle ID used by the tool and keep it for renewals. Do not publish account details or full device identifiers in chat.
5. Without desktop automation access, finish the download and checksum verification, then give the user the exact file location and next UI steps. Do not report that the app is installed when only the files are ready.

### Source Installation From the Command Line

Run all commands from the repository root. First complete Xcode initialization,
account sign-in, and phone pairing from Method 2. The user can select their own
Team in Xcode. If you cannot confirm the Team ID, use Xcode's UI to run the app;
do not guess or copy the project's default value.

Check the environment and available devices first. If any check fails, resolve
it before continuing:

```bash
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
cmake --version
xcodebuild -list -project RawLab/RawLab.xcodeproj
xcodebuild -showdestinations -project RawLab/RawLab.xcodeproj -scheme RawLab
xcrun devicectl list devices
```

If `xcodebuild` points to Command Line Tools, set `DEVELOPER_DIR` in the current
terminal to the actual Xcode `Contents/Developer` directory, for example
`export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"`. There is no
need to change the global toolchain selection.

Set the following variables to real values in the current terminal before
building. Do not pass placeholders to the commands:

| Variable | Where to get it |
| --- | --- |
| `TEAM_ID` | The developer Team ID confirmed by the user, or the `DEVELOPMENT_TEAM` setting after the user selects their own Team in Xcode; the repository's existing value does not prove it belongs to the user |
| `BUNDLE_ID` | The unique bundle identifier chosen for the first installation; keep the same value for updates and renewals |
| `DEVICE_UDID` | The `id` of the target physical iPhone in `xcodebuild -showdestinations`; do not select a simulator |
| `DEVICE_ID` | The Identifier for the same phone in `devicectl list devices`; do not assume it is the same as the UDID above |

Run the following blocks in order in the same terminal. **Continue only after
each block exits with code 0.** Command-line overrides supply signing settings
without editing the project file:

```bash
: "${TEAM_ID:?Set the confirmed signing team ID}"
: "${BUNDLE_ID:?Set the app bundle ID}"
: "${DEVICE_UDID:?Set the physical iPhone destination ID}"
: "${DEVICE_ID:?Set the same iPhone devicectl identifier}"

bash lutools/build.sh ios
```

```bash
bash lutools/platform/ios/verify-framework.sh
```

The framework must pass verification. Do not reuse a cache of unknown origin or
version just because the directory exists.

```bash
xcodebuild \
  -project RawLab/RawLab.xcodeproj \
  -scheme RawLab \
  -configuration Release \
  -destination "platform=iOS,id=${DEVICE_UDID}" \
  -derivedDataPath build/ios-personal-install \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  build
```

This uses the account already signed in to Xcode to create or update signing
assets and register the selected device as needed. Do not use
`CODE_SIGNING_ALLOWED=NO`; that produces a build without the signature needed
for installation.

```bash
APP_PATH="$PWD/build/ios-personal-install/Build/Products/Release-iphoneos/RawLab.app"
test -d "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
```

Once signature verification passes, install the `.app` bundle, not the unsigned
IPA:

```bash
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
```

If the phone still shows Developer Mode or trust prompts, wait for the user to
complete them before continuing:

```bash
xcrun devicectl device info apps --device "$DEVICE_ID"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
```

Check the actual Bundle ID in the installed-app list. A successful launch
command does not prove that the app will not immediately crash. Ask the user to
confirm that RawLab is visible and stays on its main screen, or verify this
using an authorized device UI tool.

### Report the Result

Report **build or signing, installation, and first launch** separately. Only
say that the app is installed and opens successfully when the installation tool
succeeds and the main screen is confirmed on the physical device. Otherwise,
state the blocked step, the original error, and what the user needs to do next.

Remind the user about the free signature's 7-day lifetime and how to renew it.
Simulator runs and unsigned device builds do not establish successful
physical-device installation.

## Troubleshooting

| Problem | What to do |
| --- | --- |
| Tapping the downloaded IPA on the phone does nothing | An unsigned IPA cannot be installed directly; use a computer and Method 1 or Method 2 |
| The phone is not detected | Unlock it, trust the computer, and try a USB data cable; on Windows, check the required iTunes and iCloud versions |
| Developer Mode is missing | Try installing a development-signed app, or start pairing in Xcode on a Mac, then check Settings again |
| The app stops opening after seven days | Re-sign and install over it using the original account and Bundle ID; do not delete it first |
| A free account's app or App ID limit has been reached | Free accounts can register up to 10 App IDs and 3 devices, with registrations expiring after 7 days; each device can have up to 3 apps installed. Check the limits instead of repeatedly changing IDs. The user must decide whether to uninstall other apps |
| Xcode reports a signing Team or Bundle ID error | Confirm your own Team, a unique Bundle ID, automatic signing, and a signed-in account |
| Xcode cannot find `sony2fuji.xcframework` | Run the iOS framework build and verification commands from the repository root; do not remove the embedded framework to bypass the error |
| Xcode does not support the phone's current iOS version | Install a compatible Xcode version and device support components; do not lower RawLab's minimum iOS version |
| You want to install through TestFlight | The current package is not a TestFlight build and cannot be imported into TestFlight; the maintainer would need to publish a separate build and provide an invitation link |

The steps and external tool instructions were checked on 2026-10-13.
Physical-device installation, peak memory, and thermal validation of the
released RawLab package remain outstanding. This guide provides installation
steps; build and simulator checks are not physical-device validation. See the
[release limitations](../releases/v0.5/v0.5.0.md).
