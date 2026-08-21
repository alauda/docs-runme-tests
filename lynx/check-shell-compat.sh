#!/usr/bin/env bash
# 校验：不允许出现「$VAR 紧跟非 ASCII 字符」的写法，必须写成 ${VAR}
#
# 为什么这是个真 bug 而不是风格问题：
#   bash 用 isalnum() 判断变量名的结束位置，而 isalnum() 是随 locale 变的。
#   在 macOS（BSD libc）的 UTF-8 locale 下，isalnum() 把 0x80-0xFF 的单字节当成
#   Latin-1 码位来分类，中文标点（如 '：' = EF BC 9A）的首字节 0xEF 会被判成字母，
#   于是 "docs-test \$MODE：" 里的变量名被解析成 MODE\xef\xbc\x9a —— 未定义。
#   （上面这行的反斜杠是为了不被本脚本自己扫出来，实际代码里当然没有反斜杠。）
#   叠加 set -u 就是 "unbound variable" 直接退出。
#   本机（glibc + UTF-8）看不出问题，本脚本用 en_US.ISO-8859-1 locale 实测复现过。
# 写成 ${VAR} 后名字边界由花括号确定，与 locale 无关。
#
# 用法: bash lynx/check-shell-compat.sh [<file.sh>...]
#       不带参数时扫描仓库内全部 *.sh（跳过 bin/、package/、.superpowers/ 等缓存目录）
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

files=()
if [ $# -gt 0 ]; then
    files=("$@")
else
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "${FRAMEWORK_ROOT}" -type f -name '*.sh' \
        -not -path '*/.git/*' \
        -not -path '*/.superpowers/*' \
        -not -path "${FRAMEWORK_ROOT}/bin/*" \
        -not -path "${FRAMEWORK_ROOT}/package/*" \
        -not -path "${FRAMEWORK_ROOT}/assets/*" | sort)
fi

if [ ${#files[@]} -eq 0 ]; then
    printf '错误: 没有可扫描的脚本\n' >&2
    exit 1
fi

# 反斜杠转义的 \$VAR 是字面量文本，不参与展开，排除掉
pattern='(?<!\\)\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7F])'

hits="$(grep -nP "${pattern}" "${files[@]}" 2>/dev/null || true)"

if [ -n "${hits}" ]; then
    printf '错误: 以下位置的 $VAR 紧跟非 ASCII 字符，在 macOS/bash 3.2 上会被解析成错误的变量名，请改写成 ${VAR}：\n' >&2
    printf '%s\n' "${hits}" | sed 's/^/  /' >&2
    exit 1
fi

printf 'shell 兼容性校验通过：%d 个脚本无「$VAR 紧跟非 ASCII」写法\n' "${#files[@]}"
