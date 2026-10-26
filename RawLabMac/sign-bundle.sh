#!/bin/bash
set -euo pipefail
APP="$1"
IDENTITY=-
if [ "${RAWLAB_RELEASE:-0}" = 1 ]; then IDENTITY="${RAWLAB_CODESIGN_IDENTITY:?Missing signing identity}"; fi
SIGN_FLAGS=(--force --sign "$IDENTITY" --timestamp=none)
if [ "${RAWLAB_RELEASE:-0}" = 1 ] && [ -n "${RAWLAB_UPDATE_TEAM_ID:-}" ]; then SIGN_FLAGS=(--force --sign "$IDENTITY" --options runtime --timestamp); fi
if [ -n "${RAWLAB_CODESIGN_KEYCHAIN:-}" ]; then SIGN_FLAGS+=(--keychain "$RAWLAB_CODESIGN_KEYCHAIN"); fi
# 先签实际 Mach-O 文件，再按目录深度签嵌套 bundle，最后签应用。不能用 --deep 代替逐层签名。
while IFS= read -r -d '' binary; do
    if file -b "$binary" | grep -q 'Mach-O'; then codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$binary"; fi
done < <(find "$APP/Contents/Frameworks" -type f -print0)
while IFS= read -r -d '' bundle; do
    codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$bundle"
done < <(python3 - "$APP/Contents/Frameworks" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in sorted((p for p in root.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ('.app', '.xpc', '.framework')),
                   key=lambda p: len(p.parts), reverse=True):
    sys.stdout.buffer.write(str(path).encode() + b'\0')
PY
)
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --deep --strict --all-architectures "$APP"
if [ "${RAWLAB_RELEASE:-0}" = 1 ]; then
    CERTIFICATE_DIR="$(mktemp -d)"
    trap 'rm -rf "$CERTIFICATE_DIR"' EXIT
    codesign --display --extract-certificates="$CERTIFICATE_DIR/cert" "$APP"
    if [ -n "${RAWLAB_UPDATE_CERTIFICATE_SHA256:-}" ]; then
        actual="$(shasum -a 256 "$CERTIFICATE_DIR/cert0" | awk '{print $1}')"
        test "$actual" = "$(printf '%s' "$RAWLAB_UPDATE_CERTIFICATE_SHA256" | tr 'A-F' 'a-f')" || { echo 'Signing certificate does not match update trust.' >&2; exit 2; }
        leaf="$(shasum -a 1 "$CERTIFICATE_DIR/cert0" | awk '{print $1}')"
        codesign --verify --deep --strict --all-architectures -R "=certificate leaf = H\"$leaf\"" "$APP"
    else
        codesign --verify --deep --strict --all-architectures -R "=anchor apple generic and certificate leaf[subject.OU] = \"$RAWLAB_UPDATE_TEAM_ID\"" "$APP"
    fi
fi
