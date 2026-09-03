#!/usr/bin/env bash
# Kiali 监控功能验证（mesh 项目专用）
#
# 背景：runme-test_kiali.sh 原先只验证「装没装上」——CSV Succeeded、Kiali CR Successful、
# Deployment 就绪。但 kiali.yaml 里最容易配错的恰恰是 external_services：
# prometheus 的 url / basic-auth Secret / thanos_proxy，以及 tracing 的
# internal_url / use_grpc。这些配错时 Kiali 照样能起来、CR 照样 Successful，
# 只有真让 Kiali 去查一次监控后端才会暴露。
#
# 本文件提供 verify_kiali_monitoring，做两件事：
#   1. GET /api/istio/status —— Kiali 主动探活它依赖的外部服务。istiod / prometheus
#      必须 Healthy；已对接调用链平台时 tracing 也必须 Healthy。
#      该接口由 Kiali 后台周期性刷新，配置刚下发时可能仍是上一轮结果，故需重试。
#   2. GET /api/namespaces/graph —— 断言 Kiali 真能从监控后端算出流量速率，
#      而不只是「连得上」。指标从产生到可被查询要经过一次抓取周期（60s 量级），
#      故每轮先补一批 bookinfo 请求再查图，直到出现速率大于 0 的边。
#
# 两种数据面模式都支持，判定条件统一为「存在速率大于 0 的边」：
#   - sidecar 模式：Envoy 上报 istio_requests_total，图上是 http 边；
#   - ambient  模式：kiali 用例跑在 waypoint 部署之前，只有 ztunnel 的 L4 指标，
#     图上是 tcp 边（编排见 run-mesh-all.sh Case 5：deploying-ambient-bookinfo →
#     kiali → ambient-l7-features，waypoint 在 kiali 之后才创建）。
#
# 为什么不能只判断「series 存不存在」：ztunnel / Envoy 会把已删除工作负载的 counter
# 一直留在内存里被继续抓取，`count(istio_tcp_connections_opened_total)` 永远非零、
# 时间戳永远是「现在」（4.3.1 环境实测：bookinfo 早已删除，32 条 series 仍在）。
# 只有 rate() 才能区分「真有流量」和「残留计数器」，所以这里断言的是速率。
#
# 认证：Kiali 是 openid 策略，不接受 Bearer token，必须拿到会话 cookie。
# 流程与 framework/acp-auth.sh 同源（dex SPA 接口 + RSA 加密密码），区别在于
# Kiali 发起的是带 PKCE 的 authorization code 流程，因此必须：
#   openid_redirect（拿到 nonce/pkce cookie 与 authorize 参数）
#     → dex 换 req → 提交账号密码拿 redirect_url → 用同一 cookie jar 回调 Kiali。
# 全程只用 curl / jq / openssl，不依赖 python（测试镜像里没有 python）。
#
# 环境变量:
#   KIALI_VERIFY_MONITORING       默认 false；置 true 才执行本验证
#   KIALI_VERIFY_NAMESPACE        流量图断言使用的命名空间，默认 bookinfo
#   KIALI_VERIFY_STATUS_RETRIES   /api/istio/status 重试轮次，默认 10
#   KIALI_VERIFY_STATUS_INTERVAL  上述重试间隔（秒），默认 15
#   KIALI_VERIFY_GRAPH_RETRIES    流量图重试轮次，默认 15
#   KIALI_VERIFY_GRAPH_INTERVAL   上述重试间隔（秒），默认 20
#   KIALI_VERIFY_GRAPH_DURATION   流量图速率窗口，默认 300s
#   PLATFORM_USERNAME / PLATFORM_PASSWORD  经 dex 换取 Kiali 会话所需的平台账号

# 防止重复 source
if [ -n "${__KIALI_MONITORING_SH_LOADED:-}" ]; then
    return 0
fi
__KIALI_MONITORING_SH_LOADED=1

__KIALI_MONITORING_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载日志与 retry_command（如果尚未加载）
if ! declare -f retry_command > /dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$__KIALI_MONITORING_SH_DIR/../../framework/common.sh"
fi

# 会话状态（由 _kiali_login 填充，供 _kiali_api_get 使用）
__KIALI_JAR=""
__KIALI_URL=""

# ── 内部工具 ────────────────────────────────────────────────────────────────

# 统一的 curl 调用（测试环境多为自签证书，沿用框架其它处的 -k）
_kiali_curl() {
    curl -k -sS --max-time "${KIALI_VERIFY_HTTP_TIMEOUT:-30}" "$@"
}

# 带会话 cookie 调用 Kiali API
# 用法: _kiali_api_get <path> [额外 curl 参数...]
# 说明: 响应体写 stdout（失败时也写，便于调用方打印诊断）；HTTP 非 2xx 返回 1
_kiali_api_get() {
    local path="$1"; shift
    local body_file code rc
    body_file=$(mktemp) || return 1
    code=$(_kiali_curl -b "$__KIALI_JAR" -c "$__KIALI_JAR" \
        -o "$body_file" -w '%{http_code}' "$@" "${__KIALI_URL}${path}" 2>/dev/null) || code="000"
    cat "$body_file"
    rm -f "$body_file"
    case "$code" in
        2*) rc=0 ;;
        *)  rc=1 ;;
    esac
    return $rc
}

# cookie jar 里是否已有 Kiali 会话 cookie
# 说明: 会话 cookie 名形如 kiali-token-<Kiali 内部集群名>（常见为 kiali-token-Kubernetes，
#       与 ACP 集群名无关，不能按 CLUSTER_NAME 拼）。登录过程中的
#       kiali-token-nonce-* / kiali-token-pkce-verifier-* 是临时 cookie，需排除。
_kiali_session_cookie_present() {
    grep -o 'kiali-token-[^[:space:]]*' "$__KIALI_JAR" 2>/dev/null \
        | grep -qvE '^kiali-token-(nonce|pkce-verifier)-'
}

# 经 dex 登录 Kiali，会话写入 $__KIALI_JAR
# 用法: _kiali_login
# 依赖: __KIALI_URL / PLATFORM_ADDRESS / PLATFORM_USERNAME / PLATFORM_PASSWORD
_kiali_login() {
    local addr="${PLATFORM_ADDRESS%/}"
    local tmp_dir authorize_url query req pubkey_resp ts encrypted
    local connector login_body login_resp redirect_url

    tmp_dir=$(mktemp -d) || return 1
    chmod 700 "$tmp_dir" 2>/dev/null || true
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" RETURN

    : > "$__KIALI_JAR"

    # 1. 让 Kiali 发起 OIDC 跳转：拿到 dex authorize 的完整参数（含 nonce / PKCE challenge），
    #    同时 Kiali 会把 nonce 与 pkce verifier 写进 cookie jar，最后回调时要用同一份。
    authorize_url=$(_kiali_curl -b "$__KIALI_JAR" -c "$__KIALI_JAR" \
        -o /dev/null -w '%{redirect_url}' "${__KIALI_URL}/api/auth/openid_redirect" 2>/dev/null) || authorize_url=""
    case "$authorize_url" in
        *\?*) query="${authorize_url#*\?}" ;;
        *)
            log_error "Kiali /api/auth/openid_redirect 未返回 OIDC 跳转地址（auth.strategy 是否为 openid？）"
            log_error "返回: ${authorize_url:-<空>}"
            return 1
            ;;
    esac

    # 2. 用 dex 的 SPA 接口换登录请求 ID
    #    （/dex/auth 与 /console-dex/auth 都被路由到前端页面，拿不到表单，只能走该接口）
    req=$(_kiali_curl -b "$__KIALI_JAR" -c "$__KIALI_JAR" \
        "${addr}/dex/api/v1/authorize?${query}" 2>/dev/null | jq -r '.req // empty' 2>/dev/null) || req=""
    if [ -z "$req" ]; then
        log_error "未能从 dex 授权响应中取得登录请求 ID (req)"
        return 1
    fi

    # 3. 取密码加密公钥（含服务端时间戳），RSA(PKCS#1 v1.5) 加密 {"ts":..,"password":..}
    pubkey_resp=$(_kiali_curl "${addr}/dex/pubkey" 2>/dev/null) || pubkey_resp=""
    ts=$(jq -r '.ts // empty' <<< "$pubkey_resp" 2>/dev/null || echo "")
    jq -r '.pubkey // empty' <<< "$pubkey_resp" > "$tmp_dir/pubkey.pem" 2>/dev/null
    if [ -z "$ts" ] || [ ! -s "$tmp_dir/pubkey.pem" ]; then
        log_error "dex 密码公钥响应格式异常: $(head -c 300 <<< "$pubkey_resp")"
        return 1
    fi
    # 密码经 $ENV 传给 jq，避免出现在进程命令行参数中；base64 用 openssl 以兼容 macOS
    encrypted=$(KIALI_TMP_TS="$ts" KIALI_TMP_PASSWORD="$PLATFORM_PASSWORD" \
        jq -cn '{ts: $ENV.KIALI_TMP_TS, password: $ENV.KIALI_TMP_PASSWORD}' \
        | tr -d '\n' \
        | openssl pkeyutl -encrypt -pubin -inkey "$tmp_dir/pubkey.pem" -pkeyopt rsa_padding_mode:pkcs1 2>/dev/null \
        | openssl base64 -A) || encrypted=""
    if [ -z "$encrypted" ]; then
        log_error "加密平台密码失败（openssl RSA 加密）"
        return 1
    fi

    # 4. 提交账号密码，拿回带 authorization code 的回调地址
    connector="${ACP_AUTH_DEX_CONNECTOR:-}"
    if [ -z "$connector" ]; then
        connector=$(_kiali_curl "${addr}/dex/api/v1/connectors" 2>/dev/null \
            | jq -r '.[0].conn_id // "local"' 2>/dev/null || echo "local")
        [ -n "$connector" ] || connector="local"
    fi
    login_body=$(KIALI_TMP_ACCOUNT="$PLATFORM_USERNAME" KIALI_TMP_ENC="$encrypted" \
        jq -cn '{account: $ENV.KIALI_TMP_ACCOUNT, password: $ENV.KIALI_TMP_ENC}')
    login_resp=$(_kiali_curl -b "$__KIALI_JAR" -c "$__KIALI_JAR" \
        -X POST -H 'Content-Type: application/json' --data-binary "$login_body" \
        "${addr}/dex/api/v1/authorize/${connector}?req=${req}" 2>/dev/null) || login_resp=""
    # jq -r 会把 JSON 里的 \u0026 还原成 &，redirect_url 可直接当 URL 用
    redirect_url=$(jq -r '.redirect_url // empty' <<< "$login_resp" 2>/dev/null || echo "")
    if [ -z "$redirect_url" ]; then
        log_error "平台登录失败: $(head -c 300 <<< "$login_resp")"
        return 1
    fi

    # 5. 用同一 cookie jar 回调 Kiali：Kiali 拿 code 换 id_token 并写入会话 cookie
    _kiali_curl -b "$__KIALI_JAR" -c "$__KIALI_JAR" -o /dev/null "$redirect_url" 2>/dev/null || true
    if ! _kiali_session_cookie_present; then
        log_error "Kiali 回调未写入会话 cookie，登录失败"
        return 1
    fi
    return 0
}

# 校验 Kiali 对外部服务的探活结果
# 用法: _kiali_check_istio_status <expect_tracing:true|false>
_kiali_check_istio_status() {
    local expect_tracing="$1"
    local body summary bad tracing_status

    body=$(_kiali_api_get "/api/istio/status") || {
        log_warn "调用 /api/istio/status 失败: $(head -c 200 <<< "$body")"
        return 1
    }
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$body"; then
        log_warn "/api/istio/status 响应格式异常: $(head -c 200 <<< "$body")"
        return 1
    fi

    summary=$(jq -r '[.[] | "\(.name)=\(.status)"] | join(" ")' <<< "$body")
    log_info "Kiali 外部服务探活: $summary"

    # istiod 与 prometheus 是 isCore 组件，任一不健康即视为监控链路不通
    bad=$(jq -r '[.[] | select((.name == "istiod" or .name == "prometheus") and .status != "Healthy")
                 | "\(.name):\(.status)"] | join(", ")' <<< "$body")
    if [ -n "$bad" ]; then
        log_warn "Kiali 核心依赖不健康: $bad"
        return 1
    fi
    if ! jq -e '[.[] | select(.name == "prometheus")] | length > 0' >/dev/null 2>&1 <<< "$body"; then
        log_warn "/api/istio/status 未返回 prometheus 组件"
        return 1
    fi

    # 已对接调用链平台时，tracing 必须 Healthy——Unreachable 说明
    # external_services.tracing 的 internal_url / use_grpc 配错或 jaeger 不可达
    if [ "$expect_tracing" = "true" ]; then
        tracing_status=$(jq -r '[.[] | select(.name == "tracing") | .status] | first // "Missing"' <<< "$body")
        if [ "$tracing_status" != "Healthy" ]; then
            log_warn "已对接调用链平台，但 Kiali 探活 tracing = $tracing_status"
            return 1
        fi
    fi
    return 0
}

# 在 bookinfo 的 ratings pod 中同步打一批 productpage 请求
# 用法: _kiali_gen_bookinfo_traffic <namespace> [请求数]
# 说明: 与 maybe_gen_bookinfo_traffic 的后台常驻循环不同，这里是有界的同步请求——
#       流量图断言只需要「最近一个速率窗口内有流量」，不需要留下后台进程。
_kiali_gen_bookinfo_traffic() {
    local ns="$1" count="${2:-20}" pod
    pod=$(kubectl get pod -l app=ratings -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || pod=""
    if [ -z "$pod" ]; then
        return 1
    fi
    kubectl exec "$pod" -c ratings -n "$ns" -- \
        bash -c "for i in \$(seq 1 ${count}); do curl -sS -o /dev/null productpage:9080/productpage || true; done" \
        > /dev/null 2>&1 || return 1
    return 0
}

# 断言 Kiali 能从监控后端算出该命名空间的流量速率
# 用法: _kiali_check_graph_traffic <namespace>
_kiali_check_graph_traffic() {
    local ns="$1" body live

    body=$(_kiali_api_get "/api/namespaces/graph" -G \
        --data-urlencode "namespaces=${ns}" \
        --data-urlencode "duration=${KIALI_VERIFY_GRAPH_DURATION:-300s}" \
        --data-urlencode "graphType=versionedApp" \
        --data-urlencode "injectServiceNodes=true" \
        --data-urlencode "rateHttp=requests" \
        --data-urlencode "rateGrpc=requests" \
        --data-urlencode "rateTcp=sent") || {
        log_warn "调用 /api/namespaces/graph 失败: $(head -c 200 <<< "$body")"
        return 1
    }

    # 只认协议自身的速率键（http / grpc / tcp）：httpPercentReq 之类的百分比字段
    # 在零流量时也可能非零，拿来判定会误判
    live=$(jq -r '[ (.elements.edges // [])[] | .data.traffic // empty
                    | select(.protocol != null)
                    | select(((.rates[.protocol]) // "0") | tonumber > 0) ] | length' <<< "$body" 2>/dev/null) || live=""
    case "$live" in
        ''|*[!0-9]*)
            log_warn "解析 Kiali 流量图失败: $(head -c 200 <<< "$body")"
            return 1
            ;;
    esac
    if [ "$live" -eq 0 ]; then
        log_warn "Kiali 流量图中暂无速率大于 0 的边（命名空间 ${ns}，窗口 ${KIALI_VERIFY_GRAPH_DURATION:-300s}）"
        return 1
    fi

    log_success "Kiali 已从监控后端算出 $live 条有流量的边:"
    jq -r '
        ((.elements.nodes // []) | map({key: .data.id,
                                        value: (.data.workload // .data.service // .data.app // .data.id)})
         | from_entries) as $names
        | (.elements.edges // [])[]
        | .data as $d | ($d.traffic // {}) as $t
        | select(($t.protocol != null) and (((($t.rates[$t.protocol]) // "0") | tonumber) > 0))
        | "    \($names[$d.source] // $d.source) -> \($names[$d.target] // $d.target)  \($t.protocol)=\($t.rates[$t.protocol])"
    ' <<< "$body" 2>/dev/null || true
    return 0
}

# ── 对外函数 ────────────────────────────────────────────────────────────────

# verify_kiali_monitoring 的主体（登录 → 探活 → 流量图），会话由调用方准备与清理
# 用法: _kiali_verify_monitoring_impl <tracing_integrated:true|false>
_kiali_verify_monitoring_impl() {
    local tracing_integrated="$1"
    local ns="${KIALI_VERIFY_NAMESPACE:-bookinfo}"
    local status_retries="${KIALI_VERIFY_STATUS_RETRIES:-10}"
    local status_interval="${KIALI_VERIFY_STATUS_INTERVAL:-15}"
    local graph_retries="${KIALI_VERIFY_GRAPH_RETRIES:-15}"
    local graph_interval="${KIALI_VERIFY_GRAPH_INTERVAL:-20}"

    # 步骤 1: 登录 Kiali（openid 策略只认会话 cookie）
    log_info "步骤 1/3: 登录 Kiali (${__KIALI_URL})"
    if ! retry_command "_kiali_login" 3 10; then
        log_error "Kiali 登录失败，无法验证监控功能"
        return 1
    fi
    log_success "Kiali 登录成功（账号 ${PLATFORM_USERNAME}）"

    # 步骤 2: 外部服务探活
    # Kiali 对外部服务的探活结果由后台周期性刷新，配置刚下发（或 jaeger 刚就绪）时
    # 拿到的可能仍是上一轮结果，因此这里必须重试而不是一次定生死。
    log_info "步骤 2/3: 校验 Kiali 外部服务探活 (/api/istio/status)"
    if [ "$tracing_integrated" = "true" ]; then
        log_info "已对接调用链平台，tracing 必须为 Healthy"
    else
        log_info "未对接调用链平台，跳过 tracing 断言"
    fi
    if ! retry_command "_kiali_check_istio_status '$tracing_integrated'" "$status_retries" "$status_interval"; then
        log_error "Kiali 外部服务探活未通过（检查 kiali.yaml 的 external_services 配置）"
        return 1
    fi
    log_success "Kiali 外部服务探活通过"

    # 步骤 3: 流量图断言（sidecar 模式为 http 边，ambient 模式为 ztunnel 的 tcp 边）
    log_info "步骤 3/3: 校验 Kiali 能算出 ${ns} 命名空间的流量速率"
    if ! kubectl get namespace "$ns" > /dev/null 2>&1; then
        log_error "命名空间 ${ns} 不存在，无法验证流量图；请先执行 bookinfo 部署用例，或用 KIALI_VERIFY_NAMESPACE 指定其它命名空间"
        return 1
    fi
    if ! kubectl get pod -l app=ratings -n "$ns" -o name 2>/dev/null | grep -q .; then
        log_error "命名空间 ${ns} 中没有 app=ratings 的 Pod，无法生成 bookinfo 流量"
        return 1
    fi

    local attempt
    for attempt in $(seq 1 "$graph_retries"); do
        # 每轮先补一批请求：指标要经过一次抓取周期才可查，且速率窗口是滑动的
        _kiali_gen_bookinfo_traffic "$ns" 20 \
            || log_warn "生成 bookinfo 流量失败（第 ${attempt}/${graph_retries} 轮），继续查询流量图"
        if _kiali_check_graph_traffic "$ns"; then
            return 0
        fi
        if [ "$attempt" -lt "$graph_retries" ]; then
            log_warn "等待监控数据 (${attempt}/${graph_retries})，${graph_interval}s 后重试..."
            sleep "$graph_interval"
        fi
    done

    log_error "在 $(( graph_retries * graph_interval ))s 内 Kiali 仍查不到 ${ns} 的流量速率"
    log_error "排查方向: 监控是否已与网格对接（istio-proxies-monitor / istiod-monitor）、"
    log_error "          kiali.yaml 的 external_services.prometheus.url 与 thanos_proxy 是否正确"
    return 1
}

# 验证 Kiali 监控功能是否真正可用
# 用法: verify_kiali_monitoring <platform_url> <cluster_name> <tracing_integrated:true|false>
# 说明: KIALI_VERIFY_MONITORING != true 时静默跳过（默认关闭）
verify_kiali_monitoring() {
    local platform_url="$1"
    local cluster_name="$2"
    local tracing_integrated="${3:-false}"

    if [ "${KIALI_VERIFY_MONITORING:-false}" != "true" ]; then
        log_info "KIALI_VERIFY_MONITORING != true，跳过 Kiali 监控功能验证"
        return 0
    fi

    log_info "=========================================="
    log_info "开始 Kiali 监控功能验证 (KIALI_VERIFY_MONITORING=true)"
    log_info "=========================================="

    local tool missing=()
    for tool in curl jq openssl kubectl; do
        command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Kiali 监控功能验证缺少工具: ${missing[*]}"
        return 1
    fi
    if [ -z "${PLATFORM_ADDRESS:-}" ] || [ -z "${PLATFORM_USERNAME:-}" ] || [ -z "${PLATFORM_PASSWORD:-}" ]; then
        log_error "Kiali 监控功能验证需要 PLATFORM_ADDRESS / PLATFORM_USERNAME / PLATFORM_PASSWORD"
        return 1
    fi
    if [ -z "$platform_url" ] || [ -z "$cluster_name" ]; then
        log_error "verify_kiali_monitoring 需要 platform_url 与 cluster_name 参数"
        return 1
    fi

    __KIALI_URL="${platform_url%/}/clusters/${cluster_name}/kiali"
    __KIALI_JAR=$(mktemp) || return 1
    chmod 600 "$__KIALI_JAR" 2>/dev/null || true

    # 不用 trap RETURN 清理：_kiali_login 内部也有 RETURN trap，嵌套时哪个先触发
    # 依赖 functrace 设置，行为不直观；这里显式收尾，语义确定。
    local rc=0
    _kiali_verify_monitoring_impl "$tracing_integrated" || rc=$?
    rm -f "$__KIALI_JAR"
    __KIALI_JAR=""

    if [ "$rc" -eq 0 ]; then
        log_success "=========================================="
        log_success "Kiali 监控功能验证通过"
        log_success "=========================================="
    fi
    return "$rc"
}
