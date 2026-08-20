#!/usr/bin/env bash
# ACP 平台认证工具函数库
#
# 用「平台地址 + 用户名 + 密码」自动换取 ACP API Token，免去手工在 UI 个人信息页
# 生成 ACP_API_TOKEN 并配置到环境变量。
#
# 原理（与 ACP 登录页 /console-dex 的前端行为一致）:
#   1. GET  /dex/api/v1/authorize?client_id=...&response_type=id_token...  -> 登录请求 ID (req)
#   2. GET  /dex/pubkey                                                    -> RSA 公钥与时间戳 ts
#   3. RSA(PKCS#1 v1.5) 加密 {"ts":..,"password":..} 后 base64
#   4. POST /dex/api/v1/authorize/<connector>?req=<req>  {account,password} -> redirect_url
#   5. 从 redirect_url 的 fragment 中取出 id_token（dex 签发，默认有效期 24h）
# 该流程为 OIDC implicit 流程，不需要 dex client secret，只需平台账号密码。
#
# 依赖环境变量:
#   - PLATFORM_ADDRESS         必填，ACP 平台地址
#   - PLATFORM_USERNAME        自动获取 token 时必填
#   - PLATFORM_PASSWORD        自动获取 token 时必填
#   - ACP_API_TOKEN            可选，显式提供则优先使用（校验不通过时回退到自动获取）
#   - ACP_AUTH_CACHE_DIR       可选，token 缓存目录（默认 <框架根>/.acp-auth）
#   - ACP_AUTH_DEX_CLIENT_ID   可选，dex client id（默认 alauda-auth）
#   - ACP_AUTH_DEX_CONNECTOR   可选，dex connector（默认自动取平台第一个连接器，通常 local）
#   - ACP_AUTH_NO_CACHE        可选，设为 true 时不读写 token 缓存
#
# 暴露函数:
#   - ensure_acp_api_token                 确保 ACP_API_TOKEN 可用（校验 → 缓存 → 登录），并 export
#   - acp_login_api_token                  走一次完整登录流程，token 输出到 stdout
#   - acp_api_token_valid <token>          校验 token 能否访问平台 API

# 防止重复 source
if [ -n "${__ACP_AUTH_SH_LOADED:-}" ]; then
    return 0
fi
__ACP_AUTH_SH_LOADED=1

__ACP_AUTH_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载日志函数（如果尚未加载）
if ! declare -f log_info > /dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$__ACP_AUTH_SH_DIR/common.sh"
fi

# token 缓存目录（独立于 .kubeconfig/，后者会在 setup_kubeconfig 时整目录重建）
ACP_AUTH_CACHE_DIR="${ACP_AUTH_CACHE_DIR:-$(cd "$__ACP_AUTH_SH_DIR/.." && pwd)/.acp-auth}"
ACP_AUTH_TOKEN_CACHE_FILE="$ACP_AUTH_CACHE_DIR/token.json"

# token 剩余有效期少于该秒数时视为过期（避免测试跑到一半失效）
ACP_AUTH_EXPIRY_MARGIN="${ACP_AUTH_EXPIRY_MARGIN:-1800}"

# ── 内部工具 ────────────────────────────────────────────────────────────────

# 统一的 curl 调用（测试环境多为自签证书，沿用框架其它处的 -k）
_acp_auth_curl() {
    curl -k -sS --max-time "${ACP_AUTH_HTTP_TIMEOUT:-30}" "$@"
}

# 跨平台 sha256（Linux: sha256sum / macOS: shasum -a 256）
_acp_auth_sha256() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

# 校验自动登录所需的工具与环境变量
_acp_auth_check_prereq() {
    local missing=()
    local tool
    for tool in curl jq openssl; do
        command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "自动获取 ACP API Token 缺少工具: ${missing[*]}"
        return 1
    fi

    missing=()
    [ -z "${PLATFORM_ADDRESS:-}" ] && missing+=("PLATFORM_ADDRESS")
    [ -z "${PLATFORM_USERNAME:-}" ] && missing+=("PLATFORM_USERNAME")
    [ -z "${PLATFORM_PASSWORD:-}" ] && missing+=("PLATFORM_PASSWORD")
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "自动获取 ACP API Token 缺少环境变量: ${missing[*]}"
        return 1
    fi
    return 0
}

# 从 dex 登录/授权响应中提取可读的错误原因
# 兼容 {"reason":..} / {"error":{"reason":..}} / {"error":"..."} / {"message":..} 等形态
_acp_auth_error_reason() {
    jq -r '
        def nonempty: select(type == "string" and length > 0);
        first(
            (.reason? | nonempty),
            (.error?.reason? | nonempty),
            (.error_description? | nonempty),
            (.error? | nonempty),
            (.message? | nonempty)
        ) // empty
    ' 2>/dev/null <<< "$1"
}

# 解析 JWT 的 exp（秒级 Unix 时间戳）；解析不出则输出 0
_acp_auth_token_expiry() {
    local token="$1" payload pad claim
    payload=$(cut -d. -f2 <<< "$token" | tr '_-' '/+')
    [ -z "$payload" ] && { echo 0; return 0; }
    pad=$(( 4 - ${#payload} % 4 ))
    [ "$pad" -lt 4 ] && payload="${payload}$(printf '=%.0s' $(seq "$pad"))"
    claim=$(openssl base64 -d -A <<< "$payload" 2>/dev/null | jq -r '.exp // 0' 2>/dev/null || echo 0)
    case "$claim" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$claim" ;;
    esac
}

# 缓存指纹：平台地址 + 用户名（换环境或换账号时缓存自动失效）
_acp_auth_cache_fingerprint() {
    printf '%s|%s' "${PLATFORM_ADDRESS%/}" "${PLATFORM_USERNAME:-}" | _acp_auth_sha256
}

# 读取缓存 token（校验指纹与有效期）；命中输出 token，未命中返回 1
_acp_auth_cache_read() {
    [ "${ACP_AUTH_NO_CACHE:-false}" = "true" ] && return 1
    [ -f "$ACP_AUTH_TOKEN_CACHE_FILE" ] || return 1

    local cached fingerprint exp token now
    cached=$(cat "$ACP_AUTH_TOKEN_CACHE_FILE" 2>/dev/null) || return 1
    fingerprint=$(jq -r '.fingerprint // empty' <<< "$cached" 2>/dev/null) || return 1
    [ "$fingerprint" = "$(_acp_auth_cache_fingerprint)" ] || return 1

    exp=$(jq -r '.exp // 0' <<< "$cached" 2>/dev/null || echo 0)
    token=$(jq -r '.token // empty' <<< "$cached" 2>/dev/null || echo "")
    [ -n "$token" ] || return 1

    now=$(date +%s)
    [ "$exp" -gt $(( now + ACP_AUTH_EXPIRY_MARGIN )) ] 2>/dev/null || return 1

    printf '%s' "$token"
}

# 写入 token 缓存（600 权限，不打印内容）
_acp_auth_cache_write() {
    local token="$1" exp="$2" tmp
    [ "${ACP_AUTH_NO_CACHE:-false}" = "true" ] && return 0

    mkdir -p "$ACP_AUTH_CACHE_DIR" || return 1
    chmod 700 "$ACP_AUTH_CACHE_DIR" 2>/dev/null || true

    tmp=$(mktemp "${ACP_AUTH_CACHE_DIR}/.token.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    if ! ACP_AUTH_TMP_TOKEN="$token" jq -n \
        --arg fingerprint "$(_acp_auth_cache_fingerprint)" \
        --argjson exp "$exp" \
        '{fingerprint: $fingerprint, exp: $exp, token: $ENV.ACP_AUTH_TMP_TOKEN}' > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$ACP_AUTH_TOKEN_CACHE_FILE" || { rm -f "$tmp"; return 1; }
    chmod 600 "$ACP_AUTH_TOKEN_CACHE_FILE" 2>/dev/null || true
    return 0
}

# ── 对外函数 ────────────────────────────────────────────────────────────────

# 校验 token 能否访问平台 API
# 用法: acp_api_token_valid <token>
acp_api_token_valid() {
    local token="$1" code
    [ -n "$token" ] || return 1
    [ -n "${PLATFORM_ADDRESS:-}" ] || return 1

    code=$(_acp_auth_curl -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        "${PLATFORM_ADDRESS%/}/auth/v1/clusters" 2>/dev/null) || return 1
    [ "$code" = "200" ]
}

# 用平台账号密码登录，token 输出到 stdout（不写缓存、不 export）
# 用法: token=$(acp_login_api_token)
acp_login_api_token() {
    _acp_auth_check_prereq || return 1

    local addr="${PLATFORM_ADDRESS%/}"
    local client_id="${ACP_AUTH_DEX_CLIENT_ID:-alauda-auth}"
    local tmp_dir req_resp req pubkey_resp ts connector login_body login_resp encrypted
    local http_code frag token reason

    tmp_dir=$(mktemp -d) || return 1
    chmod 700 "$tmp_dir" 2>/dev/null || true
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" RETURN

    # 1. 发起授权请求，拿到登录请求 ID
    #    redirect_uri 用平台自身的 console-platform（dex client 已放行平台地址下的任意路径），
    #    implicit 流程下 token 直接回写在 redirect_url 的 fragment 里，不会真正发生跳转。
    req_resp=$(_acp_auth_curl -G "${addr}/dex/api/v1/authorize" \
        --data-urlencode "client_id=${client_id}" \
        --data-urlencode "redirect_uri=${addr}/console-platform" \
        --data-urlencode "response_type=id_token" \
        --data-urlencode "scope=openid profile email groups" \
        --data-urlencode "nonce=$(openssl rand -hex 16)" \
        --data-urlencode "state=docs-runme-tests" 2>&1) || {
        log_error "请求 dex 授权接口失败: ${addr}/dex/api/v1/authorize"
        log_error "curl 输出: $req_resp"
        return 1
    }

    req=$(jq -r '.req // empty' <<< "$req_resp" 2>/dev/null || echo "")
    if [ -z "$req" ]; then
        log_error "未能从 dex 授权响应中取得登录请求 ID (req)"
        log_error "响应: $(head -c 500 <<< "$req_resp")"
        return 1
    fi

    # 2. 取密码加密公钥（含服务端时间戳）
    pubkey_resp=$(_acp_auth_curl "${addr}/dex/pubkey" 2>&1) || {
        log_error "获取 dex 密码公钥失败: ${addr}/dex/pubkey"
        return 1
    }
    ts=$(jq -r '.ts // empty' <<< "$pubkey_resp" 2>/dev/null || echo "")
    jq -r '.pubkey // empty' <<< "$pubkey_resp" > "$tmp_dir/pubkey.pem" 2>/dev/null
    if [ -z "$ts" ] || [ ! -s "$tmp_dir/pubkey.pem" ]; then
        log_error "dex 密码公钥响应格式异常: $(head -c 300 <<< "$pubkey_resp")"
        return 1
    fi

    # 3. RSA(PKCS#1 v1.5) 加密 {"ts":..,"password":..}
    #    密码经 $ENV 传给 jq，避免出现在进程命令行参数中
    encrypted=$(ACP_AUTH_TMP_TS="$ts" ACP_AUTH_TMP_PASSWORD="$PLATFORM_PASSWORD" \
        jq -cn '{ts: $ENV.ACP_AUTH_TMP_TS, password: $ENV.ACP_AUTH_TMP_PASSWORD}' \
        | tr -d '\n' \
        | openssl pkeyutl -encrypt -pubin -inkey "$tmp_dir/pubkey.pem" -pkeyopt rsa_padding_mode:pkcs1 2>/dev/null \
        | openssl base64 -A) || {
        log_error "加密平台密码失败（openssl RSA 加密）"
        return 1
    }
    if [ -z "$encrypted" ]; then
        log_error "加密平台密码失败：加密结果为空"
        return 1
    fi

    # 4. 提交登录（connector 默认取平台第一个，通常为 local）
    connector="${ACP_AUTH_DEX_CONNECTOR:-}"
    if [ -z "$connector" ]; then
        connector=$(_acp_auth_curl "${addr}/dex/api/v1/connectors" 2>/dev/null \
            | jq -r '.[0].conn_id // "local"' 2>/dev/null || echo "local")
        [ -n "$connector" ] || connector="local"
    fi

    login_body=$(ACP_AUTH_TMP_ACCOUNT="$PLATFORM_USERNAME" ACP_AUTH_TMP_ENC="$encrypted" \
        jq -cn '{account: $ENV.ACP_AUTH_TMP_ACCOUNT, password: $ENV.ACP_AUTH_TMP_ENC}')

    http_code=$(_acp_auth_curl -o "$tmp_dir/login.json" -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        --data-binary "$login_body" \
        "${addr}/dex/api/v1/authorize/${connector}?req=${req}" 2>/dev/null) || {
        log_error "调用 dex 登录接口失败: ${addr}/dex/api/v1/authorize/${connector}"
        return 1
    }
    login_resp=$(cat "$tmp_dir/login.json" 2>/dev/null || echo "")

    if [ "$http_code" != "200" ]; then
        reason=$(_acp_auth_error_reason "$login_resp")
        log_error "平台登录失败: HTTP $http_code${reason:+（$reason）}"
        case "$reason" in
            *FirstLoginPasswordUpdate*|*PasswordExpired*)
                log_error "该账号需先在 ACP 页面修改密码后才能登录" ;;
            *[Cc]aptcha*|*verify*|*Verify*)
                log_error "该账号触发了验证码/二次验证，无法自动登录；请改用 UI 生成的 ACP_API_TOKEN" ;;
        esac
        return 1
    fi

    # 5. 从 redirect_url 的 fragment 中取 id_token
    frag=$(jq -r '.redirect_url // empty' <<< "$login_resp" 2>/dev/null | sed 's/^[^#]*#//')
    token=$(tr '&' '\n' <<< "$frag" | grep '^id_token=' | cut -d= -f2- | head -n 1)
    [ -n "$token" ] || token=$(tr '&' '\n' <<< "$frag" | grep '^access_token=' | cut -d= -f2- | head -n 1)

    if [ -z "$token" ]; then
        log_error "登录成功但未能从回调地址中解析出 token"
        log_error "回调参数: $(tr '&' '\n' <<< "$frag" | cut -d= -f1 | tr '\n' ' ')"
        return 1
    fi

    printf '%s' "$token"
    return 0
}

# 确保 ACP_API_TOKEN 可用并 export
# 优先级: 已配置且可用的 ACP_API_TOKEN > 有效缓存 > 用平台账号密码登录
ensure_acp_api_token() {
    local token exp now

    # 1. 显式配置的 token 优先
    if [ -n "${ACP_API_TOKEN:-}" ]; then
        if acp_api_token_valid "$ACP_API_TOKEN"; then
            export ACP_API_TOKEN
            return 0
        fi
        if [ -z "${PLATFORM_USERNAME:-}" ] || [ -z "${PLATFORM_PASSWORD:-}" ]; then
            log_error "配置的 ACP_API_TOKEN 无法访问 ${PLATFORM_ADDRESS%/}/auth/v1/clusters"
            log_error "请检查 token 是否过期、平台地址是否可达，或配置 PLATFORM_USERNAME / PLATFORM_PASSWORD 以自动获取"
            return 1
        fi
        log_warn "配置的 ACP_API_TOKEN 校验失败（可能已过期），改用平台账号自动获取"
        unset ACP_API_TOKEN
    fi

    # 2. 缓存命中且仍可用
    if token=$(_acp_auth_cache_read) && [ -n "$token" ]; then
        if acp_api_token_valid "$token"; then
            export ACP_API_TOKEN="$token"
            log_info "复用缓存的 ACP API Token: $ACP_AUTH_TOKEN_CACHE_FILE"
            return 0
        fi
        log_warn "缓存的 ACP API Token 已失效，重新登录获取"
    fi

    # 3. 用平台账号密码登录
    _acp_auth_check_prereq || {
        log_error "未配置 ACP_API_TOKEN，且无法自动获取"
        return 1
    }

    log_info "使用平台账号 ${PLATFORM_USERNAME} 自动获取 ACP API Token..."
    token=$(acp_login_api_token) || return 1

    if ! acp_api_token_valid "$token"; then
        log_error "自动获取的 token 无法访问平台 API，请确认账号权限"
        return 1
    fi

    exp=$(_acp_auth_token_expiry "$token")
    now=$(date +%s)
    if [ "$exp" -gt "$now" ] 2>/dev/null; then
        log_success "已获取 ACP API Token（有效期至 $(date -d "@$exp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$exp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$exp")）"
    else
        exp=0
        log_success "已获取 ACP API Token"
    fi

    _acp_auth_cache_write "$token" "$exp" || log_warn "写入 token 缓存失败（不影响本次执行）: $ACP_AUTH_TOKEN_CACHE_FILE"

    export ACP_API_TOKEN="$token"
    return 0
}
