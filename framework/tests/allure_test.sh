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
    check_contains "fullName 带项目前缀与 Case/phase" "$merged" '"fullName": "mesh/install-mesh [Case 3 test]"'
    check_contains "historyId 带 Case/phase/序号"       "$merged" '"historyId": "mesh/install-mesh|case3|test|1"'
    check_contains "毫秒时间戳"          "$merged" '"start": 100000'
    check_contains "suite 标签"          "$merged" '"value": "Case 3: 单网格"'
    check_contains "feature 标签"        "$merged" '"value": "mesh"'
    check_contains "tag 标签展开"        "$merged" '"value": "sidecar"'
    check_contains "case_id 标签"        "$merged" '"value": "ASM-DOC-002"'
    check_contains "skipped 用例"        "$merged" '"status": "skipped"'
    check_contains "skip 原因带 env 前缀" "$merged" '[env] 集群不能访问外网'
    rm -rf "$dir"
}

# 整 Case 被 case_skip（没有任何伴随 doctest）时，allure_emit_results 必须为它
# 补发一条占位结果，否则这个 Case 在 allure 报告里会直接消失（而不是显示为 skipped）
test_emit_results_orphan_case() {
    printf '\n== allure_emit_results 整 Case 无 doctest 时补占位 ==\n'
    local dir; dir="$(mktemp -d)"
    cat > "$dir/results.jsonl" <<'EOF'
{"type":"doctest","project":"mesh","file":"install-mesh","script":"runme-test_install-mesh.sh","case_id":"3","case_name":"单网格","phase":"test","status":"passed","skip_reason":"","fail_reason":"","start_ts":100,"end_ts":160,"duration_s":60}
{"type":"case","case_id":"3","case_name":"单网格","status":"passed","tags":"smoke","duration_s":60}
{"type":"case_skip","case_id":"6","case_name":"多集群自动升级","skip_reason":"[env] 非多集群环境"}
EOF
    allure_emit_results "$dir/results.jsonl" "$dir/allure-result"

    check_eq "产出 2 个结果文件（1 doctest + 1 占位）" \
        "$(find "$dir/allure-result" -name '*-result.json' | wc -l | tr -d ' ')" "2"

    local merged; merged="$(cat "$dir"/allure-result/*-result.json)"
    check_contains "占位用例状态 skipped"    "$merged" '"status": "skipped"'
    check_contains "占位原因带 env 前缀"      "$merged" '"message": "[env] 非多集群环境"'
    check_contains "占位 suite 标签"          "$merged" '"value": "Case 6: 多集群自动升级"'
    check_eq "有 doctest 的 Case 不重复补占位" \
        "$(printf '%s' "$merged" | grep -c '"fullName": "mesh/install-mesh \[Case 3 test\]"')" "1"
    check_eq "占位仅产出一次"                 \
        "$(printf '%s' "$merged" | grep -c '"fullName": "case/6"')" "1"
    rm -rf "$dir"
}

# 同一篇文档在一次 Run 里会跑多次（不同 Case / --no-cleanup 与 --cleanup-only /
# 同一 Case 内重复），historyId 必须各不相同——相同则被 allure 当成重试，
# 只保留最后一条，失败会被后面的 passed 覆盖掉（实测 mesh Case 5 的
# deploying-ambient-bookinfo 主跑 failed、cleanup-only passed，报告里 failed=0）
test_emit_results_duplicate_docs() {
    printf '\n== allure_emit_results 同文档多次执行不互相覆盖 ==\n'
    local dir; dir="$(mktemp -d)"
    cat > "$dir/results.jsonl" <<'EOF'
{"type":"doctest","project":"mesh","file":"deploying-ambient-bookinfo","script":"a.sh","case_id":"5","case_name":"Ambient","phase":"test","status":"failed","skip_reason":"","fail_reason":"ztunnel 未纳管","start_ts":100,"end_ts":135,"duration_s":35}
{"type":"doctest","project":"mesh","file":"deploying-ambient-bookinfo","script":"a.sh","case_id":"5","case_name":"Ambient","phase":"cleanup-only","status":"passed","skip_reason":"","fail_reason":"","start_ts":200,"end_ts":210,"duration_s":10}
{"type":"doctest","project":"mesh","file":"kiali","script":"k.sh","case_id":"3","case_name":"单网格","phase":"test","status":"passed","skip_reason":"","fail_reason":"","start_ts":300,"end_ts":310,"duration_s":10}
{"type":"doctest","project":"mesh","file":"kiali","script":"k.sh","case_id":"5","case_name":"Ambient","phase":"test","status":"failed","skip_reason":"","fail_reason":"boom","start_ts":320,"end_ts":330,"duration_s":10}
{"type":"doctest","project":"mesh","file":"install-mesh","script":"i.sh","case_id":"4","case_name":"HA","phase":"test","status":"passed","skip_reason":"","fail_reason":"","start_ts":400,"end_ts":410,"duration_s":10}
{"type":"doctest","project":"mesh","file":"install-mesh","script":"i.sh","case_id":"4","case_name":"HA","phase":"test","status":"failed","skip_reason":"","fail_reason":"第二次挂了","start_ts":420,"end_ts":430,"duration_s":10}
{"type":"case","case_id":"3","case_name":"单网格","status":"passed","tags":"smoke","duration_s":10}
{"type":"case","case_id":"4","case_name":"HA","status":"failed","tags":"ha","duration_s":30}
{"type":"case","case_id":"5","case_name":"Ambient","status":"failed","tags":"smoke ambient","duration_s":110}
EOF
    ALLURE_CASE_IDS_FILE="$dir/nonexistent.tsv" allure_emit_results "$dir/results.jsonl" "$dir/allure-result"

    local total uniq failed
    total="$(find "$dir/allure-result" -name '*-result.json' | wc -l | tr -d ' ')"
    uniq="$(jq -r '.historyId' "$dir"/allure-result/*-result.json | sort -u | wc -l | tr -d ' ')"
    failed="$(jq -r '.status' "$dir"/allure-result/*-result.json | grep -c '^failed$' | tr -d ' ')"
    check_eq "6 条 doctest 生成 6 个用例文件" "$total" "6"
    check_eq "historyId 两两不同"             "$uniq"  "6"
    check_eq "3 条 failed 都保留下来"          "$failed" "3"

    local merged; merged="$(cat "$dir"/allure-result/*-result.json)"
    check_contains "cleanup-only 用例名带后缀" "$merged" '"name": "deploying-ambient-bookinfo (cleanup)"'
    check_contains "同 Case 同 phase 重复加序号" "$merged" '"name": "install-mesh #2"'
    check_contains "主跑用例名保持纯文档名"     "$merged" '"name": "kiali"'
    rm -rf "$dir"
}

# 执行日志挂为附件：去颜色码、屏蔽密码；失败用例的 [ERROR] 行与日志尾部进 trace，
# 但 statusDetails.message 必须保持原样（dailybuild 巡检用它当失败签名去重建单）
test_emit_results_log_attachment() {
    printf '\n== allure_emit_results 执行日志附件 ==\n'
    local dir; dir="$(mktemp -d)"
    printf '\033[0;34m[INFO]\033[0m 步骤 3.1\n\033[0;31m[ERROR]\033[0m East 端流量验证失败 pw=S3cret-pw\r\n最后一行\n' > "$dir/fail.log"
    printf 'all good\n' > "$dir/pass.log"
    printf '\033[0;31m[ERROR]\033[0m 拉取 kubeconfig 失败\n' > "$dir/case1.log"
    cat > "$dir/results.jsonl" <<EOF
{"type":"doctest","project":"mesh","file":"install-mpmn","script":"s.sh","case_id":"6","case_name":"多集群","phase":"test","status":"failed","skip_reason":"","fail_reason":"测试函数 test_x 返回非 0","start_ts":100,"end_ts":190,"duration_s":90,"log_file":"$dir/fail.log"}
{"type":"doctest","project":"mesh","file":"configuration-overview","script":"c.sh","case_id":"6","case_name":"多集群","phase":"test","status":"passed","skip_reason":"","fail_reason":"","start_ts":90,"end_ts":100,"duration_s":10,"log_file":"$dir/pass.log"}
{"type":"doctest","project":"mesh","file":"nolog","script":"n.sh","case_id":"6","case_name":"多集群","phase":"test","status":"passed","skip_reason":"","fail_reason":"","start_ts":90,"end_ts":100,"duration_s":10,"log_file":"$dir/missing.log"}
{"type":"case","case_id":"6","case_name":"多集群","status":"failed","tags":"multicluster","duration_s":100,"log_file":"$dir/case6.log"}
{"type":"case","case_id":"1","case_name":"环境初始化","status":"failed","tags":"always","duration_s":5,"log_file":"$dir/case1.log"}
EOF
    PLATFORM_PASSWORD="S3cret-pw" allure_emit_results "$dir/results.jsonl" "$dir/allure-result"

    local r fail pass nolog case1 src
    r="$dir/allure-result"
    fail="$(jq -s '.[] | select(.name == "install-mpmn")' "$r"/*-result.json)"
    pass="$(jq -s '.[] | select(.name == "configuration-overview")' "$r"/*-result.json)"
    nolog="$(jq -s '.[] | select(.name == "nolog")' "$r"/*-result.json)"
    case1="$(jq -s '.[] | select(.name == "Case 1: 环境初始化")' "$r"/*-result.json)"

    check_eq "失败用例 message 保持原样" "$(printf '%s' "$fail" | jq -r '.statusDetails.message')" "测试函数 test_x 返回非 0"
    check_eq "附件名" "$(printf '%s' "$fail" | jq -r '.attachments[0].name')" "执行日志"
    check_eq "附件类型" "$(printf '%s' "$fail" | jq -r '.attachments[0].type')" "text/plain"
    src="$(printf '%s' "$fail" | jq -r '.attachments[0].source')"
    check_eq "附件文件落在结果目录" "$(test -f "$r/$src" && echo yes)" "yes"
    check_eq "附件去掉颜色码" "$(grep -c "$(printf '\033')" "$r/$src")" "0"
    check_eq "附件去掉 \\r" "$(grep -c "$(printf '\r')" "$r/$src")" "0"
    check_contains "附件屏蔽密码" "$(cat "$r/$src")" "pw=******"
    check_eq "附件不含明文密码" "$(grep -c 'S3cret-pw' "$r/$src")" "0"
    check_contains "trace 含 ERROR 行" "$(printf '%s' "$fail" | jq -r '.statusDetails.trace')" "[ERROR] East 端流量验证失败"
    check_contains "trace 含日志末尾" "$(printf '%s' "$fail" | jq -r '.statusDetails.trace')" "最后一行"

    check_eq "通过用例也挂附件" "$(printf '%s' "$pass" | jq -r '.attachments | length')" "1"
    check_eq "通过用例不写 trace" "$(printf '%s' "$pass" | jq -r '.statusDetails | has("trace")')" "false"
    check_eq "日志文件不存在时不挂附件" "$(printf '%s' "$nolog" | jq -r 'has("attachments")')" "false"

    check_eq "无 doctest 的 Case 挂 Case 日志" "$(printf '%s' "$case1" | jq -r '.attachments[0].name')" "Case 执行日志"
    check_contains "无 doctest 的失败 Case 写 trace" "$(printf '%s' "$case1" | jq -r '.statusDetails.trace')" "拉取 kubeconfig 失败"
    check_eq "有 doctest 的 Case 不单独出结果" "$(jq -s '[.[] | select(.name == "Case 6: 多集群")] | length' "$r"/*-result.json)" "0"
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
    test_emit_results_orphan_case
    test_emit_results_duplicate_docs
    test_emit_results_log_attachment
    test_emit_broken
    test_environment_and_categories
    test_generate_missing_cli
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
