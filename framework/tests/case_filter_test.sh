#!/usr/bin/env bash
# case-filter.sh 单元测试（纯 bash，不依赖集群）
# 用法: bash framework/tests/case_filter_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/lynx/case-filter.sh"

T_PASS=0
T_FAIL=0

# check_rc <描述> <期望返回码> <case_type> <tag...>
check_rc() {
    local desc="$1" want="$2" expr="$3"; shift 3
    local got=0
    _case_type_matches "$expr" "$@" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$desc"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望 rc=%s 实际 rc=%s\n' "$desc" "$want" "$got"
    fi
}

test_matches() {
    printf '\n== _case_type_matches ==\n'
    check_rc "空表达式全选"            0 ""                          smoke install
    check_rc "单标签命中"              0 "smoke"                     smoke install
    check_rc "单标签未命中"            1 "update"                    smoke install
    check_rc "合取全命中"              0 "smoke and install"         smoke install sidecar
    check_rc "合取部分命中即未选中"    1 "smoke and update"          smoke install
    check_rc "not 排除命中"            1 "smoke and not egress"      smoke egress
    check_rc "not 排除未命中"          0 "smoke and not egress"      smoke install
    check_rc "仅 not"                  0 "not egress"                smoke install
    check_rc "always 恒选中"           0 "update and not install"    always install
    check_rc "always 对空表达式亦可"   0 ""                          always
    check_rc "or 表达式非法"           2 "smoke or update"           smoke
    check_rc "标签前缀不误命中"        1 "smoke"                     smoketest install
}

main() {
    test_matches
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
