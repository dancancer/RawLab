#!/usr/bin/env bash
set -euo pipefail

download_verified() {
  local url="$1" checksum="$2" archive="$3" partial="${3}.part"
  if [[ -f "$archive" ]] && echo "$checksum  $archive" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$partial"
    return
  fi
  if ! curl -fL --retry 3 "$url" -o "$partial"; then
    rm -f "$partial"
    return 1
  fi
  if ! echo "$checksum  $partial" | sha256sum -c -; then
    rm -f "$partial"
    return 1
  fi
  mv -f "$partial" "$archive"
}

main() {
  if [[ "$(id -u)" != 0 || "$(uname -s)" != Linux ]]; then
    echo 'Run with sudo inside the dedicated Ubuntu 24.04 CI guest.' >&2
    exit 1
  fi
  . /etc/os-release
  if [[ "$ID" != ubuntu || "$VERSION_ID" != 24.04 ]]; then
    echo 'The Android runner requires Ubuntu 24.04.' >&2
    exit 1
  fi
  if [[ "$(systemd-detect-virt --vm)" != kvm ]]; then
    echo 'Install the Android toolchain in a KVM guest, never on the physical host.' >&2
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl git unzip zip build-essential cmake ninja-build \
    pkg-config autoconf automake libtool meson gettext openjdk-17-jdk-headless \
    python3.12 python3.12-venv python3-pip time jq

  if ! id runner >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash runner
  fi
  install -d -o runner -g runner /opt/android-sdk /opt/rawlab-ci /var/cache/rawlab-ci/lens-sources

  tools_version=15859902
  tools_sha256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
  archive="/var/cache/rawlab-ci/commandlinetools-linux-${tools_version}.zip"
  download_verified "https://dl.google.com/android/repository/commandlinetools-linux-${tools_version}_latest.zip" "$tools_sha256" "$archive"
  if [[ ! -f /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager ]]; then
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' EXIT
    unzip -q "$archive" -d "$staging"
    install -d /opt/android-sdk/cmdline-tools
    mv "$staging/cmdline-tools" /opt/android-sdk/cmdline-tools/latest
  fi
  chown -R runner:runner /opt/android-sdk

  export ANDROID_HOME=/opt/android-sdk
  export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
  export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
  cd /opt/rawlab-ci
  # sdkmanager closes stdin after the last license; ignore only yes's SIGPIPE.
  set +o pipefail
  yes | runuser -u runner -- env ANDROID_HOME="$ANDROID_HOME" JAVA_HOME="$JAVA_HOME" \
    "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses
  license_status="${PIPESTATUS[1]}"
  set -o pipefail
  if [[ "$license_status" != 0 ]]; then
    exit "$license_status"
  fi
  runuser -u runner -- env ANDROID_HOME="$ANDROID_HOME" JAVA_HOME="$JAVA_HOME" \
    "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
    'platforms;android-35' 'build-tools;35.0.0' 'ndk;27.2.12479018' 'cmake;3.22.1' 'platform-tools'

  printf 'ANDROID_HOME=%s\nJAVA_HOME=%s\n' "$ANDROID_HOME" "$JAVA_HOME" > /opt/rawlab-ci/android.env
  chown runner:runner /opt/rawlab-ci/android.env
  echo 'Android guest toolchain is ready. Register the Actions runner separately; never store a GitHub token here.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
