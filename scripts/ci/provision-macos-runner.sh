#!/bin/bash
set -euo pipefail
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 || $(id -u) == 0 ]]; then
    echo 'Use the non-administrator rawlab-ci account on an Apple Silicon Mac.' >&2
    exit 1
fi
if [[ $(id -un) != rawlab-ci || " $(id -Gn) " == *' admin '* ]]; then
    if [[ ${4:-} != --allow-current-user ]]; then
        echo 'Use the non-administrator rawlab-ci account on an Apple Silicon Mac.' >&2
        exit 1
    fi
    echo 'Personal-account runner explicitly enabled; trusted CI inherits the current user file access.' >&2
fi
root=${1:?Pass the dedicated CI root}
xcode=${2:?Pass the full Xcode.app path}
archive=${3:?Pass the verified runner archive}
[[ "$root" == /* && -d "$root" && ! -L "$root" && -O "$root" && -w "$root" ]]
root="$(cd "$root" && pwd -P)"
home="$(cd "$HOME" && pwd -P)"
if [[ "$root" != "$home/"* ]]; then
    echo 'Keep runner startup files and Python inside the CI user home. Use --work for an external build volume.' >&2
    exit 1
fi
[[ -d "$xcode/Contents/Developer" && -r "$xcode/Contents/Info.plist" ]]
export DEVELOPER_DIR="$xcode/Contents/Developer"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
python=/opt/homebrew/bin/python3.12
"$python" -c 'import sys; assert sys.version_info[:2] == (3, 12)'
xcodebuild -version
xcodebuild -checkFirstLaunchStatus
xcrun --sdk macosx --show-sdk-path
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphonesimulator --show-sdk-path
xcrun simctl list runtimes available -j | "$python" -c '
import json, sys
runtimes = json.load(sys.stdin).get("runtimes", [])
if not any(runtime.get("platform") == "iOS" and runtime.get("isAvailable") and runtime.get("identifier")
           for runtime in runtimes):
    sys.exit("Install an available iOS simulator runtime before registering this Apple runner.")
'
for tool in brew cmake pkg-config autoconf automake glibtoolize; do command -v "$tool"; done
brew list --versions autoconf automake libtool m4 pkgconf
printf '%s  %s\n' df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2 "$archive" | shasum -a 256 -c -
mkdir -p "$root/runner" "$root/_work" "$root/tmp" "$root/cache/pip" "$root/cache/lens-sources" "$root/cache/macos-sources"
chmod 700 "$root"
if [[ ! -x "$root/runner/bin/Runner.Listener" ]]; then
    tar -xzf "$archive" -C "$root/runner"
fi
if [[ ! -x "$root/venv/bin/python" ]]; then "$python" -m venv "$root/venv"; fi
# setup-python's macOS distribution requires a privileged, fixed framework install.
# Use a prepared Python 3.12 venv instead; jobs never need sudo or global pip writes.
printf '%s\n' "$root/venv/bin:$PATH" > "$root/runner/.path"
printf '%s\n' \
    "PATH=$root/venv/bin:$PATH" \
    "DEVELOPER_DIR=$DEVELOPER_DIR" "TMPDIR=$root/tmp/" \
    "PIP_CACHE_DIR=$root/cache/pip" "RAWLAB_LENS_SOURCE_CACHE=$root/cache/lens-sources" \
    "RAWLAB_SOURCE_CACHE=$root/cache/macos-sources" \
    'LANG=en_US.UTF-8' 'LC_ALL=en_US.UTF-8' \
    'HOMEBREW_NO_AUTO_UPDATE=1' 'HOMEBREW_NO_INSTALL_CLEANUP=1' > "$root/runner/.env"
echo 'Tools are ready. Register the runner separately and install its user LaunchAgent from the selected user login session.'
