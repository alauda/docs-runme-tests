#!/usr/bin/env bash
# acp-auth.sh 单元测试（纯 bash，可独立运行，不依赖集群与平台）
# 网络交互（登录 / token 校验）通过覆盖函数打桩，只验证取值优先级、缓存与解析逻辑。
# 用法: bash framework/tests/acp_auth_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# 缓存目录指向临时沙箱，避免污染仓库的 .acp-auth/
ACP_AUTH_CACHE_DIR="$(mktemp -d)"
export ACP_AUTH_CACHE_DIR

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/acp-auth.sh"

T_PASS=0
T_FAIL=0

# check_eq <描述> <实际> <期望>
check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 构造一个 exp 为指定时间戳的伪 JWT（仅用于解析测试，不含有效签名）
fake_jwt() {
    local exp="$1" payload
    payload=$(printf '{"exp":%s,"email":"tester"}' "$exp" \
        | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    printf 'ZmFrZQ.%s.c2ln' "$payload"
}

# 每个用例用独立的缓存沙箱与干净的环境变量
new_sandbox() {
    rm -rf "$ACP_AUTH_CACHE_DIR"
    ACP_AUTH_CACHE_DIR="$(mktemp -d)"
    ACP_AUTH_TOKEN_CACHE_FILE="$ACP_AUTH_CACHE_DIR/token.json"
    unset ACP_API_TOKEN
    export PLATFORM_ADDRESS='https://acp.test'
    export PLATFORM_USERNAME='tester'
    export PLATFORM_PASSWORD='secret'
    # 登录次数记在文件里：acp_login_api_token 由命令替换在子 shell 中调用，变量自增传不回来
    LOGIN_CALLS_FILE="$ACP_AUTH_CACHE_DIR/login-calls"
    : > "$LOGIN_CALLS_FILE"
}

login_calls() {
    wc -l < "$LOGIN_CALLS_FILE" | tr -d ' '
}

# ── 打桩：token 校验与登录，均不发起网络请求 ──
# STUB_VALID_TOKEN 之外的 token 一律视为无效
STUB_VALID_TOKEN=""
acp_api_token_valid() {
    [ -n "${1:-}" ] && [ "$1" = "$STUB_VALID_TOKEN" ]
}
acp_login_api_token() {
    echo "call" >> "$LOGIN_CALLS_FILE"
    [ "${STUB_LOGIN_FAIL:-false}" = "true" ] && return 1
    printf '%s' "$STUB_VALID_TOKEN"
}

# ── 测试：JWT exp 解析 ──
test_token_expiry() {
    printf '\n== _acp_auth_token_expiry ==\n'
    check_eq "解析 exp" "$(_acp_auth_token_expiry "$(fake_jwt 2000000000)")" "2000000000"
    check_eq "非 JWT 返回 0" "$(_acp_auth_token_expiry "not-a-jwt")" "0"
    check_eq "空串返回 0" "$(_acp_auth_token_expiry "")" "0"
}

# ── 测试：错误原因提取 ──
test_error_reason() {
    printf '\n== _acp_auth_error_reason ==\n'
    check_eq "reason 字段" "$(_acp_auth_error_reason '{"reason":"PasswordExpired"}')" "PasswordExpired"
    check_eq "error.reason 字段" "$(_acp_auth_error_reason '{"error":{"reason":"Captcha"}}')" "Captcha"
    check_eq "error 字符串" "$(_acp_auth_error_reason '{"error":"invalid_request"}')" "invalid_request"
    check_eq "非 JSON 不报错" "$(_acp_auth_error_reason 'oops')" ""
}

# ── 测试：缓存读写往返 ──
test_cache_roundtrip() {
    printf '\n== 缓存读写 ==\n'
    new_sandbox
    local future=$(( $(date +%s) + 86400 ))
    _acp_auth_cache_write "cached-token" "$future"
    check_eq "命中缓存" "$(_acp_auth_cache_read)" "cached-token"
    check_eq "缓存文件权限 600" "$(ls -l "$ACP_AUTH_TOKEN_CACHE_FILE" | cut -c1-10)" "-rw-------"

    # 换账号 -> 指纹不匹配 -> 不命中
    PLATFORM_USERNAME='someone-else'
    check_eq "换账号不命中" "$(_acp_auth_cache_read)" ""
    PLATFORM_USERNAME='tester'

    # 剩余有效期不足 margin -> 视为过期
    _acp_auth_cache_write "soon-expire" "$(( $(date +%s) + 60 ))"
    check_eq "临近过期不命中" "$(_acp_auth_cache_read)" ""

    # ACP_AUTH_NO_CACHE=true -> 不读缓存
    _acp_auth_cache_write "cached-token" "$future"
    ACP_AUTH_NO_CACHE=true
    check_eq "禁用缓存不读" "$(_acp_auth_cache_read)" ""
    ACP_AUTH_NO_CACHE=false
}

# ── 测试：已配置 token 的处理 ──
test_configured_token() {
    printf '\n== ensure_acp_api_token：已配置 token ==\n'
    new_sandbox
    STUB_VALID_TOKEN="good-token"
    export ACP_API_TOKEN="good-token"
    ensure_acp_api_token > /dev/null 2>&1
    check_eq "有效 token 原样保留" "$ACP_API_TOKEN" "good-token"
    check_eq "未触发登录" "$(login_calls)" "0"

    new_sandbox
    STUB_VALID_TOKEN="fresh-token"
    export ACP_API_TOKEN="stale-token"
    ensure_acp_api_token > /dev/null 2>&1
    check_eq "失效 token 自动换新" "$ACP_API_TOKEN" "fresh-token"
    check_eq "触发一次登录" "$(login_calls)" "1"

    new_sandbox
    STUB_VALID_TOKEN="fresh-token"
    export ACP_API_TOKEN="stale-token"
    unset PLATFORM_PASSWORD
    local rc=0
    ensure_acp_api_token > /dev/null 2>&1 || rc=$?
    check_eq "失效 token 且无凭据则失败" "$rc" "1"
    check_eq "未触发登录（无凭据）" "$(login_calls)" "0"
}

# ── 测试：缓存优先于登录 ──
test_cache_priority() {
    printf '\n== ensure_acp_api_token：缓存优先 ==\n'
    new_sandbox
    STUB_VALID_TOKEN="cached-token"
    _acp_auth_cache_write "cached-token" "$(( $(date +%s) + 86400 ))"
    ensure_acp_api_token > /dev/null 2>&1
    check_eq "复用缓存 token" "$ACP_API_TOKEN" "cached-token"
    check_eq "未触发登录" "$(login_calls)" "0"

    # 缓存里的 token 已被平台撤销 -> 重新登录
    new_sandbox
    STUB_VALID_TOKEN="new-token"
    _acp_auth_cache_write "revoked-token" "$(( $(date +%s) + 86400 ))"
    ensure_acp_api_token > /dev/null 2>&1
    check_eq "缓存失效则重新登录" "$ACP_API_TOKEN" "new-token"
    check_eq "触发一次登录" "$(login_calls)" "1"
}

# ── 测试：登录获取并写缓存 ──
test_login_and_cache() {
    printf '\n== ensure_acp_api_token：登录并缓存 ==\n'
    new_sandbox
    STUB_VALID_TOKEN="$(fake_jwt $(( $(date +%s) + 86400 )))"
    ensure_acp_api_token > /dev/null 2>&1
    check_eq "登录取得 token" "$ACP_API_TOKEN" "$STUB_VALID_TOKEN"
    check_eq "写入缓存" "$(_acp_auth_cache_read)" "$STUB_VALID_TOKEN"

    # 登录失败时应返回非 0
    new_sandbox
    STUB_LOGIN_FAIL=true
    local rc=0
    ensure_acp_api_token > /dev/null 2>&1 || rc=$?
    check_eq "登录失败返回 1" "$rc" "1"
    STUB_LOGIN_FAIL=false
}

# ── 测试：kubeconfig 兜底调用 ──
test_kubeconfig_fallback() {
    printf '\n== kubeconfig 缺 token 时兜底获取 ==\n'
    # shellcheck disable=SC1090,SC1091
    source "$FRAMEWORK_ROOT/framework/kubeconfig.sh"
    new_sandbox
    STUB_VALID_TOKEN="kc-token"
    _check_kubeconfig_env > /dev/null 2>&1
    check_eq "自动补齐 ACP_API_TOKEN" "$ACP_API_TOKEN" "kc-token"

    new_sandbox
    unset PLATFORM_ADDRESS
    local rc=0
    _check_kubeconfig_env > /dev/null 2>&1 || rc=$?
    check_eq "缺平台地址仍报错" "$rc" "1"
}

main() {
    test_token_expiry
    test_error_reason
    test_cache_roundtrip
    test_configured_token
    test_cache_priority
    test_login_and_cache
    test_kubeconfig_fallback
    rm -rf "$ACP_AUTH_CACHE_DIR"
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
