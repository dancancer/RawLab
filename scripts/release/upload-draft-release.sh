#!/bin/bash
# ============================================================================
#  把 13 个标准发布资产上传到 GitHub Draft Release，并用 API 逐个核对 size 与 SHA-256。
#  用法：
#    GH_TOKEN="$(gh auth token --user dancancer)" bash scripts/release/upload-draft-release.sh \
#        --dist "$DIST" --notes-file "$NOTES_FILE" [--version X.Y.Z] [--repo dancancer/RawLab] \
#        [--jobs 4] [--attempts 4] [--verify-only]
#  流程：
#    1. 本地核对：$DIST 恰好是 13 个标准文件，SHA256SUMS.txt 覆盖其余 12 个且全部校验通过；
#    2. 先建空 Draft（不带资产）。已有同 tag 的 Draft 则复用；同 tag 已正式发布则拒绝；
#    3. 3–4 路并发上传，单个资产失败按退避重试（--clobber 覆盖半截资产），全部失败项汇总到 stderr；
#    4. 通过 API 读取 Draft 资产：数量 13、文件名集合一致、每个 size 与 digest(sha256) 与本地一致。
#  本脚本只上传与核验，从不转正；核验通过后由发布人按发布规范执行 gh release edit --draft=false。
#  测试钩子：GH 指定 gh 可执行文件，RAWLAB_UPLOAD_BACKOFF 指定重试退避基数（秒）。
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GH="${GH:-gh}"
PYTHON="${PYTHON:-python3}"

# 内部入口：由 xargs 并发调用，负责单个资产的上传与重试。
if [ "${1:-}" = "--upload-one" ]; then
    tag="$2"; repo="$3"; attempts="$4"; status_dir="$5"; file="$6"
    name="$(basename "$file")"
    backoff="${RAWLAB_UPLOAD_BACKOFF:-5}"
    attempt=1
    while :; do
        if "$GH" release upload "$tag" "$file" --repo "$repo" --clobber >"$status_dir/$name.log" 2>&1; then
            printf 'uploaded %s (attempt %d/%d)\n' "$name" "$attempt" "$attempts"
            : > "$status_dir/$name.ok"
            exit 0
        fi
        if [ "$attempt" -ge "$attempts" ]; then
            printf 'error: upload %s failed after %d attempt(s):\n' "$name" "$attempt" >&2
            sed 's/^/error:     /' "$status_dir/$name.log" >&2
            exit 1
        fi
        printf 'retry %s: attempt %d/%d failed\n' "$name" "$attempt" "$attempts" >&2
        sleep $(( backoff * attempt ))
        attempt=$(( attempt + 1 ))
    done
fi

usage() { sed -n 2,15p "$0"; }
version=""
repo="dancancer/RawLab"
dist=""
notes=""
jobs=4
attempts=4
verify_only=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) version="${2:?}"; shift 2 ;;
        --repo) repo="${2:?}"; shift 2 ;;
        --dist) dist="${2:?}"; shift 2 ;;
        --notes-file) notes="${2:?}"; shift 2 ;;
        --jobs) jobs="${2:?}"; shift 2 ;;
        --attempts) attempts="${2:?}"; shift 2 ;;
        --verify-only) verify_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if [ -z "$version" ]; then
    version="$("$PYTHON" "$ROOT/scripts/version/generate.py" --print version)"
fi
case "$jobs" in ''|*[!0-9]*) echo "--jobs must be a positive integer" >&2; exit 2 ;; esac
case "$attempts" in ''|*[!0-9]*) echo "--attempts must be a positive integer" >&2; exit 2 ;; esac
[ "$jobs" -ge 1 ] && [ "$attempts" -ge 1 ] || { echo "--jobs and --attempts must be >= 1" >&2; exit 2; }
[ -n "$dist" ] && [ -d "$dist" ] || { echo "--dist must name the directory holding the 13 release assets" >&2; exit 2; }
dist="$(cd "$dist" && pwd)"
if [ "$verify_only" = 0 ]; then
    [ -n "$notes" ] && [ -f "$notes" ] || { echo "--notes-file must name the UTF-8 release notes file" >&2; exit 2; }
fi
# 发布仓库只有授权账号可写；显式要求令牌，避免落到默认只读账号上传到一半才报 403。
[ -n "${GH_TOKEN:-}" ] || { echo 'GH_TOKEN is not set; use GH_TOKEN="$(gh auth token --user dancancer)"' >&2; exit 2; }
tag="v$version"

# 资产清单与 docs/process/release-packaging-guide.md「标准产物清单」一一对应。
expected=(
    "RawLab-Mac-$version-arm64.zip"
    "RawLab-Mac-$version-x86_64.zip"
    "RawLab.Desktop-stable-Setup.exe"
    "RawLab.Desktop-$version-stable-full.nupkg"
    "RawLab-Windows-$version-x64.zip"
    "RawLab-Android-$version.apk"
    "RawLab-iOS-$version-unsigned.ipa"
    "RawLab-$version-source.tar.gz"
    "appcast-arm64.xml"
    "appcast-x86_64.xml"
    "windows-stable.json"
    "BUILD-PROVENANCE.json"
    "SHA256SUMS.txt"
)

# ---- 1. 本地核对 ----
"$PYTHON" - "$dist" "${expected[@]}" <<'PY'
import hashlib, sys
from pathlib import Path
dist = Path(sys.argv[1]); expected = sys.argv[2:]
actual = sorted(p.name for p in dist.iterdir() if not p.name.startswith("."))
missing = sorted(set(expected) - set(actual)); extra = sorted(set(actual) - set(expected))
errors = [f"missing asset: {n}" for n in missing] + [f"unexpected file in dist: {n}" for n in extra]
for name in expected:
    path = dist / name
    if path.exists() and (not path.is_file() or path.stat().st_size == 0):
        errors.append(f"asset is empty or not a regular file: {name}")
if not errors:
    sums = {}
    for line in (dist / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        digest, _, name = line.partition("  ")
        sums[name.lstrip("*")] = digest.strip().lower()
    covered = sorted(n for n in expected if n != "SHA256SUMS.txt")
    if sorted(sums) != covered:
        errors.append(f"SHA256SUMS.txt must list exactly the other 12 assets, found: {sorted(sums)}")
    else:
        for name in covered:
            local = hashlib.sha256((dist / name).read_bytes()).hexdigest()
            if local != sums[name]:
                errors.append(f"SHA256SUMS.txt mismatch: {name}")
if errors:
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
print(f"local: 13/13 assets present, SHA256SUMS.txt 12/12 OK")
PY

release_state() {
    # 输出 none / draft / published；同 tag 的 Draft 通过 tag 查询同样可见。
    local out
    if ! out="$("$GH" release view "$tag" --repo "$repo" --json isDraft --jq '.isDraft' 2>&1)"; then
        case "$out" in
            *"release not found"*|*"Not Found"*) echo none; return 0 ;;
            *) printf 'error: cannot query release %s: %s\n' "$tag" "$out" >&2; return 1 ;;
        esac
    fi
    case "$out" in
        true) echo draft ;;
        false) echo published ;;
        *) printf 'error: unexpected isDraft value for %s: %s\n' "$tag" "$out" >&2; return 1 ;;
    esac
}

state="$(release_state)"
if [ "$state" = published ]; then
    echo "error: $tag is already published; this script only uploads to a Draft" >&2
    exit 1
fi

# ---- 2/3. 建空 Draft 并并发上传 ----
if [ "$verify_only" = 0 ]; then
    if [ "$state" = none ]; then
        "$GH" release create "$tag" --repo "$repo" --verify-tag --draft \
            --title "RawLab $version" --notes-file "$notes"
        echo "created empty draft $tag"
    else
        echo "reusing existing draft $tag"
    fi
    status_dir="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-upload.XXXXXX")"
    trap 'rm -rf "$status_dir"' EXIT
    upload_rc=0
    # 大包先传，缩短并发尾巴。
    for name in "${expected[@]}"; do
        printf '%s\t%s\n' "$(wc -c < "$dist/$name" | tr -d ' ')" "$dist/$name"
    done | sort -rn | cut -f2- | tr '\n' '\0' |
        xargs -0 -n1 -P "$jobs" bash "$0" --upload-one "$tag" "$repo" "$attempts" "$status_dir" || upload_rc=$?
    failed=()
    for name in "${expected[@]}"; do
        [ -f "$status_dir/$name.ok" ] || failed+=("$name")
    done
    if [ "${#failed[@]}" -gt 0 ] || [ "$upload_rc" -ne 0 ]; then
        printf 'error: %d asset(s) failed to upload to draft %s:\n' "${#failed[@]}" "$tag" >&2
        printf 'error:   %s\n' ${failed[@]+"${failed[@]}"} >&2
        echo "error: rerun the same command to resume; the draft stays unpublished" >&2
        exit 1
    fi
fi

# ---- 4. API 核验 ----
[ "$(release_state)" = draft ] || { echo "error: $tag is no longer a draft; refusing to report it verified" >&2; exit 1; }
release_id="$("$GH" release view "$tag" --repo "$repo" --json databaseId --jq '.databaseId')"
assets_file="$(mktemp "${TMPDIR:-/tmp}/rawlab-assets.XXXXXX")"
"$GH" api "repos/$repo/releases/$release_id/assets?per_page=100" > "$assets_file"
verify_rc=0
"$PYTHON" - "$assets_file" "$dist" "${expected[@]}" <<'PY' || verify_rc=$?
import hashlib, json, sys
from pathlib import Path
assets = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
dist = Path(sys.argv[2]); expected = sys.argv[3:]
errors = []
remote = {a["name"]: a for a in assets}
if len(assets) != len(expected):
    errors.append(f"draft has {len(assets)} assets, expected {len(expected)}")
for name in sorted(set(remote) - set(expected)):
    errors.append(f"unexpected remote asset: {name}")
ok = 0
for name in expected:
    asset = remote.get(name)
    if asset is None:
        errors.append(f"missing remote asset: {name}")
        continue
    local = dist / name
    size = local.stat().st_size
    sha = hashlib.sha256(local.read_bytes()).hexdigest()
    digest = (asset.get("digest") or "").lower()
    state = asset.get("state")
    problems = []
    if state != "uploaded":
        problems.append(f"state={state}")
    if asset.get("size") != size:
        problems.append(f"size {asset.get('size')} != local {size}")
    if not digest:
        problems.append("API returned no digest; cannot verify SHA-256")
    elif digest != f"sha256:{sha}":
        problems.append(f"digest {digest} != local sha256:{sha}")
    if problems:
        errors.append(f"{name}: " + "; ".join(problems))
    else:
        ok += 1
print(f"remote: {ok}/{len(expected)} assets match local size and sha256")
for e in errors:
    print(f"error: {e}", file=sys.stderr)
sys.exit(1 if errors else 0)
PY
rm -f "$assets_file"
if [ "$verify_rc" -ne 0 ]; then
    echo "error: draft $tag failed API verification; do not publish it" >&2
    exit 1
fi
echo "draft $tag verified; publish only after the release checklist passes:"
echo "  gh release edit $tag --repo $repo --draft=false --latest"
