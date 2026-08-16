#!/usr/bin/env bash
# install_operator 重入（幂等）逻辑单元测试（纯 Bash，可独立运行，不依赖集群）
# 用法: bash framework/tests/install_operator_test.sh
#
# 通过在 PATH 前置伪造的 kubectl / runme 模拟集群状态：
#   FAKE_CSV_PHASE     - 目标 CSV 的 status.phase；空表示 CSV 不存在
#   FAKE_CSV_PHASE_SEQ - 多次查询 status.phase 时依次返回的值（模拟中间态收敛）
#   FAKE_SUBSCRIPTION  - 1 表示 Subscription 存在
#   FAKE_INSTALLPLAN_PENDING - 0 表示 wait-installplan-pending 失败（无挂起的 InstallPlan）
# 伪造 kubectl 会把每次调用记录到 $FAKE_LOG，用例据此断言实际执行了哪些动作。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/verify.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if [ "$2" = "$3" ]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_contains() {
    if [[ "$2" == *"$3"* ]]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_not_contains() {
    if [[ "$2" != *"$3"* ]]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望不含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# ------------------------------------------------------------------------------
# 伪造 kubectl / runme
# ------------------------------------------------------------------------------
FAKE_BIN="$(mktemp -d)"

cat > "$FAKE_BIN/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
# 伪造 kubectl：按环境变量描述的集群状态应答，并把调用记录到 $FAKE_LOG
echo "kubectl $*" >> "$FAKE_LOG"

# 跨调用的状态（如 status.phase 查询次数）保存在 $FAKE_STATE_FILE
if [ -s "${FAKE_STATE_FILE:-/dev/null}" ]; then
    # shellcheck disable=SC1090
    source "$FAKE_STATE_FILE"
fi

args=("$@")
# 跳过 -n <ns>
if [ "${args[0]:-}" = "-n" ]; then
    args=("${args[@]:2}")
fi

verb="${args[0]:-}"
kind="${args[1]:-}"
name="${args[2]:-}"

case "$verb:$kind" in
    get:csv)
        if [ -z "${FAKE_CSV_PHASE:-}" ]; then
            echo "Error from server (NotFound): csv \"$name\" not found" >&2
            exit 1
        fi
        for a in "$@"; do
            case "$a" in
                *status.phase*)
                    if [ -n "${FAKE_CSV_PHASE_SEQ:-}" ]; then
                        # 第 N 次查询返回序列里的第 N 个值（超出则取最后一个），模拟中间态收敛
                        n=$(( ${FAKE_PHASE_N:-0} + 1 ))
                        echo "FAKE_PHASE_N=$n" >> "$FAKE_STATE_FILE"
                        phases=($FAKE_CSV_PHASE_SEQ)
                        idx=$(( n - 1 ))
                        if [ "$idx" -ge "${#phases[@]}" ]; then idx=$(( ${#phases[@]} - 1 )); fi
                        echo "${phases[$idx]}"
                    else
                        echo "$FAKE_CSV_PHASE"
                    fi
                    exit 0 ;;
            esac
        done
        echo "$name  Succeeded"
        exit 0 ;;
    get:subscription)
        if [ "${FAKE_SUBSCRIPTION:-0}" = "1" ]; then exit 0; fi
        echo "Error from server (NotFound): subscription \"$name\" not found" >&2
        exit 1 ;;
    wait:*)
        exit 0 ;;
esac
exit 0
FAKE_KUBECTL

cat > "$FAKE_BIN/runme" <<'FAKE_RUNME'
#!/usr/bin/env bash
# 伪造 runme：记录调用，print 输出可执行内容，run 直接成功
echo "runme $*" >> "$FAKE_LOG"
action="$1"
block="$2"
case "$action:$block" in
    print:*create-subscription-*)
        echo 'true # apply subscription'
        exit 0 ;;
    print:*confirm-catalogsource-output)
        echo "platform"; exit 0 ;;
    run:*confirm-catalogsource)
        echo "platform"; exit 0 ;;
    run:*check-packagemanifest-versions)
        echo "CHANNEL  NAME  VERSION"
        echo "stable   opentelemetry-operator2.v0.156.0  0.156.0"
        exit 0 ;;
    run:*wait-installplan-pending)
        if [ "${FAKE_INSTALLPLAN_PENDING:-1}" = "1" ]; then exit 0; fi
        exit 1 ;;
    run:*check-csv-status)
        echo "opentelemetry-operator2.v0.156.0  Succeeded"; exit 0 ;;
    run:*)
        exit 0 ;;
    print:*)
        echo "true"; exit 0 ;;
esac
exit 0
FAKE_RUNME

chmod +x "$FAKE_BIN/kubectl" "$FAKE_BIN/runme"
export PATH="$FAKE_BIN:$PATH"

PKG_URL="http://example.com/opentelemetry-operator2.stable.ALL.v0.156.0.tgz"

# 每个用例重置伪造状态
new_case() {
    FAKE_LOG="$(mktemp)"; export FAKE_LOG
    FAKE_STATE_FILE="$(mktemp)"; export FAKE_STATE_FILE
    export FAKE_CSV_PHASE="" FAKE_CSV_PHASE_SEQ="" FAKE_SUBSCRIPTION=0 FAKE_INSTALLPLAN_PENDING=1
    # 重入探测的等待循环在单测里不要真的 sleep
    export OPERATOR_REENTRY_WAIT_RETRIES=3 OPERATOR_REENTRY_WAIT_INTERVAL=0
}

run_install() {
    local out rc=0
    out=$(install_operator "opentelemetry-operator2" "opentelemetry-operator2" "$PKG_URL" "install-otel" 2>&1) || rc=$?
    LAST_OUTPUT="$out"
    LAST_RC="$rc"
}

# ------------------------------------------------------------------------------
# 用例
# ------------------------------------------------------------------------------

test_fresh_install() {
    printf '\n== 全新安装（无 CSV）==\n'
    new_case
    run_install
    check_eq "返回码 0" "$LAST_RC" "0"
    check_contains "执行了 Subscription 创建" "$(cat "$FAKE_LOG")" "runme print install-otel:create-subscription-opentelemetry-operator2"
    check_contains "执行了 InstallPlan 审批" "$(cat "$FAKE_LOG")" "runme run install-otel:approve-installplan-manual"
}

test_already_installed() {
    printf '\n== 重入：已安装（CSV Succeeded）—— 跳过安装 ==\n'
    new_case
    export FAKE_CSV_PHASE="Succeeded" FAKE_SUBSCRIPTION=1
    run_install
    check_eq "返回码 0" "$LAST_RC" "0"
    check_contains "提示已安装" "$LAST_OUTPUT" "已安装"
    check_contains "提示跳过安装" "$LAST_OUTPUT" "跳过 opentelemetry-operator2 安装"
    check_not_contains "未重新创建 Subscription" "$(cat "$FAKE_LOG")" "create-subscription"
    check_not_contains "未执行 InstallPlan 审批" "$(cat "$FAKE_LOG")" "approve-installplan-manual"
}

test_installed_without_subscription() {
    printf '\n== 重入：已安装但 Subscription 不存在 —— 同样跳过（不代管集群资源）==\n'
    new_case
    export FAKE_CSV_PHASE="Succeeded" FAKE_SUBSCRIPTION=0
    run_install
    check_eq "返回码 0" "$LAST_RC" "0"
    check_contains "提示跳过安装" "$LAST_OUTPUT" "跳过 opentelemetry-operator2 安装"
    check_not_contains "未重新创建 Subscription" "$(cat "$FAKE_LOG")" "create-subscription"
}

test_intermediate_phase_converges() {
    printf '\n== 重入：CSV 处于中间态，等待其收敛为 Succeeded ==\n'
    new_case
    export FAKE_CSV_PHASE="Installing" FAKE_CSV_PHASE_SEQ="Installing Installing Succeeded"
    run_install
    check_eq "返回码 0" "$LAST_RC" "0"
    check_contains "等待中间态收敛" "$LAST_OUTPUT" "等待其变为 Succeeded"
    check_contains "收敛后判定已安装" "$LAST_OUTPUT" "已安装 (phase=Succeeded)"
    check_not_contains "未走安装流程" "$(cat "$FAKE_LOG")" "create-subscription"
}

test_failed_csv() {
    printf '\n== 重入：CSV 处于 Failed —— 报错交由人工处理，不自行删除 ==\n'
    new_case
    export FAKE_CSV_PHASE="Failed" FAKE_SUBSCRIPTION=1
    run_install
    check_eq "返回码 1" "$LAST_RC" "1"
    check_contains "提示状态异常" "$LAST_OUTPUT" "存在但状态不是 Succeeded"
    check_not_contains "未删除 CSV" "$(cat "$FAKE_LOG")" "delete csv"
    check_not_contains "未删除 Subscription" "$(cat "$FAKE_LOG")" "delete subscription"
}

test_intermediate_phase_never_converges() {
    printf '\n== 重入：CSV 长期停在中间态 —— 等待超时后报错 ==\n'
    new_case
    export FAKE_CSV_PHASE="Installing"
    run_install
    check_eq "返回码 1" "$LAST_RC" "1"
    check_contains "提示状态异常" "$LAST_OUTPUT" "存在但状态不是 Succeeded"
    check_not_contains "未删除 CSV" "$(cat "$FAKE_LOG")" "delete csv"
}

test_installplan_timeout() {
    printf '\n== 全新安装时等不到挂起的 InstallPlan —— 失败 ==\n'
    new_case
    export FAKE_INSTALLPLAN_PENDING=0
    run_install
    check_eq "返回码 1" "$LAST_RC" "1"
    check_contains "报等待超时" "$LAST_OUTPUT" "等待 InstallPlan 超时"
}

test_errexit_safe_when_called_bare() {
    printf '\n== set -e 下裸调用（mesh project.sh 的调用方式）不应中断脚本 ==\n'
    new_case
    export FAKE_CSV_PHASE="Succeeded" FAKE_SUBSCRIPTION=1
    local out rc=0
    out=$(bash -c '
        set -e
        source "$FRAMEWORK_ROOT/framework/common.sh"
        source "$FRAMEWORK_ROOT/framework/verify.sh"
        install_operator "opentelemetry-operator2" "opentelemetry-operator2" "'"$PKG_URL"'" "install-otel"
        echo "AFTER_INSTALL_OPERATOR"
    ' 2>&1) || rc=$?
    check_eq "返回码 0" "$rc" "0"
    check_contains "跳过安装后脚本继续执行" "$out" "AFTER_INSTALL_OPERATOR"
}

test_fresh_install
test_already_installed
test_installed_without_subscription
test_intermediate_phase_converges
test_failed_csv
test_intermediate_phase_never_converges
test_installplan_timeout
test_errexit_safe_when_called_bare

printf '\n==================== 结果 ====================\n'
printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
rm -rf "$FAKE_BIN"
[ "$T_FAIL" -eq 0 ]
