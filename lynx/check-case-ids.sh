#!/usr/bin/env bash
# 校验 lynx/case-ids.tsv：格式合法、编号唯一、每个 runme-test_*.sh 都已登记
# 用法: bash lynx/check-case-ids.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IDS="$FRAMEWORK_ROOT/lynx/case-ids.tsv"

if [ ! -f "$IDS" ]; then
    printf '错误: 找不到 %s\n' "$IDS" >&2
    exit 1
fi

rc=0

# 1. 每条记录三列，且编号格式合法
bad_fmt="$(awk -F'\t' '!/^#/ && NF > 0 && (NF != 3 || $3 !~ /^(ASM|OTEL|TRACE)-DOC-[0-9]{3}$/) {print NR": "$0}' "$IDS")"
if [ -n "$bad_fmt" ]; then
    printf '错误: 以下行格式不合法（需三列 TAB 分隔，编号形如 ASM-DOC-001）：\n' >&2
    printf '%s\n' "$bad_fmt" | sed 's/^/  /' >&2
    rc=1
fi

# 2. 编号唯一
dup_id="$(awk -F'\t' '!/^#/ && NF == 3 {print $3}' "$IDS" | sort | uniq -d)"
if [ -n "$dup_id" ]; then
    printf '错误: 重复的 case_id：\n' >&2
    printf '%s\n' "$dup_id" | sed 's/^/  - /' >&2
    rc=1
fi

# 3. project+doc 组合唯一
dup_doc="$(awk -F'\t' '!/^#/ && NF == 3 {print $1"/"$2}' "$IDS" | sort | uniq -d)"
if [ -n "$dup_doc" ]; then
    printf '错误: 重复的 project/doc：\n' >&2
    printf '%s\n' "$dup_doc" | sed 's/^/  - /' >&2
    rc=1
fi

# 4. 每个已存在的 runme-test_*.sh 都已登记
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [ -n "$line" ] || continue
    name="${line%%:*}"
    path="${line#*:}"
    case "$path" in
        /*) repo="$path" ;;
        *)  repo="$FRAMEWORK_ROOT/$path" ;;
    esac
    [ -d "$repo/docs" ] || continue
    find "$repo/docs" -type f -name 'runme-test_*.sh' | while IFS= read -r f; do
        doc="$(basename "$f")"; doc="${doc#runme-test_}"; doc="${doc%.sh}"
        if ! awk -F'\t' -v p="$name" -v d="$doc" '!/^#/ && $1==p && $2==d {found=1} END {exit !found}' "$IDS"; then
            printf '错误: 未登记 case_id: %s/%s（%s）\n' "$name" "$doc" "$f" >&2
            printf 'x' >> "$FRAMEWORK_ROOT/.case-id-miss"
        fi
    done
done < "$FRAMEWORK_ROOT/repos.conf"

if [ -f "$FRAMEWORK_ROOT/.case-id-miss" ]; then
    rm -f "$FRAMEWORK_ROOT/.case-id-miss"
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    printf 'case_id 清单校验通过：%d 条记录\n' "$(awk -F'\t' '!/^#/ && NF == 3' "$IDS" | wc -l | tr -d ' ')"
fi
exit "$rc"
