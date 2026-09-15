#!/usr/bin/env bash
# framework/verify.sh 单元测试（纯 bash，不联网、不依赖集群）
# 用法: bash framework/tests/verify_test.sh
#
# 重点覆盖 ANSI 转义序列的处理：runme 用 PTY 执行代码块，块里带
# `--color=auto` 的 grep 会给匹配文本套颜色码，关键字跨过着色段就会被截断。
# 这类失败在日志里看起来完全正常（终端把颜色码渲染掉了），必须有单测兜住。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/verify.sh"

T_PASS=0
T_FAIL=0

check() {
    if [ "$2" = "$3" ]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

yn() { if "$@"; then echo yes; else echo no; fi; }

# grep --color=auto 的真实形态：匹配段被 <ESC>[01;31m<ESC>[K ... <ESC>[m<ESC>[K 包住，
# 行尾还有 PTY 带来的 CR
ESC=$(printf '\033')
COLORED="2026-09-15T12:44:47Z INF ${ESC}[01;31m${ESC}[KDiscovered cluster${ESC}[m${ESC}[K: Name=[cluster1], Accessible=true, IsKialiHome=true, ApiEndpoint=[https://100.4.0.1:443], SecretName=[]$(printf '\r')"
PLAIN="2026-09-15T12:44:47Z INF Discovered cluster: Name=[cluster1], Accessible=true, IsKialiHome=true, ApiEndpoint=[https://100.4.0.1:443], SecretName=[]"

test_strip_ansi() {
    printf '\n== __strip_ansi ==\n'
    check "去掉颜色码" "$(__strip_ansi "${ESC}[01;31m${ESC}[Kfoo${ESC}[m${ESC}[K")" "foo"
    check "不含 ESC 时原样返回" "$(__strip_ansi 'plain text')" "plain text"
    check "多行也处理" "$(__strip_ansi "a${ESC}[0mb
c${ESC}[1;32md")" "ab
cd"
}

test_cmp_contains_colored() {
    printf '\n== __cmp_contains 忽略颜色码 ==\n'
    # 关键字跨过被着色的 "Discovered cluster"，未剥离颜色码时必然匹配不到
    local kw="Discovered cluster: Name=[cluster1], Accessible=true, IsKialiHome=true"
    check "带颜色码的输出仍能命中关键字" "$(yn __cmp_contains "$COLORED" "$kw")" "yes"
    check "干净输出照常命中"             "$(yn __cmp_contains "$PLAIN" "$kw")" "yes"
    check "不存在的关键字不误判"         "$(yn __cmp_contains "$COLORED" "Name=[cluster9]")" "no"
    check "not_contains 也忽略颜色码"    "$(yn __cmp_not_contains "$COLORED" "$kw")" "no"
}

test_cmp_lines_colored() {
    printf '\n== __cmp_lines 忽略颜色码 ==\n'
    local expected='+ Discovered cluster: Name=[cluster1], Accessible=true, IsKialiHome=true
- Name=[cluster9]'
    check "逐行断言通过" "$(yn __cmp_lines "$COLORED" "$expected")" "yes"
}

test_cmp_same_unaffected() {
    printf '\n== 无 ESC 时行为不变 ==\n'
    # 不含 ESC 的输出不走 sed 子进程，尾部换行等既有语义保持原样
    check "精确匹配"           "$(yn __cmp_same "$PLAIN" "$PLAIN")" "yes"
    check "CR 仍被剥离"        "$(yn __cmp_same "abc$(printf '\r')" "abc")" "yes"
    check "首行匹配"           "$(yn __cmp_first_line "$PLAIN
second" "$PLAIN")" "yes"
    check "正则匹配"           "$(yn __cmp_regex "$PLAIN" 'Name=\[cluster1\]')" "yes"
}

main() {
    test_strip_ansi
    test_cmp_contains_colored
    test_cmp_lines_colored
    test_cmp_same_unaffected
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
