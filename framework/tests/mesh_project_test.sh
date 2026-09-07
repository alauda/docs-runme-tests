#!/usr/bin/env bash
# mesh project.sh 单元测试（纯 Bash，可独立运行，不依赖集群）
# 用法: bash framework/tests/mesh_project_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
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

test_relax_psa_for_root_gateway() {
    printf '\n== relax_psa_for_root_gateway 门控与放宽行为 ==\n'

    local calls_file
    calls_file="$(mktemp)"

    # 桩 kubectl：记录调用，并按 PSA_LABEL 返回命名空间当前的 enforce 值
    kubectl() {
        printf '%s\n' "$*" >> "$calls_file"
        case "$*" in
            *"jsonpath="*) printf '%s' "${PSA_LABEL:-}" ;;
        esac
        return 0
    }

    # 1) 门控关闭 → no-op
    : > "$calls_file"
    ENABLE_GW_LINUX_KERNEL_COMPAT=false PSA_LABEL=restricted \
        relax_psa_for_root_gateway bookinfo true >/dev/null 2>&1
    check_eq "门控关闭时不调用 kubectl" "$(wc -l < "$calls_file" | tr -d ' ')" "0"

    # 2) 门控开启但非 root → no-op
    : > "$calls_file"
    ENABLE_GW_LINUX_KERNEL_COMPAT=true PSA_LABEL=restricted \
        relax_psa_for_root_gateway bookinfo false >/dev/null 2>&1
    check_eq "非 root 时不调用 kubectl" "$(wc -l < "$calls_file" | tr -d ' ')" "0"

    # 3) 门控开启 + root + 命名空间为 restricted → 放宽为 baseline
    : > "$calls_file"
    ENABLE_GW_LINUX_KERNEL_COMPAT=true PSA_LABEL=restricted \
        relax_psa_for_root_gateway bookinfo true >/dev/null 2>&1
    check_contains "restricted 时放宽为 baseline" "$(cat "$calls_file")" \
        "label namespace bookinfo pod-security.kubernetes.io/enforce=baseline --overwrite"

    # 4) 门控开启 + root，但命名空间没打 enforce 标签 → 只查询不改标签
    : > "$calls_file"
    ENABLE_GW_LINUX_KERNEL_COMPAT=true PSA_LABEL= \
        relax_psa_for_root_gateway bookinfo true >/dev/null 2>&1
    check_eq "无 enforce 标签时不改标签" "$(grep -c 'label namespace' "$calls_file" | tr -d ' ')" "0"

    # 5) 多集群：传入 context 时注入 --context
    : > "$calls_file"
    ENABLE_GW_LINUX_KERNEL_COMPAT=true PSA_LABEL=restricted \
        relax_psa_for_root_gateway sample true cluster1 >/dev/null 2>&1
    check_contains "带 context 时注入 --context" "$(cat "$calls_file")" "--context cluster1 label namespace sample"

    unset -f kubectl
    rm -f "$calls_file"
}

test_retry_runme_verify() {
    printf '\n== retry_runme_verify ==\n'

    local calls_file
    calls_file="$(mktemp)"

    # 桩：前 N 次失败，之后成功；调用次数记到 calls_file
    runme() {
        printf 'x\n' >> "$calls_file"
        local n
        n=$(wc -l < "$calls_file" | tr -d ' ')
        if [ "$n" -le "${STUB_FAIL_TIMES:-0}" ]; then
            echo "container not found"
            return 1
        fi
        echo "ok-output"
        return 0
    }
    sleep() { :; }   # 免等待

    # 1) 首次即成功 —— 只调用一次
    : > "$calls_file"; RETRY_RUNME_OUTPUT=
    STUB_FAIL_TIMES=0 retry_runme_verify blk __cmp_contains "ok-output" 5 1 >/dev/null 2>&1
    check_eq "首次成功只执行一次" "$(wc -l < "$calls_file" | tr -d ' ')" "1"
    check_eq "输出回填 RETRY_RUNME_OUTPUT" "$RETRY_RUNME_OUTPUT" "ok-output"

    # 2) 前两次 exec 失败 —— 第三次成功，返回 0
    : > "$calls_file"
    STUB_FAIL_TIMES=2 retry_runme_verify blk __cmp_contains "ok-output" 5 1 >/dev/null 2>&1
    check_eq "瞬时失败后重试成功" "$?" "0"
    check_eq "共执行三次" "$(wc -l < "$calls_file" | tr -d ' ')" "3"

    # 3) 块本身成功但输出不匹配 —— 耗尽重试后返回 1
    : > "$calls_file"
    STUB_FAIL_TIMES=0 retry_runme_verify blk __cmp_contains "never-match" 3 1 >/dev/null 2>&1
    check_eq "断言始终不过则返回 1" "$?" "1"
    check_eq "按 attempts 次数耗尽" "$(wc -l < "$calls_file" | tr -d ' ')" "3"

    unset -f runme sleep
    unset STUB_FAIL_TIMES
    rm -f "$calls_file"
}

main() {
    test_fetch_platform_ca_fallback_stdout_is_pure
    test_relax_psa_for_root_gateway
    test_retry_runme_verify
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}

main
