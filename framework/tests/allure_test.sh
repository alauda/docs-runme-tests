#!/usr/bin/env bash
# lynx/allure.sh 单元测试（纯 bash + jq，不依赖集群，allure CLI 用桩替代）
# 用法: bash framework/tests/allure_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/lynx/allure.sh"

T_PASS=0
T_FAIL=0

check_contains() {
    if __cmp_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 造一份 results.jsonl：1 个 Case（含 tags）+ 2 条 doctest（1 passed 1 skipped）
make_results() {
    local f="$1"
    cat > "$f" <<'EOF'
{"type":"doctest","project":"mesh","file":"install-mesh","script":"runme-test_install-mesh.sh","case_id":"3","case_name":"单网格","phase":"test","status":"passed","skip_reason":"","fail_reason":"","start_ts":100,"end_ts":160,"duration_s":60}
{"type":"doctest","project":"mesh","file":"routing-egress-traffic-via-istio-apis","script":"runme-test_routing-egress-traffic-via-istio-apis.sh","case_id":"3","case_name":"单网格","phase":"test","status":"skipped","skip_reason":"[env] 集群不能访问外网","fail_reason":"","start_ts":160,"end_ts":161,"duration_s":1}
{"type":"case","case_id":"3","case_name":"单网格","status":"passed","tags":"smoke install sidecar","duration_s":61}
EOF
}

test_emit_results() {
    printf '\n== allure_emit_results ==\n'
    local dir; dir="$(mktemp -d)"
    make_results "$dir/results.jsonl"
    printf 'mesh\tinstall-mesh\tASM-DOC-002\n' > "$dir/case-ids.tsv"
    ALLURE_CASE_IDS_FILE="$dir/case-ids.tsv" allure_emit_results "$dir/results.jsonl" "$dir/allure-result"

    check_eq "生成 2 个用例文件" "$(find "$dir/allure-result" -name '*-result.json' | wc -l | tr -d ' ')" "2"

    local merged; merged="$(cat "$dir"/allure-result/*-result.json)"
    check_contains "fullName 带项目前缀" "$merged" '"fullName": "mesh/install-mesh"'
    check_contains "毫秒时间戳"          "$merged" '"start": 100000'
    check_contains "suite 标签"          "$merged" '"value": "Case 3: 单网格"'
    check_contains "feature 标签"        "$merged" '"value": "mesh"'
    check_contains "tag 标签展开"        "$merged" '"value": "sidecar"'
    check_contains "case_id 标签"        "$merged" '"value": "ASM-DOC-002"'
    check_contains "skipped 用例"        "$merged" '"status": "skipped"'
    check_contains "skip 原因带 env 前缀" "$merged" '[env] 集群不能访问外网'
    rm -rf "$dir"
}

test_emit_broken() {
    printf '\n== allure_emit_broken ==\n'
    local dir; dir="$(mktemp -d)"
    allure_emit_broken "$dir/allure-result" "docs-test mesh 异常退出"
    local merged; merged="$(cat "$dir"/allure-result/*-result.json)"
    check_contains "broken 状态" "$merged" '"status": "broken"'
    check_contains "含中断说明" "$merged" '异常退出'
    rm -rf "$dir"
}

test_environment_and_categories() {
    printf '\n== environment.properties / categories.json ==\n'
    local dir; dir="$(mktemp -d)"
    PLATFORM_ADDRESS="https://acp.example" PLATFORM_PASSWORD="s3cret" \
        SINGLE_CLUSTER_NAME="asm-1" CASE_TYPE="smoke and not egress" \
        allure_write_environment "$dir/allure-result"
    local env_out; env_out="$(cat "$dir/allure-result/environment.properties")"
    check_contains "写平台地址"   "$env_out" "platform.address=https://acp.example"
    check_contains "写被测集群"   "$env_out" "cluster.single=asm-1"
    check_contains "写 CASE_TYPE" "$env_out" "case.type=smoke and not egress"
    check_eq "不含密码" "$(printf '%s' "$env_out" | grep -c 's3cret')" "0"

    allure_write_categories "$dir/allure-result"
    local cat_out; cat_out="$(cat "$dir/allure-result/categories.json")"
    check_contains "含环境不支持分类" "$cat_out" "环境不支持"
    check_contains "含预期不测试分类" "$cat_out" "预期不测试"
    check_eq "categories.json 是合法 JSON" "$(printf '%s' "$cat_out" | jq -e 'type' 2>/dev/null)" '"array"'
    rm -rf "$dir"
}

test_generate_missing_cli() {
    printf '\n== allure_generate 缺 CLI 时报错 ==\n'
    local dir; dir="$(mktemp -d)"
    mkdir -p "$dir/allure-result"
    local rc=0
    PATH="/nonexistent-bin" allure_generate "$dir/allure-result" "$dir/allure-report" >/dev/null 2>&1 || rc=$?
    check_eq "缺 CLI 返回非 0" "$rc" "1"
    rm -rf "$dir"
}

main() {
    test_emit_results
    test_emit_broken
    test_environment_and_categories
    test_generate_missing_cli
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
