#!/bin/bash
# 辅助功能（AX）UI 套件的共享前置门（契约见 docs/process/ci.md，与 hdr-rendition-ui
# 的 RAWLAB_REQUIRE_AX 形态一致）。形态同 native-env.sh：调用方 `source` 后直接调用
# `rawlab_ax_gate`，由门在需要时自行 exit：
# - AX 可用：返回，脚本照常真跑检查；
# - AX 不可用且设置了 RAWLAB_REQUIRE_AX：向 stderr 打印一行 FAIL 原因，exit 1；
# - AX 不可用且未设档：打印 SKIP + ::warning::（行为标记，不算真跑），exit 0。
# 探测与 Swift 测试内的 AXIsProcessTrusted() 同一 API：临时编译两行探针，
# 探针本身失败时不下结论（返回），交给脚本自身的编译/断言报错。
rawlab_ax_gate() {
    local out verdict
    out="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ax-gate.XXXXXX")" || return 0
    printf 'import ApplicationServices\nprint(AXIsProcessTrusted())\n' > "$out/probe.swift"
    if swiftc "$out/probe.swift" -o "$out/probe" 2>/dev/null; then
        verdict="$("$out/probe" 2>/dev/null || echo unknown)"
    else
        verdict=unknown
    fi
    rm -rf "$out"
    [ "$verdict" = "true" ] && return 0
    [ "$verdict" = "false" ] || return 0
    if [ -n "${RAWLAB_REQUIRE_AX:-}" ]; then
        echo "FAIL: RAWLAB_REQUIRE_AX is set but accessibility is not granted; the AX checks cannot run" >&2
        exit 1
    fi
    local notice="SKIP: accessibility is not trusted here; the AX checks did not run"
    echo "$notice"
    # 与 GitHub Actions 的注解语法一致；本地普通终端只会多一行 ::warning::。
    echo "::warning::$notice"
    exit 0
}
