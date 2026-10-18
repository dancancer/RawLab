#!/bin/bash
# ============================================================================
#  阿里云 RUM SDK 的共享缓存位置：主工作区的 .cache/shared/aliyun-rum
#  worktree 里也指向主工作区，SDK 只下载一次；用法：source 后读 RUM_CACHE_ROOT
# ============================================================================
RUM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUM_COMMON_GIT="$(git -C "$RUM_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
RUM_CACHE_ROOT="${RAWLAB_RUM_CACHE:-$(dirname "${RUM_COMMON_GIT:-$RUM_REPO/.git}")/.cache/shared/aliyun-rum}"
