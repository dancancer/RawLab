#!/bin/bash
# ============================================================================
#  发版前本机快检：在切 release/* 或开始四端打包前，先把最常见的“打包到一半才炸”的问题拦下来。
#  用法：bash scripts/release/preflight.sh [--models macos,ios|macos|ios|none] [--skip-mac-compile]
#  步骤（任一步失败立即停止，并在 stderr 打印失败步骤名与退出码）：
#    1. version   ：四端版本号与 Shared/version.json 一致（generate.py --check），并跑构建号单调/血统门禁
#    2. docs      ：入库 Markdown 相对链接可解析（test_doc_links）
#    3. mac-compile：RawLabMac 主工程全量 Swift 类型检查。模型测试只编译部分源文件，SwiftUI 视图里的
#                   编译错误只有完整应用编译才会暴露；这里用持久 SwiftPM 缓存增量构建依赖模块，再对
#                   与 RawLabMac/build.sh 相同的源文件集合做 swiftc -typecheck，不编译原生核心、不链接。
#    4. models    ：scripts/ci/apple-models.sh（默认 macos 与 ios）
#  缓存：SwiftPM 产物放在 RAWLAB_PREFLIGHT_CACHE（默认 <worktree>/.cache/tmp/release-preflight），
#        与本工作区源码绑定，不跨 worktree 共享；不再需要时可整目录删除。
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

models="macos,ios"
mac_compile=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --models) models="${2:?--models needs macos,ios|macos|ios|none}"; shift 2 ;;
        --models=*) models="${1#--models=}"; shift ;;
        --skip-mac-compile) mac_compile=0; shift ;;
        -h|--help) sed -n 2,15p "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
model_platforms=()
case "$models" in
    none) ;;
    ''|*,|,*|*,,*) echo "--models needs macos,ios|macos|ios|none, got '$models'" >&2; exit 2 ;;
    *)
        IFS=',' read -r -a model_platforms <<< "$models"
        for platform in "${model_platforms[@]}"; do
            case "$platform" in
                macos|ios) ;;
                *) echo "Unknown --models platform: $platform (expected macos, ios or none)" >&2; exit 2 ;;
            esac
        done
        ;;
esac

PYTHON="${PYTHON:-python3}"
CACHE="${RAWLAB_PREFLIGHT_CACHE:-$ROOT/.cache/tmp/release-preflight}"
summary=()

run_step() {
    local name="$1"; shift
    local started rc=0
    started="$(date +%s)"
    printf '\n[preflight] ==> %s\n' "$name"
    # 不能写成 `"$@" || rc=$?`：|| 语境会让步骤函数里的 set -e 整体失效，中途失败被吞掉。
    # 步骤放进子 shell 单独开 set -e，同时隔离 build-env.sh 导出的环境变量。
    set +e
    ( set -e; "$@" )
    rc=$?
    set -e
    local elapsed=$(( $(date +%s) - started ))
    if [ "$rc" -ne 0 ]; then
        summary+=("FAIL  $name (${elapsed}s, exit $rc)")
        printf '[preflight] %s\n' "${summary[@]}" >&2
        printf 'error: release preflight step "%s" failed with exit code %s\n' "$name" "$rc" >&2
        exit "$rc"
    fi
    summary+=("PASS  $name (${elapsed}s)")
}

check_version() {
    "$PYTHON" scripts/version/generate.py --check
    "$PYTHON" -m unittest scripts.ci.test_versioning
}

check_docs() {
    "$PYTHON" -m unittest scripts.ci.test_doc_links
}

# 与 RawLabMac/build.sh 的应用 swiftc 调用保持同一组源文件、桥接头、框架与编译条件；
# scripts/release/tests/test_preflight.py 会核对两边的源文件集合不漂移。
mac_typecheck() {
    source "$ROOT/RawLabMac/build-env.sh"
    local sdk sparkle swiftpm_bin
    sdk="$(rawlab_mac_sdk_path)"
    sparkle="$(bash "$ROOT/RawLabMac/prepare-sparkle.sh")"
    mkdir -p "$CACHE"
    # 正式包默认带 RUM（RAWLAB_RUM=1），类型检查同样打开，避免 #if RAWLAB_RUM 分支漏检。
    bash "$ROOT/scripts/rum/prepare-macos.sh" "$CACHE/rum-sdk" >/dev/null
    local swiftpm_flags=(--package-path "$ROOT" --scratch-path "$CACHE/swiftpm-$ARCH" -c release --arch "$ARCH"
        -Xswiftc -sdk -Xswiftc "$sdk" -Xswiftc -target -Xswiftc "$ARCH-apple-macosx$MACOSX_DEPLOYMENT_TARGET")
    SDKROOT="$sdk" swift build "${swiftpm_flags[@]}"
    swiftpm_bin="$(SDKROOT="$sdk" swift build "${swiftpm_flags[@]}" --show-bin-path)"
    local include_flags=(-I "$swiftpm_bin")
    if [ -d "$swiftpm_bin/Modules" ]; then
        include_flags+=(-I "$swiftpm_bin/Modules")
    fi
    include_flags+=(-Xcc "-fmodule-map-file=$ROOT/lutools/include/sony2fuji/ffi/module.modulemap")
    local app_sources=()
    while IFS= read -r -d '' source; do app_sources+=("$source"); done < <(find "$ROOT/RawLabMac/Sources" -name '*.swift' -print0)
    swiftc -typecheck -swift-version 5 \
        -sdk "$sdk" -target "$ARCH-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
        -module-cache-path "$CACHE/module-cache" \
        "${include_flags[@]}" \
        -D RAWLAB_RUM -I "$CACHE/rum-sdk/module" \
        -F "$(dirname "$sparkle")" \
        -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h" \
        "${app_sources[@]}" "$ROOT"/Shared/*.swift "$ROOT"/Shared/Native/*.swift
    printf 'PASS: RawLabMac app sources typecheck (%s, %d app files)\n' "$ARCH" "${#app_sources[@]}"
}

run_step "version" check_version
run_step "docs" check_docs
if [ "$mac_compile" = 1 ]; then
    run_step "mac-compile" mac_typecheck
fi
for platform in ${model_platforms[@]+"${model_platforms[@]}"}; do
    run_step "models-$platform" bash "$ROOT/scripts/ci/apple-models.sh" "$platform"
done

printf '\n[preflight] summary\n'
printf '[preflight] %s\n' "${summary[@]}"
