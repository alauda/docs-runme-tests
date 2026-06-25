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

# ── 测试：三层聚合 summary.json ──
test_aggregate() {
    printf '\n== _report_aggregate / summary.json ==\n'
    new_sandbox
    RUNME_TEST_RUN_ID="testrun"; RUNME_TEST_PROJECT="mesh"; RUNME_TEST_RUN_START=100
    export RUNME_TEST_RUN_ID RUNME_TEST_PROJECT RUNME_TEST_RUN_START
    # 构造：init case(passed,无doctest) / case_skip / 普通case(passed+skipped+failed)
    printf '%s\n' \
      '{"type":"case","case_id":"1","case_name":"初始化","status":"passed","duration_s":130}' \
      '{"type":"case_skip","case_id":"2","case_name":"双栈","skip_reason":"IS_DUAL_STACK != true"}' \
      '{"type":"doctest","project":"mesh","file":"install-mesh","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"passed","skip_reason":"","fail_reason":"","start_ts":100,"end_ts":280,"duration_s":180}' \
      '{"type":"doctest","project":"tracing","file":"es","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"skipped","skip_reason":"未配置 ES","fail_reason":"","start_ts":280,"end_ts":281,"duration_s":1}' \
      '{"type":"doctest","project":"mesh","file":"kiali","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"failed","skip_reason":"","fail_reason":"pod 未就绪","start_ts":281,"end_ts":791,"duration_s":510}' \
      '{"type":"case","case_id":"3","case_name":"单网格","status":"failed","duration_s":691}' \
      > "$RUNME_TEST_RUN_DIR/results.jsonl"

    report_finalize >/dev/null 2>&1
    local s; s="$(cat "$RUNME_TEST_RUN_DIR/summary.json")"
    check_eq "doctests.total"   "$(printf '%s' "$s" | jq -r '.totals.doctests.total')"   "3"
    check_eq "doctests.failed"  "$(printf '%s' "$s" | jq -r '.totals.doctests.failed')"  "1"
    check_eq "doctests.skipped" "$(printf '%s' "$s" | jq -r '.totals.doctests.skipped')" "1"
    check_eq "cases.total"      "$(printf '%s' "$s" | jq -r '.totals.cases.total')"      "3"
    check_eq "cases.skipped"    "$(printf '%s' "$s" | jq -r '.totals.cases.skipped')"    "1"
    check_eq "cases.passed"     "$(printf '%s' "$s" | jq -r '.totals.cases.passed')"     "1"
    check_eq "cases.failed"     "$(printf '%s' "$s" | jq -r '.totals.cases.failed')"     "1"
    check_eq "result"           "$(printf '%s' "$s" | jq -r '.result')"                  "failed"
    check_eq "case3 明细数"     "$(printf '%s' "$s" | jq -r '.cases[] | select(.case_id=="3") | .doctests | length')" "3"
    check_eq "case2 跳过原因"   "$(printf '%s' "$s" | jq -r '.cases[] | select(.case_id=="2") | .skip_reason')" "IS_DUAL_STACK != true"
    rm -rf "$RUNME_TEST_RUN_DIR"
}

# ── 测试：junit.xml 生成与转义 ──
test_junit() {
    printf '\n== junit.xml ==\n'
    new_sandbox
    RUNME_TEST_RUN_ID="testrun"; RUNME_TEST_PROJECT="mesh"; RUNME_TEST_RUN_START="$(date +%s)"
    export RUNME_TEST_RUN_ID RUNME_TEST_PROJECT RUNME_TEST_RUN_START
    printf '%s\n' \
      '{"type":"case_skip","case_id":"2","case_name":"双栈","skip_reason":"IS_DUAL_STACK != true"}' \
      '{"type":"doctest","project":"mesh","file":"kiali","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"failed","skip_reason":"","fail_reason":"pod <a & b>","start_ts":1,"end_ts":3,"duration_s":2}' \
      '{"type":"case","case_id":"3","case_name":"单网格","status":"failed","duration_s":2}' \
      > "$RUNME_TEST_RUN_DIR/results.jsonl"

    report_finalize >/dev/null 2>&1
    local x; x="$(cat "$RUNME_TEST_RUN_DIR/junit.xml")"
    check_contains "XML 头" "$x" '<?xml version="1.0" encoding="UTF-8"?>'
    check_contains "testsuites" "$x" '<testsuites name="mesh"'
    check_contains "testcase 命名" "$x" 'name="mesh/kiali"'
    check_contains "failure 元素" "$x" '<failure message='
    check_contains "XML 转义" "$x" 'pod &lt;a &amp; b&gt;'
    check_contains "skipped 占位" "$x" '<skipped message="IS_DUAL_STACK != true">'
    rm -rf "$RUNME_TEST_RUN_DIR"
}

# ── 测试：终端摘要 ──
test_terminal() {
    printf '\n== 终端摘要 ==\n'
    new_sandbox
    RUNME_TEST_RUN_ID="testrun"; RUNME_TEST_PROJECT="mesh"; RUNME_TEST_RUN_START=100
    export RUNME_TEST_RUN_ID RUNME_TEST_PROJECT RUNME_TEST_RUN_START
    printf '%s\n' \
      '{"type":"case_skip","case_id":"2","case_name":"双栈","skip_reason":"IS_DUAL_STACK != true"}' \
      '{"type":"doctest","project":"mesh","file":"kiali","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"failed","skip_reason":"","fail_reason":"pod 未就绪","start_ts":1,"end_ts":131,"duration_s":130}' \
      '{"type":"case","case_id":"3","case_name":"单网格","status":"failed","duration_s":130}' \
      > "$RUNME_TEST_RUN_DIR/results.jsonl"

    local out; out="$(report_finalize 2>&1)"
    check_contains "标题" "$out" "测试运行汇总"
    check_contains "Case 计数行" "$out" "Case      "
    check_contains "文档测试计数行" "$out" "文档测试"
    check_contains "失败明细含文件" "$out" "mesh/kiali"
    check_contains "失败原因" "$out" "pod 未就绪"
    check_contains "跳过明细" "$out" "双栈"
    check_contains "跳过明细含原因" "$out" "IS_DUAL_STACK != true"
    check_contains "耗时格式" "$out" "2m10s"
    rm -rf "$RUNME_TEST_RUN_DIR"
}

main() {
    test_name_parse
    test_record_doctest
    test_case_skip
    test_finalize_exit
    test_aggregate
    test_junit
    test_terminal
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
