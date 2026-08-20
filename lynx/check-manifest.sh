#!/usr/bin/env bash
# 校验：文档命名代码块里的每一个 `-f <外部 URL>` 都已登记进 lynx/assets-manifest.tsv
#
# 挂在镜像构建流水线上。文档改了 URL 而清单没跟上时，镜像里就会缺资产，
# 离线环境跑到一半才炸——这里提前拦住。
#
# 用法: bash lynx/check-manifest.sh [<doc-repo-root>...]
#       不带参数时按 repos.conf 遍历所有已注册的文档仓库。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$FRAMEWORK_ROOT/lynx/assets-manifest.tsv"

if [ ! -f "$MANIFEST" ]; then
    printf '错误: 找不到清单 %s\n' "$MANIFEST" >&2
    exit 1
fi

# 收集待扫描的文档仓库
repos=()
if [ $# -gt 0 ]; then
    repos=("$@")
else
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [ -n "$line" ] || continue
        path="${line#*:}"
        case "$path" in
            /*) resolved="$path" ;;
            *)  resolved="$FRAMEWORK_ROOT/$path" ;;
        esac
        [ -d "$resolved" ] && repos+=("$resolved")
    done < "$FRAMEWORK_ROOT/repos.conf"
fi

if [ ${#repos[@]} -eq 0 ]; then
    printf '错误: 没有可扫描的文档仓库\n' >&2
    exit 1
fi

# 提取命名代码块内 `-f <url>` 形式的 URL
extract_urls() {
    local repo="$1"
    [ -d "$repo/docs" ] || return 0
    find "$repo/docs" -name '*.mdx' -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
        awk '
            /^[[:space:]]*```/ {
                if (inblock) { inblock = 0 }
                else if ($0 ~ /\{name=/) { inblock = 1 }
                next
            }
            inblock {
                s = $0
                while (match(s, /-f[[:space:]]+https?:\/\/[^[:space:]"'"'"']+/)) {
                    u = substr(s, RSTART, RLENGTH)
                    sub(/^-f[[:space:]]+/, "", u)
                    print u
                    s = substr(s, RSTART + RLENGTH)
                }
            }
        ' "$f"
    done
}

tmp_found="$(mktemp)"
tmp_known="$(mktemp)"
trap 'rm -f "$tmp_found" "$tmp_known"' EXIT

for repo in "${repos[@]}"; do
    extract_urls "$repo"
done | sort -u > "$tmp_found"

awk -F'\t' '/^https?:\/\//{print $1}' "$MANIFEST" | sort -u > "$tmp_known"

missing="$(comm -23 "$tmp_found" "$tmp_known")"
stale="$(comm -13 "$tmp_found" "$tmp_known")"

rc=0
if [ -n "$missing" ]; then
    printf '错误: 以下文档 URL 未登记进 %s：\n' "$MANIFEST" >&2
    printf '%s\n' "$missing" | sed 's/^/  - /' >&2
    rc=1
fi
if [ -n "$stale" ]; then
    printf '警告: 清单中以下 URL 已不再被任何文档引用（可清理）：\n' >&2
    printf '%s\n' "$stale" | sed 's/^/  - /' >&2
fi
if [ "$rc" -eq 0 ]; then
    printf '资产清单校验通过：%d 个 URL 全部已登记\n' "$(wc -l < "$tmp_found" | tr -d ' ')"
fi
exit "$rc"
