#!/usr/bin/env bash
# 调用链查询验证单元测试（伪造 curl，不依赖集群与网络）
# 用法: bash framework/tests/tracing_trace_query_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/projects/tracing/trace-query.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_contains() {
    if __cmp_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 伪造 curl：按 URL 末尾的路径决定回什么，响应体写进 -o 指定的文件、状态码打到 stdout，
# 同时把 URL 追加到 $STUB/calls 供断言调用次数与顺序。
# 各路径的响应由 STUB_<PATH>_CODE / STUB_<PATH>_BODY 三对环境变量控制。
make_curl_stub() {
    STUB="$(mktemp -d)"
    : > "$STUB/calls"
    cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        http*|https*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "$STUB_CALLS"
case "$url" in
    */services)         code="${STUB_SERVICES_CODE:-200}";  body="${STUB_SERVICES_BODY:-}" ;;
    */operations)       code="${STUB_OPERATIONS_CODE:-200}"; body="${STUB_OPERATIONS_BODY:-}" ;;
    */trace-summaries)  code="${STUB_SUMMARIES_CODE:-200}";  body="${STUB_SUMMARIES_BODY:-}" ;;
    *)                  code="404"; body='{"error":"unexpected path"}' ;;
esac
[ -n "$out" ] && printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
EOF
    chmod +x "$STUB/curl"
    export STUB_CALLS="$STUB/calls"
    PATH="$STUB:$PATH"
}

# 每个用例的公共入参：文档代码块本该 export 的那几个变量 + 一个假 token
setup_env() {
    export PLATFORM_URL="https://platform.test"
    export CLUSTER_NAME="business-1"
    export JAEGER_NS="jaeger-system"
    export JAEGER_INSTANCE_NAME="jaeger"
    export JAEGER_BASEPATH="/clusters/business-1/jaeger"
    export ACP_API_TOKEN="stub-token"
    export TRACING_VERIFY_TRACE_QUERY=true
    export TRACING_VERIFY_TRACE_RETRIES=2
    export TRACING_VERIFY_TRACE_INTERVAL=0
    export STUB_SERVICES_CODE=200
    export STUB_OPERATIONS_CODE=200
    export STUB_SUMMARIES_CODE=200
    export STUB_SERVICES_BODY='{"services":["jaeger","telemetrygen"]}'
    export STUB_OPERATIONS_BODY='{"operations":[{"name":"/api/v3/services","spanKind":"internal"}]}'
    export STUB_SUMMARIES_BODY='{"summaries":[{"traceId":"abc","rootServiceName":"jaeger","spanCount":2}]}'
}

teardown_env() {
    unset TRACING_VERIFY_TRACE_QUERY TRACING_VERIFY_TRACE_SERVICE \
        TRACING_VERIFY_TRACE_RETRIES TRACING_VERIFY_TRACE_INTERVAL \
        PLATFORM_URL CLUSTER_NAME JAEGER_NS JAEGER_INSTANCE_NAME JAEGER_BASEPATH \
        ACP_API_TOKEN
}

calls_count() { awk 'END {print NR}' "$STUB/calls" 2>/dev/null; }

test_disabled_by_default() {
    printf '\n== 默认关闭：不置 TRACING_VERIFY_TRACE_QUERY 时直接返回 0 且不发请求 ==\n'
    make_curl_stub; setup_env
    unset TRACING_VERIFY_TRACE_QUERY
    local out rc=0
    out=$(verify_jaeger_trace_query 2>&1) || rc=$?
    check_eq "返回 0" "$rc" "0"
    check_contains "说明已跳过" "$out" "TRACING_VERIFY_TRACE_QUERY != true"
    check_eq "没有发出任何请求" "$(calls_count)" "0"
    teardown_env; rm -rf "$STUB"
}

test_missing_vars() {
    printf '\n== 缺少文档注入的变量时报错点名 ==\n'
    make_curl_stub; setup_env
    unset JAEGER_BASEPATH
    local out rc=0
    out=$(verify_jaeger_trace_query 2>&1) || rc=$?
    check_eq "返回 1" "$rc" "1"
    check_contains "点名缺失变量" "$out" "JAEGER_BASEPATH"
    check_eq "没有发出任何请求" "$(calls_count)" "0"
    teardown_env; rm -rf "$STUB"
}

test_happy_path() {
    printf '\n== 一轮打通：三个接口依次调用并断言查到调用链 ==\n'
    make_curl_stub; setup_env
    local out rc=0
    out=$(verify_jaeger_trace_query 2>&1) || rc=$?
    check_eq "返回 0" "$rc" "0"
    check_eq "共发出 3 次请求" "$(calls_count)" "3"
    check_contains "第 1 次是 services" "$(sed -n '1p' "$STUB/calls")" "/api/v3/services"
    check_contains "第 2 次是 operations" "$(sed -n '2p' "$STUB/calls")" "/api/v3/operations"
    check_contains "第 3 次是 trace-summaries" "$(sed -n '3p' "$STUB/calls")" "/api/v3/trace-summaries"
    check_contains "断言查到 1 条" "$out" "查询到 1 条调用链"
    check_contains "URL 走 ACP Service 代理" "$(sed -n '1p' "$STUB/calls")" \
        "https://platform.test/kubernetes/business-1/api/v1/namespaces/jaeger-system/services/jaeger-collector-extension:16686/proxy/clusters/business-1/jaeger/api/v3"
    teardown_env; rm -rf "$STUB"
}

test_empty_summaries_retries_then_fails() {
    printf '\n== 查不到调用链：整轮重试到次数用尽后失败 ==\n'
    make_curl_stub; setup_env
    export STUB_SUMMARIES_BODY='{"summaries":[]}'
    local out rc=0
    out=$(verify_jaeger_trace_query 2>&1) || rc=$?
    check_eq "返回 1" "$rc" "1"
    check_eq "2 轮 × 3 个接口 = 6 次请求" "$(calls_count)" "6"
    check_contains "提示窗口内没查到" "$out" "内未查到服务 jaeger 的调用链"
    check_contains "给出排查方向" "$out" "rollover / ISM 是否建出读别名"
    teardown_env; rm -rf "$STUB"
}

test_service_absent_short_circuits() {
    printf '\n== 服务列表里没有目标服务：本轮不再查后两个接口 ==\n'
    make_curl_stub; setup_env
    export STUB_SERVICES_BODY='{"services":["telemetrygen"]}'
    local out rc=0
    out=$(verify_jaeger_trace_query 2>&1) || rc=$?
    check_eq "返回 1" "$rc" "1"
    check_eq "每轮只发 1 次请求，共 2 次" "$(calls_count)" "2"
    check_contains "提示服务尚未出现" "$out" "服务列表里暂未出现 jaeger"
    teardown_env; rm -rf "$STUB"
}

test_http_error_reported() {
    printf '\n== 接口返回非 2xx：带状态码报错并重试 ==\n'
    make_curl_stub; setup_env
    export STUB_SERVICES_CODE=403
    export STUB_SERVICES_BODY='{"kind":"Status","code":403}'
    local out rc=0
    out=$(verify_jaeger_trace_query 2>&1) || rc=$?
    check_eq "返回 1" "$rc" "1"
    check_contains "带上 HTTP 状态码" "$out" "HTTP 403"
    teardown_env; rm -rf "$STUB"
}

test_streamed_json_response() {
    printf '\n== 流式响应（多个顶层 JSON 对象）也能正确计数 ==\n'
    make_curl_stub; setup_env
    export STUB_SUMMARIES_BODY='{"summaries":[{"traceId":"a"}]}
{"summaries":[{"traceId":"b"},{"traceId":"c"}]}'
    local out rc=0
    out=$(verify_jaeger_trace_query 2>&1) || rc=$?
    check_eq "返回 0" "$rc" "0"
    check_contains "累计 3 条" "$out" "查询到 3 条调用链"
    teardown_env; rm -rf "$STUB"
}

test_custom_service_name() {
    printf '\n== TRACING_VERIFY_TRACE_SERVICE 可换查询用的服务名 ==\n'
    make_curl_stub; setup_env
    export TRACING_VERIFY_TRACE_SERVICE=telemetrygen
    local out rc=0
    out=$(verify_jaeger_trace_query 2>&1) || rc=$?
    check_eq "返回 0" "$rc" "0"
    check_contains "按新服务名查询" "$out" "查询服务: telemetrygen"
    teardown_env; rm -rf "$STUB"
}

test_rfc3339_format() {
    printf '\n== RFC3339 时间窗口格式（GNU / BSD date 都要能出结果）==\n'
    local ts
    ts=$(_tracing_rfc3339 1788420173)
    check_eq "定点时间戳格式正确" "$ts" "2026-09-03T07:22:53.000Z"
    if __cmp_regex "$(_tracing_rfc3339 "$(date +%s)")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.000Z$'; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] 当前时间也符合 RFC3339\n'
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] 当前时间不符合 RFC3339\n'
    fi
}

main() {
    test_disabled_by_default
    test_missing_vars
    test_happy_path
    test_empty_summaries_retries_then_fails
    test_service_absent_short_circuits
    test_http_error_reported
    test_streamed_json_response
    test_custom_service_name
    test_rfc3339_format
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
