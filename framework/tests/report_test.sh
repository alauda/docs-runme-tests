#!/usr/bin/env bash
# report.sh 单元测试（纯 bash，可独立运行，不依赖集群）
# 用法: bash framework/tests/report_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/report.sh"

T_PASS=0
T_FAIL=0

# check_contains <描述> <实际> <期望子串>
check_contains() {
    if __cmp_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# check_eq <描述> <实际> <期望>
check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 每个用例用独立的临时 RUN_DIR
new_sandbox() {
    unset RUNME_TEST_RUN_DIR RUNME_TEST_RUN_ID RUNME_TEST_CASE_ID RUNME_TEST_CASE_NAME
    RUNME_TEST_RUN_DIR="$(mktemp -d)"
    export RUNME_TEST_RUN_DIR
    : > "$RUNME_TEST_RUN_DIR/results.jsonl"
}

# ── 测试：_doctest_name_from_script 解析 ──
test_name_parse() {
    printf '\n== _doctest_name_from_script ==\n'
    check_eq "去前缀去后缀" "$(_doctest_name_from_script /a/b/runme-test_kiali.sh)" "kiali"
    check_eq "多段连字符" "$(_doctest_name_from_script runme-test_install-mesh.sh)" "install-mesh"
}

# ── 测试：写入 doctest 记录 ──
test_record_doctest() {
    printf '\n== report_record_doctest ==\n'
    new_sandbox
    report_record_doctest mesh kiali runme-test_kiali.sh test failed "" "pod 未就绪" 100 160
    local line; line="$(cat "$RUNME_TEST_RUN_DIR/results.jsonl")"
    check_contains "type=doctest" "$line" '"type":"doctest"'
    check_contains "file=kiali" "$line" '"file":"kiali"'
    check_contains "status=failed" "$line" '"status":"failed"'
    check_contains "duration=60" "$line" '"duration_s":60'
    rm -rf "$RUNME_TEST_RUN_DIR"
}

# ── 测试：case_skip 记录 ──
test_case_skip() {
    printf '\n== case_skip ==\n'
    new_sandbox
    case_skip 2 "双栈网格安装" "IS_DUAL_STACK != true" >/dev/null
    local line; line="$(cat "$RUNME_TEST_RUN_DIR/results.jsonl")"
    check_contains "type=case_skip" "$line" '"type":"case_skip"'
    check_contains "reason" "$line" '"skip_reason":"IS_DUAL_STACK != true"'
    check_contains "case_id=2" "$line" '"case_id":"2"'
    rm -rf "$RUNME_TEST_RUN_DIR"
}

# ── 测试：最小 finalize 退出码 ──
test_finalize_exit() {
    printf '\n== report_finalize 退出码 ==\n'
    new_sandbox
    report_record_doctest mesh a x.sh test passed "" "" 1 2
    report_finalize >/dev/null 2>&1; check_eq "全通过→0" "$?" "0"
    new_sandbox
    report_record_doctest mesh a x.sh test failed "" "boom" 1 2
    report_finalize >/dev/null 2>&1; check_eq "有失败→1" "$?" "1"
    new_sandbox
    report_finalize >/dev/null 2>&1; check_eq "空结果→0" "$?" "0"
    rm -rf "$RUNME_TEST_RUN_DIR"
}

main() {
    test_name_parse
    test_record_doctest
    test_case_skip
    test_finalize_exit
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
