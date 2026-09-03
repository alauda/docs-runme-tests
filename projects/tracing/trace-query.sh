#!/usr/bin/env bash
# 调用链查询验证（tracing 项目专用）
#
# 背景：两篇安装文档的测试脚本原先只验证「装没装上」——集群插件就绪、Jaeger 与
# OpenTelemetry Collector 的 Deployment 滚动完成、Ingress 拿到地址。但 Jaeger 起来
# 不等于调用链真的可查：jaeger.yaml 里 jaeger_storage 的存储地址 / 索引前缀 / 凭据、
# jaeger_query 的 base_path，以及 rollover（ES）或 ISM（OpenSearch）建出来的读别名，
# 任何一处配错，Deployment 照样 Ready、CR 照样没有报错，只有真查一次 Query API 才暴露。
#
# 本文件提供 verify_jaeger_trace_query，按下面三步查 Jaeger 的 v3 Query API：
#   1. GET /api/v3/services                  —— 存储里的 service 列表（读通路是否打通）
#   2. GET /api/v3/operations?service=<服务> —— 目标服务的 operation 列表
#   3. GET /api/v3/trace-summaries?...       —— 断言时间窗口内至少查到 2 条调用链
# 门槛取 2 而不是 1：只查到 1 条时无法区分「链路真的通了」和「刚好撞上一条孤立记录」
# （比如上一轮验证自己留下的那条），2 条才说明存储在持续接收并可检索。
# 三步在同一轮里按序执行，任一步不通就整轮重试（而不是单独重试某一步），因为：
#   - span 从写入到可查询之间隔着 collector 的 batch 与存储的 refresh，第一轮查不到是常态；
#   - 每轮都重算时间窗口（now-lookback ~ now），窗口跟着重试往前滚，不会停在旧区间；
#   - 前两步本身会在 Jaeger 侧产生新的自身调用链，正好给下一轮当数据。
# SPM 不在本验证范围内：spanmetrics 走的是 monitoring 存储，与调用链查询无关。
#
# 访问路径：走 ACP 的 kube-apiserver Service 代理，不依赖 Jaeger Ingress 与 oauth2-proxy
# （后者是 OIDC 浏览器流程，脚本里换会话代价高），因此只需要一个 ACP token：
#   <平台地址>/kubernetes/<集群>/api/v1/namespaces/<Jaeger 命名空间>
#     /services/<Jaeger 实例名>-collector-extension:16686/proxy<JAEGER_BASEPATH>/api/v3/...
# 其中 `<实例名>-collector-extension` 是 OpenTelemetry Operator 为 jaeger_query 的 16686
# 端口建的 extension Service，`<JAEGER_BASEPATH>` 与 jaeger_query.base_path 取值一致。
# token 由引擎在 run.sh 里 ensure_acp_api_token 统一准备（未配置时用平台账号密码自动换取）。
#
# 环境变量：
#   TRACING_VERIFY_TRACE_QUERY          默认 false；置 true 才执行本验证
#   TRACING_VERIFY_TRACE_SERVICE        默认查询的服务名，默认 jaeger——Jaeger 自身的调用链，
#                                       SKIP_TELEMETRYGEN=true 跳过 telemetrygen 时也一定有。
#                                       调用时传第一个参数可覆盖它（如按服务名查 telemetrygen）
#   TRACING_VERIFY_TRACE_MIN_COUNT      判定通过所需的最少调用链条数，默认 2
#   TRACING_VERIFY_TRACE_RETRIES        整轮重试次数，默认 10
#   TRACING_VERIFY_TRACE_INTERVAL       重试间隔（秒），默认 15
#   TRACING_VERIFY_TRACE_LOOKBACK       查询时间窗口长度（秒），默认 300
#   TRACING_VERIFY_TRACE_SEARCH_DEPTH   query.searchDepth，默认 20
#   TRACING_VERIFY_TRACE_HTTP_TIMEOUT   单次 curl 超时（秒），默认 30
#   ACP_API_TOKEN                       引擎自动获取；显式配置时优先使用

# 防止重复 source
if [ -n "${__TRACING_TRACE_QUERY_SH_LOADED:-}" ]; then
    return 0
fi
__TRACING_TRACE_QUERY_SH_LOADED=1

__TRACING_TRACE_QUERY_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载日志函数（如果尚未加载）
if ! declare -f log_info > /dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$__TRACING_TRACE_QUERY_SH_DIR/../../framework/common.sh"
fi

# 查询状态（由 verify_jaeger_trace_query 填充，供内部函数使用）
#   __TRACING_QUERY_BASE       Jaeger v3 Query API 的前缀
#   __TRACING_QUERY_BODY_FILE  最近一次响应体的落盘路径（整次验证复用一个临时文件）
__TRACING_QUERY_BASE=""
__TRACING_QUERY_BODY_FILE=""

# ── 内部工具 ────────────────────────────────────────────────────────────────

# 统一的 curl 调用（测试环境多为自签证书，沿用框架其它处的 -k）
_tracing_trace_query_curl() {
    curl -k -sS --max-time "${TRACING_VERIFY_TRACE_HTTP_TIMEOUT:-30}" \
        -H "Authorization: Bearer ${ACP_API_TOKEN}" "$@"
}

# GET 一个 Jaeger Query API 路径
# 用法: code=$(_tracing_query_get <相对路径> [额外 curl 参数...])
# 说明: HTTP 状态码写 stdout，响应体写进 __TRACING_QUERY_BODY_FILE（失败时也写，
#       便于调用方打印诊断）；非 2xx 返回 1。URL 放在最后，`-G` 之类的参数照常生效。
#       状态码走 stdout 而不是全局变量：调用方是 `code=$(...)` 命令替换，子 shell 里
#       的赋值传不回来。
_tracing_query_get() {
    local path="$1"; shift
    local code
    code=$(_tracing_trace_query_curl -o "$__TRACING_QUERY_BODY_FILE" -w '%{http_code}' \
        "$@" "${__TRACING_QUERY_BASE}${path}" 2>/dev/null) || code="000"
    printf '%s' "$code"
    case "$code" in
        2*) return 0 ;;
        *)  return 1 ;;
    esac
}

# epoch 秒 → RFC3339（UTC，毫秒固定 .000），Jaeger v3 的 query.startTime* 要这个格式
# GNU date 用 `-d @<秒>`，BSD（macOS）date 用 `-r <秒>`，两种都试
_tracing_rfc3339() {
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null \
        || date -u -r "$1" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null
}

# 截断最近一次响应体，避免把整个 trace 列表打进日志
_tracing_query_brief() {
    head -c 300 "$__TRACING_QUERY_BODY_FILE" 2>/dev/null
}

# 一轮完整查询：services → operations → trace-summaries，任一步不通即返回 1
# 用法: _tracing_trace_query_round <服务名>
# 说明: jq 一律带 -s（slurp）。Jaeger v3 的部分接口按 grpc-gateway 流式返回多个顶层
#       JSON 对象，不 slurp 时 `length` 会打印多行，数值判断随即失效。
_tracing_trace_query_round() {
    local svc="$1"
    local lookback="${TRACING_VERIFY_TRACE_LOOKBACK:-300}"
    local depth="${TRACING_VERIFY_TRACE_SEARCH_DEPTH:-20}"
    local min_count="${TRACING_VERIFY_TRACE_MIN_COUNT:-2}"
    local code count now min_ts max_ts

    # 1. 服务列表：断言目标服务已出现，否则后面两步没有意义
    code=$(_tracing_query_get "/services") || {
        log_warn "查询 /api/v3/services 失败: HTTP ${code}，响应: $(_tracing_query_brief)"
        return 1
    }
    if ! jq -es --arg s "$svc" '([.[] | (.services // [])[]] | index($s)) != null' \
            >/dev/null 2>&1 < "$__TRACING_QUERY_BODY_FILE"; then
        log_warn "服务列表里暂未出现 ${svc}，本轮重试。当前列表: $(_tracing_query_brief)"
        return 1
    fi

    # 2. operation 列表
    code=$(_tracing_query_get "/operations" -G --data-urlencode "service=${svc}") || {
        log_warn "查询 /api/v3/operations 失败: HTTP ${code}，响应: $(_tracing_query_brief)"
        return 1
    }
    count=$(jq -rs '[.[] | (.operations // [])[]] | length' < "$__TRACING_QUERY_BODY_FILE" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    if [ "$count" -eq 0 ]; then
        log_warn "服务 ${svc} 的 operation 列表为空，本轮重试"
        return 1
    fi
    log_info "服务 ${svc} 的 operation 数: ${count}"

    # 3. 调用链查询：窗口每轮重算，断言至少查到 1 条
    now=$(date +%s)
    min_ts=$(_tracing_rfc3339 $(( now - lookback )))
    max_ts=$(_tracing_rfc3339 "$now")
    if [ -z "$min_ts" ] || [ -z "$max_ts" ]; then
        log_error "生成 RFC3339 时间窗口失败（date 既不支持 -d @<秒> 也不支持 -r <秒>）"
        return 1
    fi
    code=$(_tracing_query_get "/trace-summaries" -G \
        --data-urlencode "query.serviceName=${svc}" \
        --data-urlencode "query.startTimeMin=${min_ts}" \
        --data-urlencode "query.startTimeMax=${max_ts}" \
        --data-urlencode "query.searchDepth=${depth}") || {
        log_warn "查询 /api/v3/trace-summaries 失败: HTTP ${code}，响应: $(_tracing_query_brief)"
        return 1
    }
    count=$(jq -rs '[.[] | (.summaries // [])[]] | length' < "$__TRACING_QUERY_BODY_FILE" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    if [ "$count" -lt "$min_count" ]; then
        log_warn "窗口 ${min_ts} ~ ${max_ts} 内服务 ${svc} 的调用链只有 ${count} 条（需要 ${min_count} 条），本轮重试"
        return 1
    fi

    log_success "查询到 ${count} 条调用链（服务 ${svc}，窗口 ${min_ts} ~ ${max_ts}）"
    return 0
}

# ── 对外函数 ────────────────────────────────────────────────────────────────

# 验证调用链能被查询到（两篇安装文档测试脚本共用）
# 用法: verify_jaeger_trace_query [<服务名>]
# 说明: TRACING_VERIFY_TRACE_QUERY != true 时静默跳过（默认关闭）。
#       服务名不传时取 TRACING_VERIFY_TRACE_SERVICE，再缺省为 jaeger；跑过 telemetrygen
#       的场景由调用方再传一次 telemetrygen，对应文档 Verification 里「在 Service 下拉框
#       选 telemetrygen 再 Find Traces」那一步。
#       依赖文档代码块 get-platform-config / set-jaeger-defaults 已 export 的
#       PLATFORM_URL / CLUSTER_NAME / JAEGER_NS / JAEGER_INSTANCE_NAME / JAEGER_BASEPATH。
verify_jaeger_trace_query() {
    local svc="${1:-${TRACING_VERIFY_TRACE_SERVICE:-jaeger}}"
    if [ "${TRACING_VERIFY_TRACE_QUERY:-false}" != "true" ]; then
        log_info "TRACING_VERIFY_TRACE_QUERY != true，跳过调用链查询验证"
        return 0
    fi

    log_info "=========================================="
    log_info "开始调用链查询验证 (TRACING_VERIFY_TRACE_QUERY=true)，服务 ${svc}"
    log_info "=========================================="

    local tool missing=()
    for tool in curl jq; do
        command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "调用链查询验证缺少工具: ${missing[*]}"
        return 1
    fi

    # 平台地址优先用文档 get-platform-config 注入的 PLATFORM_URL（被测集群自己认的
    # 平台入口），未注入时回退到框架配置的 PLATFORM_ADDRESS
    local platform="${PLATFORM_URL:-${PLATFORM_ADDRESS:-}}"
    local cluster="${CLUSTER_NAME:-}"
    local ns="${JAEGER_NS:-}"
    local instance="${JAEGER_INSTANCE_NAME:-}"
    local basepath="${JAEGER_BASEPATH:-}"
    missing=()
    [ -n "$platform" ] || missing+=("PLATFORM_URL")
    [ -n "$cluster" ] || missing+=("CLUSTER_NAME")
    [ -n "$ns" ] || missing+=("JAEGER_NS")
    [ -n "$instance" ] || missing+=("JAEGER_INSTANCE_NAME")
    [ -n "$basepath" ] || missing+=("JAEGER_BASEPATH")
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "调用链查询验证缺少变量: ${missing[*]}"
        log_error "这些变量应由文档的 get-platform-config / set-jaeger-defaults 代码块 export"
        return 1
    fi

    # token 正常由引擎在 run.sh 里准备好；独立 source 本文件的场景兜底再取一次
    if [ -z "${ACP_API_TOKEN:-}" ]; then
        if declare -f ensure_acp_api_token > /dev/null 2>&1; then
            ensure_acp_api_token || return 1
        else
            log_error "调用链查询验证需要 ACP_API_TOKEN（由引擎自动获取，或显式配置）"
            return 1
        fi
    fi

    local retries="${TRACING_VERIFY_TRACE_RETRIES:-10}"
    local interval="${TRACING_VERIFY_TRACE_INTERVAL:-15}"

    __TRACING_QUERY_BASE="${platform%/}/kubernetes/${cluster}/api/v1/namespaces/${ns}/services/${instance}-collector-extension:16686/proxy${basepath}/api/v3"
    __TRACING_QUERY_BODY_FILE=$(mktemp) || return 1
    log_info "Jaeger Query API: ${__TRACING_QUERY_BASE}"
    log_info "查询服务: ${svc}，至少 ${TRACING_VERIFY_TRACE_MIN_COUNT:-2} 条，最多 ${retries} 轮、间隔 ${interval}s"

    local rc=1 attempt=1
    while [ "$attempt" -le "$retries" ]; do
        log_info "第 ${attempt}/${retries} 轮调用链查询..."
        if _tracing_trace_query_round "$svc"; then
            rc=0
            break
        fi
        if [ "$attempt" -lt "$retries" ]; then
            sleep "$interval"
        fi
        attempt=$((attempt + 1))
    done

    rm -f "$__TRACING_QUERY_BODY_FILE"
    __TRACING_QUERY_BODY_FILE=""
    __TRACING_QUERY_BASE=""

    if [ "$rc" -ne 0 ]; then
        log_error "调用链查询验证失败：${retries} 轮重试后服务 ${svc} 的调用链仍不足 ${TRACING_VERIFY_TRACE_MIN_COUNT:-2} 条"
        log_error "排查方向：Jaeger 的 jaeger_storage 是否指向本次部署的存储后端、"
        log_error "          rollover / ISM 是否建出读别名、collector 是否已把 span 写进存储"
        return 1
    fi

    log_success "=========================================="
    log_success "调用链查询验证通过（服务 ${svc}）"
    log_success "=========================================="
    return 0
}
