#!/usr/bin/env bash
# lynx/env-adapter.sh 单元测试（纯 bash + jq，不依赖集群）
# 用法: bash framework/tests/env_adapter_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 在子 shell 里跑一次适配，回显指定变量，避免污染测试进程
adapt_and_echo() {
    local var="$1"; shift
    ( set -u
      # shellcheck disable=SC1090,SC1091
      . "$FRAMEWORK_ROOT/lynx/env-adapter.sh"
      env -i PATH="$PATH" HOME="$HOME" FRAMEWORK_ROOT="$FRAMEWORK_ROOT" "$@" \
        bash -c '
          . "$FRAMEWORK_ROOT/framework/common.sh"
          . "$FRAMEWORK_ROOT/lynx/env-adapter.sh"
          lynx_adapt_env >/dev/null 2>&1
          printf "%s" "${'"$var"':-}"
        ' )
}

test_credential_mapping() {
    printf '\n== 平台凭据映射 ==\n'
    check_eq "API_URL→PLATFORM_ADDRESS"      "$(adapt_and_echo PLATFORM_ADDRESS  API_URL=https://acp.example)"      "https://acp.example"
    check_eq "USERNAME→PLATFORM_USERNAME"    "$(adapt_and_echo PLATFORM_USERNAME USERNAME=admin)"                   "admin"
    check_eq "PASSWORD→PLATFORM_PASSWORD"    "$(adapt_and_echo PLATFORM_PASSWORD PASSWORD=p@ss)"                    "p@ss"
    check_eq "REGION_NAME→SINGLE_CLUSTER_NAME" "$(adapt_and_echo SINGLE_CLUSTER_NAME REGION_NAME=asm-1)"            "asm-1"
    check_eq "已有 PLATFORM_ADDRESS 不被覆盖" \
        "$(adapt_and_echo PLATFORM_ADDRESS API_URL=https://a PLATFORM_ADDRESS=https://b)" "https://b"
}

test_ippool_mapping() {
    printf '\n== GLOBAL_EXTERNAL_IPPOOL → METALLB_EXTERNAL_ADDRESSES_JSON ==\n'
    local out
    out="$(adapt_and_echo METALLB_EXTERNAL_ADDRESSES_JSON REGION_NAME=asm-1 GLOBAL_EXTERNAL_IPPOOL='"192.168.1.10,192.168.1.11"')"
    check_eq "集群名"   "$(printf '%s' "$out" | jq -r '.[0].cluster')"              "asm-1"
    check_eq "两个地址" "$(printf '%s' "$out" | jq -r '.[0].ipv4Addresses | length')" "2"
    check_eq "补 /32"   "$(printf '%s' "$out" | jq -r '.[0].ipv4Addresses[0]')"     "192.168.1.10/32"

    out="$(adapt_and_echo METALLB_EXTERNAL_ADDRESSES_JSON REGION_NAME=asm-1 \
           GLOBAL_EXTERNAL_IPPOOL=192.168.1.10 GLOBAL_EXTERNAL_IPPOOL_V6=fd00::1)"
    check_eq "v6 补 /128" "$(printf '%s' "$out" | jq -r '.[0].ipv6Addresses[0]')" "fd00::1/128"

    out="$(adapt_and_echo METALLB_EXTERNAL_ADDRESSES_JSON REGION_NAME=asm-1)"
    check_eq "无 IP 池时不产生 JSON" "$out" ""
}

test_defaults() {
    printf '\n== 默认值 ==\n'
    check_eq "GLOBAL_CLUSTER_NAME 默认 global" "$(adapt_and_echo GLOBAL_CLUSTER_NAME)"      "global"
    check_eq "ACP_KUBECONFIG_MODE 默认 direct" "$(adapt_and_echo ACP_KUBECONFIG_MODE)"      "direct"
    check_eq "IS_DUAL_STACK 默认 false"        "$(adapt_and_echo IS_DUAL_STACK)"            "false"
    check_eq "EXIT_ON_TEST_FAILURE 默认 false" "$(adapt_and_echo EXIT_ON_TEST_FAILURE)"     "false"
    check_eq "模板显式值优先"                  "$(adapt_and_echo IS_DUAL_STACK IS_DUAL_STACK=true)" "true"
}

main() {
    test_credential_mapping
    test_ippool_mapping
    test_defaults
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
