#!/bin/bash
set -euo pipefail
: "${GITHUB_ENV:?Run this helper from a GitHub Actions job}"

if ! command -v rustup >/dev/null 2>&1; then
    : "${RUNNER_TEMP:?Set the job temporary directory}"
    : "${GITHUB_PATH:?Set the job PATH export file}"
    tools="$RUNNER_TEMP/rawlab-x3f-tools"
    export CARGO_HOME="$tools/cargo" RUSTUP_HOME="$tools/rustup"
    export PATH="$CARGO_HOME/bin:$PATH"
    if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
        case "$(uname -s)-$(uname -m)" in
            Darwin-arm64) host=aarch64-apple-darwin ;;
            Darwin-x86_64) host=x86_64-apple-darwin ;;
            Linux-aarch64) host=aarch64-unknown-linux-gnu ;;
            Linux-x86_64) host=x86_64-unknown-linux-gnu ;;
            *) echo 'Unsupported Rust bootstrap host.' >&2; exit 2 ;;
        esac
        mkdir -p "$tools"
        url="https://static.rust-lang.org/rustup/dist/$host/rustup-init"
        curl --fail --location --silent --show-error --retry 2 "$url" --output "$tools/rustup-init"
        curl --fail --location --silent --show-error --retry 2 "$url.sha256" --output "$tools/rustup-init.sha256"
        expected="$(awk '{print $1}' "$tools/rustup-init.sha256")"
        printf '%s  %s\n' "$expected" "$tools/rustup-init" | shasum -a 256 -c -
        chmod +x "$tools/rustup-init"
        "$tools/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none
    fi
    printf '%s\n' "$CARGO_HOME/bin" >> "$GITHUB_PATH"
    printf 'CARGO_HOME=%s\nRUSTUP_HOME=%s\n' "$CARGO_HOME" "$RUSTUP_HOME" >> "$GITHUB_ENV"
fi

rustup toolchain install 1.99.1 --profile minimal --component rust-docs
rustup target add --toolchain 1.99.1 "$@"
printf 'RUSTUP_TOOLCHAIN=1.99.1\n' >> "$GITHUB_ENV"
