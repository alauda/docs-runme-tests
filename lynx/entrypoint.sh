#!/usr/bin/env bash
# 镜像入口（lynx TestTemplate 里写 command: docs-test）
#
# 用法: docs-test <init|mesh|otel|tracing>
#   init    —— 每个业务集群跑一次的前置：拉 kubeconfig、装集群插件与 servicemesh-operator2、
#              用本 region 的 $GLOBAL_EXTERNAL_IPPOOL 建 MetalLB 地址池（owner=init）
#   mesh    —— ./run-mesh-all.sh
#   otel    —— ./run-otel-all.sh
#   tracing —— ./run-tracing-all.sh
#
# 无论编排怎么退出，都保证 $TEST_RESULT_DIR 下有一份 allure 报告：空的 allure 目录
# 会让 lynx 的 summaryResult 变成 NUL，比一条明确的 broken 用例难排查得多。
set -uo pipefail

FRAMEWORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FRAMEWORK_ROOT
cd "$FRAMEWORK_ROOT"

# 与 run.sh 相同的加载顺序（init 模式要直接调用 setup_external_ip_pools）
# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/report.sh"
source "$FRAMEWORK_ROOT/framework/acp-auth.sh"
source "$FRAMEWORK_ROOT/framework/kubeconfig.sh"
source "$FRAMEWORK_ROOT/framework/tools.sh"
source "$FRAMEWORK_ROOT/framework/assets.sh"
source "$FRAMEWORK_ROOT/lynx/env-adapter.sh"

export PATH="$FRAMEWORK_ROOT/bin:$PATH"

lynx_adapt_env

MODE="${1:-}"
case "$MODE" in
    init|mesh|otel|tracing) ;;
    *)
        log_error "用法: docs-test <init|mesh|otel|tracing>"
        exit 1
        ;;
esac

# 兜底：编排异常中断时也要留下可解析的 allure 报告
_emergency_report() {
    local rc=$?
    # init 模式成功退出时不需要兜底：run.sh --init-only 在 report_init 之前就
    # exit 0（见 run.sh），压根不会产生 results.jsonl / allure 相关目录，这是
    # 该模式的正常形态，不是「异常中断」。不加这条判断的话，init 每次成功都会
    # 被这里误判成异常、补一条 broken 占位用例——若 lynx 把 initials 与 tests
    # 挂到同一个 TEST_RESULT_DIR（共享 PVC），这条 broken 会被后续测试项的
    # allure generate 收进报告，变成一条指向错误方向的红。
    # 注意只放行 rc=0：init 真失败时仍要走下面的兜底，不能把故障也一起吞掉。
    if [ "$MODE" = "init" ] && [ "$rc" -eq 0 ]; then
        return 0
    fi
    if [ -d "${TEST_RESULT_DIR:-/nonexistent}/allure-report" ]; then
        return 0
    fi
    log_warn "未产出 allure 报告（docs-test $MODE 退出码 $rc），生成占位报告"
    allure_emit_broken       "$TEST_RESULT_DIR/allure-result" "docs-test $MODE 异常退出，退出码 $rc" || true
    allure_write_environment "$TEST_RESULT_DIR/allure-result" || true
    allure_write_categories  "$TEST_RESULT_DIR/allure-result" || true
    allure_generate          "$TEST_RESULT_DIR/allure-result" "$TEST_RESULT_DIR/allure-report" || true
}
trap _emergency_report EXIT

if [ "$MODE" = "init" ]; then
    if [ -z "${SINGLE_CLUSTER_NAME:-}" ]; then
        log_error "init 模式需要 REGION_NAME（或 SINGLE_CLUSTER_NAME）指定目标业务集群"
        exit 1
    fi
    log_header "docs-test init：初始化业务集群 $SINGLE_CLUSTER_NAME"
    ./run.sh --project mesh --init-only --cluster "$SINGLE_CLUSTER_NAME" || exit 1
    # 地址池由 init 拥有：长期存在，供后续三个测试项复用，测试脚本不会清理它
    EXTERNAL_IP_POOL_OWNER=init setup_external_ip_pools "$SINGLE_CLUSTER_NAME" || exit 1
    log_success "docs-test init 完成: $SINGLE_CLUSTER_NAME"
    exit 0
fi

log_header "docs-test $MODE：CASE_TYPE='${CASE_TYPE:-<未设置，全选>}'"
"./run-${MODE}-all.sh"
exit $?
