#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/native-env.sh"
OUT="$(mktemp -d /tmp/rawlab-ai-live-bin.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -parse-as-library -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macosx26.0" \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$ROOT/RawLabMac/Sources/AIColorRecipe.swift" "$ROOT/RawLabMac/Sources/AIService.swift" \
    "$ROOT/RawLabMac/Sources/AISettings.swift" "$ROOT/RawLabMac/Sources/AIImage.swift" \
    "$ROOT/RawLabMac/Sources/AIColorLook.swift" "$ROOT/RawLabMac/Sources/AIFileExporter.swift" \
    "$ROOT/RawLabMac/tests/AILiveTests.swift" "$ROOT/lutools/build-macos/libsony2fuji_core.a" \
    $(pkg-config --libs libraw opencv4 wavelib) -lc++ -lz -framework AppKit -framework ImageIO -framework Metal -framework Security -o "$OUT/test"
# 仅此显式开发测试读取 .env；密钥通过子进程环境传入，不进入命令行或输出。
node --input-type=module -e '
import {readFileSync} from "node:fs";
import {parseEnv} from "node:util";
import {spawn} from "node:child_process";
const [root,binary,output] = process.argv.slice(1);
const values = parseEnv(readFileSync(root + "/.env", "utf8"));
const key = values.DEEPSEEK_API_KEY ?? values["DEEPSEEK-API-KEY"];
if (!key) { process.stderr.write("DeepSeek test key is missing.\n"); process.exit(2); }
const child = spawn(binary,[output],{env:{...process.env,DEEPSEEK_API_KEY:key},stdio:"inherit"});
child.on("error",()=>{process.stderr.write("Cannot launch live test.\n");process.exitCode=1;});
child.on("exit",code=>{process.exitCode=code ?? 1;});
' "$ROOT" "$OUT/test" "${1:-$ROOT/output/ai-color-match-live}"
