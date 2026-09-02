#!/usr/bin/env bash
# _create_namespace_safe 单元测试（纯 Bash，可独立运行，不依赖集群）
# 用法: bash framework/tests/create_namespace_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"

T_PASS=0
T_FAIL=0
CALLS=""
PSA_LABEL=""
CREATE_RC=0

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

# 桩 runme：只实现 print，返回一个「建两个命名空间 + 各打一次 PSA 标签」的代码块
runme() {
    [ "$1" = "print" ] || return 1
    cat <<'BLK'
kubectl create namespace ns-a
kubectl label namespace ns-a pod-security.kubernetes.io/enforce=restricted --overwrite
kubectl create namespace ns-b
kubectl label namespace ns-b pod-security.kubernetes.io/enforce=restricted --overwrite
BLK
}

# 桩 kubectl：记录调用；create 按 CREATE_RC 决定成败（模拟 AlreadyExists），
# jsonpath 查询返回 PSA_LABEL
kubectl() {
    CALLS="$CALLS$*"$'\n'
    case "$*" in
        *"create namespace"*) return "$CREATE_RC" ;;
        *"jsonpath="*) printf '%s' "$PSA_LABEL"; return 0 ;;
    esac
    return 0
}

test_all_lines_run_even_after_failure() {
    printf '\n== 块内首条命令失败时后续命令仍执行 ==\n'
    CALLS=""; PSA_LABEL="restricted"; CREATE_RC=1   # create 全部失败（模拟 AlreadyExists）

    _create_namespace_safe fake:block "ns-a ns-b" >/dev/null 2>&1
    check_eq "返回 0" "$?" "0"
    check_contains "第二个命名空间仍被创建" "$CALLS" "create namespace ns-b"
    check_contains "ns-a 的 PSA 标签仍被下发" "$CALLS" "label namespace ns-a pod-security.kubernetes.io/enforce=restricted --overwrite"
    check_contains "ns-b 的 PSA 标签仍被下发" "$CALLS" "label namespace ns-b pod-security.kubernetes.io/enforce=restricted --overwrite"
}

test_psa_label_verified() {
    printf '\n== PSA enforce 标签校验 ==\n'
    local rc

    CALLS=""; PSA_LABEL="restricted"; CREATE_RC=0
    _create_namespace_safe fake:block "ns-a ns-b" >/dev/null 2>&1; rc=$?
    check_eq "标签生效时返回 0" "$rc" "0"

    CALLS=""; PSA_LABEL="baseline"; CREATE_RC=0
    _create_namespace_safe fake:block "ns-a ns-b" >/dev/null 2>&1; rc=$?
    check_eq "标签值不符时返回 1" "$rc" "1"

    CALLS=""; PSA_LABEL=""; CREATE_RC=0
    _create_namespace_safe fake:block "ns-a ns-b" >/dev/null 2>&1; rc=$?
    check_eq "标签缺失时返回 1" "$rc" "1"
}

test_empty_block_is_error() {
    printf '\n== 代码块取不到内容时报错 ==\n'
    local rc
    runme() { printf ''; }
    _create_namespace_safe fake:block "ns-a" >/dev/null 2>&1; rc=$?
    check_eq "空代码块返回 1" "$rc" "1"
}

main() {
    test_all_lines_run_even_after_failure
    test_psa_label_verified
    test_empty_block_is_error
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}

main
