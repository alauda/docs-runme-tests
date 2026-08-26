#!/usr/bin/env bash
# 校验 lynx/docs-refs.tsv：三个 build-arg 齐全、无重复、ref 非空且不含空白。
# 分支、tag 和完整 commit SHA 均由构建期 clone helper 处理；这里不限制具体命名，
# 以免误伤文档仓库已有的合法 ref。
# 用法: bash lynx/check-docs-refs.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REFS="${FRAMEWORK_ROOT}/lynx/docs-refs.tsv"

if [ ! -f "${REFS}" ]; then
    printf '错误: 找不到 %s\n' "${REFS}" >&2
    exit 1
fi

rc=0

bad="$(awk -F'\t' '!/^#/ && NF > 0 && (NF != 2 || $1 !~ /^(MESH|OTEL|TRACING)_DOCS_REF$/ || $2 == "" || $2 ~ /[[:space:]]/) {print NR": "$0}' "${REFS}")"
if [ -n "${bad}" ]; then
    printf '错误: 以下行格式不合法（需两列 TAB 分隔，第一列是 MESH/OTEL/TRACING_DOCS_REF，第二列是非空且无空白的 ref）：\n' >&2
    printf '%s\n' "${bad}" | sed 's/^/  /' >&2
    rc=1
fi

for key in MESH_DOCS_REF OTEL_DOCS_REF TRACING_DOCS_REF; do
    n="$(awk -F'\t' -v k="${key}" '!/^#/ && $1 == k {c++} END {print c+0}' "${REFS}")"
    if [ "${n}" -ne 1 ]; then
        printf '错误: %s 出现 %s 次，应恰好 1 次\n' "${key}" "${n}" >&2
        rc=1
    fi
done

if [ "${rc}" -eq 0 ]; then
    printf '文档仓库 ref 清单校验通过：\n'
    awk -F'\t' '!/^#/ && NF == 2 {printf "  %s = %s\n", $1, $2}' "${REFS}"
fi
exit "${rc}"
