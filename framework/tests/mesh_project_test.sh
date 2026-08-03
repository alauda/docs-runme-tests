#!/usr/bin/env bash
# mesh project.sh 单元测试（纯 Bash，可独立运行，不依赖集群）
# 用法: bash framework/tests/mesh_project_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

T_PASS=0
T_FAIL=0

check_contains() {
    if [[ "$2" == *"$3"* ]]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_eq() {
    if [ "$2" = "$3" ]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

test_fetch_platform_ca_fallback_stdout_is_pure() {
    printf '\n== fetch_platform_ca 回退路径 ==\n'

    local sandbox stderr_file output warning
    sandbox="$(mktemp -d)"
    stderr_file="$(mktemp)"
    KUBECONFIG_DIR="$sandbox"
    GLOBAL_CLUSTER_NAME="global"
    : > "$KUBECONFIG_DIR/global.yaml"

    # 满足工具检查；实际代码块执行由下方桩函数接管。
    runme() {
        return 0
    }

    # 模拟 ca.crt 为空、tls.crt 存在的集群数据。
    _run_runme_block_isolated() {
        case "$1" in
            config-kiali:get-ca-certificate) printf '' ;;
            config-kiali:get-ca-certificate-alternative) printf 'ZmFrZS1jYQ==' ;;
            *) return 1 ;;
        esac
    }

    output="$(fetch_platform_ca 2>"$stderr_file")"
    warning="$(sed $'s/\033\\[[0-9;]*m//g' "$stderr_file")"

    check_eq "stdout 只包含回退证书" "$output" "ZmFrZS1jYQ=="
    check_contains "stderr 包含回退警告" "$warning" "返回空，回退到 alternative 块"

    rm -f "$stderr_file"
    rm -rf "$sandbox"
}

main() {
    test_fetch_platform_ca_fallback_stdout_is_pure
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}

main
