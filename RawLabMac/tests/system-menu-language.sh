#!/bin/bash
# ============================================================================
#  系统菜单跟随界面语言：选了德文/日文后，"编辑""窗口"等系统菜单也要换语言
#  用法：system-menu-language.sh <RawLab Mac.app>
#  需要桌面会话和辅助功能权限；副本换包标识、用临时主目录，不碰日常 RawLab 的设置
# ============================================================================
set -euo pipefail
SOURCE_APP="${1:?Pass the built RawLab Mac.app}"
OUT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rawlab-menu-language.XXXXXX")" && pwd -P)"
ID="dev.rawlab.agent.menu-language.$$"
APP="$OUT/MenuLanguage.app"
PROCESS="MenuLanguage.app/Contents/MacOS/RawLabMac"
cleanup() {
    pkill -f "$PROCESS" 2>/dev/null || true
    defaults delete "$ID" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$ID.plist"
    rm -rf "$OUT"
}
trap cleanup EXIT
ditto "$SOURCE_APP" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP" >/dev/null 2>&1
mkdir -p "$OUT/home"
cat > "$OUT/menus.swift" <<'SWIFT'
import ApplicationServices
let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
var bar: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar)
var items: CFTypeRef?
if let bar { AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &items) }
for item in (items as? [AXUIElement] ?? []).dropFirst() {
    var title: CFTypeRef?
    AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
    print(title as? String ?? "")
}
SWIFT
swiftc -O "$OUT/menus.swift" -o "$OUT/menus" 2>/dev/null

check() {
    local language=$1 edit=$2 window=$3 pid titles
    defaults write "$ID" RawLab.language -string "$language"
    defaults write "$ID" updates.automatic -bool false
    open -n -a "$APP" --env CFFIXED_USER_HOME="$OUT/home" --args -ApplePersistenceIgnoreState YES
    for _ in $(seq 40); do
        pid=$(pgrep -f "$PROCESS" || true)
        [ -n "$pid" ] && break
        sleep 0.25
    done
    [ -n "$pid" ] || { echo "FAIL: app did not start"; exit 1; }
    sleep 3
    titles="$("$OUT/menus" "$pid" | tr '\n' ' ')"
    kill "$pid"; sleep 1
    if [[ " $titles " == *" $edit "* && " $titles " == *" $window "* ]]; then
        echo "PASS: $language menu bar: $titles"
    else
        echo "FAIL: $language menu bar should use $edit / $window: $titles"; exit 1
    fi
}
check de Bearbeiten Fenster
check ja 編集 ウインドウ
