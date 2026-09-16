#!/usr/bin/env bash
# tracing Jaeger v2 集群插件「落地集群」解析的单元测试（打桩，不联网、不依赖集群）
# 用法: bash framework/tests/tracing_jaeger_plugin_test.sh
#
# 集群插件的 ModuleInfo 建在 Global 集群，落地到哪个业务集群由参数决定，光切
# kubeconfig context 决定不了——多集群网格要两个集群各装一套调用链，这个优先级
# （显式参数 > TEST_TARGET_CLUSTER > SINGLE_CLUSTER_NAME）必须锁住。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/tools.sh"
# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/projects/tracing/jaeger-plugin.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if [ "$2" = "$3" ]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 打桩全局侧安装：只把拿到的目标集群记到 RESOLVED，不碰平台与集群
_tracing_jaeger_plugin_install_via_global() {
    RESOLVED="$2"
    return 0
}

# 解析一次目标集群（verify_cm_block 显式传空，跳过目标集群侧的 runme 校验）
# 用法: resolve [<显式目标集群>]
resolve() {
    RESOLVED=""
    tracing_install_jaeger_plugin "install-tracing-elasticsearch" "${1:-}" "" > /dev/null 2>&1
    printf '%s' "$RESOLVED"
}

main() {
    KUBECONFIG_DIR="$(mktemp -d)"
    export KUBECONFIG_DIR
    : > "$KUBECONFIG_DIR/global.yaml"   # 函数只检查 Global kubeconfig 是否存在

    printf '\n== 落地集群优先级 ==\n'
    export SINGLE_CLUSTER_NAME=east
    unset TEST_TARGET_CLUSTER
    check_eq "未指定 --cluster 时用 SINGLE_CLUSTER_NAME" "$(resolve)" "east"

    export TEST_TARGET_CLUSTER=west
    check_eq "TEST_TARGET_CLUSTER 优先于 SINGLE_CLUSTER_NAME" "$(resolve)" "west"
    check_eq "显式参数优先于两者"                            "$(resolve other)" "other"

    unset SINGLE_CLUSTER_NAME
    check_eq "只有 TEST_TARGET_CLUSTER 时也能解析" "$(resolve)" "west"

    printf '\n== 两者皆空时报错 ==\n'
    unset TEST_TARGET_CLUSTER
    local rc=0
    tracing_install_jaeger_plugin "install-tracing-elasticsearch" "" "" > /dev/null 2>&1 || rc=$?
    check_eq "无目标集群返回非 0" "$rc" "1"

    rm -rf "$KUBECONFIG_DIR"

    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
