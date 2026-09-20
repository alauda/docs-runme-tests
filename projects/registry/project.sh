#!/usr/bin/env bash
# registry 项目专属逻辑（Alauda Container Platform Registry 文档测试）
#
# 由 run.sh 引擎在 source framework/{common,verify,kubeconfig,tools,assets}.sh 之后加载。
#
# ── 被测文档仓库 ──────────────────────────────────────────────────────────────
# acp-docs 的 docs/en/configure/registry/ 与 docs/en/developer/registry/。
# 测试脚本 runme-test_<doc>.sh 与对应 .mdx 同仓同目录。
#
# ── 与其他项目的差异 ──────────────────────────────────────────────────────────
# Registry 的文档测试对环境的依赖比 mesh/otel/tracing 更"底层"：
#   - 需要 image-registry-system 命名空间与 cluster-image-registry-operator
#   - Operator 包**不在全新 ACP 环境的 OperatorHub 里**，必须显式上架
#   - 组件工作负载需要平台 registry 的 pull 凭据
# 因此 project_init 会负责 Operator 包上架，测试脚本负责其余状态断言。
#
# ── 环境供给（可选）──────────────────────────────────────────────────────────
# 本文件实现了 project_provision / project_provision_cleanup，支持在没有现成 ACP
# 环境时现场造一套（见 provision.sh）。未使用该机制时这两个钩子不会被调用。

# ==============================================================================
# 项目钩子（由 run.sh 引擎调用）
# ==============================================================================

# 校验 registry 项目专属环境变量
# 注：PKG_REGISTRY_OPERATOR_URL 为可选，为空即 verify-only（Operator 包由平台预上架）。
project_check_env() {
    if [ -z "${PKG_REGISTRY_OPERATOR_URL:-}" ]; then
        log_info "未提供 PKG_REGISTRY_OPERATOR_URL，Registry Operator 进入 verify-only 模式（要求平台已预上架）"
    fi
    if [ -z "${REGISTRY_PULL_SECRET_NAME:-}" ]; then
        log_info "未提供 REGISTRY_PULL_SECRET_NAME，默认使用 global-registry-auth"
        export REGISTRY_PULL_SECRET_NAME="global-registry-auth"
    fi
    return 0
}

# registry 重量级初始化（仅 --init-only / --force-init 时调用）
# 通用工具（runme/violet）已由引擎安装；此处负责 kubeconfig 与 Registry Operator 插件包上传。
# Operator 的 Subscription/InstallPlan 由测试脚本按文档步骤执行（那正是被测内容）。
# 用法: project_init <cluster>...
project_init() {
    if [ $# -eq 0 ]; then
        log_error "registry project_init: 至少需要一个集群参数"
        return 1
    fi

    local clusters=("$@")
    local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"
    log_info "registry 环境初始化 (业务集群: ${clusters[*]} + Global 集群: ${global_cluster})..."

    # 末尾追加 Global 集群：与 mesh/otel 的 project_init 保持一致，避免跨项目交替时
    # kubeconfig fingerprint 失配触发重拉。
    ensure_kubeconfig "${clusters[@]}" "$global_cluster" || return 1

    # 下载并上传 Registry Operator 插件包。
    # 为什么必须做：全新 ACP 4.4 环境的 OperatorHub 里**没有** cluster-image-registry-operator，
    # 文档 § Install by Using YAML 第一步建 Subscription 就会被 check-subscription.cpaas.io
    # 准入 webhook 拒掉。上架后才能继续。
    # 地址为空即 verify-only：跳过，由平台预上架。
    local cluster
    if [ -n "${PKG_REGISTRY_OPERATOR_URL:-}" ]; then
        download_package "$PKG_REGISTRY_OPERATOR_URL" || return 1
        for cluster in "${clusters[@]}"; do
            if ! check_package_uploaded "$cluster" "$PKG_REGISTRY_OPERATOR_URL"; then
                upload_package "$cluster" "$PKG_REGISTRY_OPERATOR_URL" || return 1
            fi
        done
    else
        log_info "未提供 PKG_REGISTRY_OPERATOR_URL，跳过上架（verify-only）"
    fi

    log_success "registry 环境初始化完成!"
}

# registry 轻量级准备（每次运行测试前调用）
project_prepare() {
    load_kubeconfig || return 1
    return 0
}

# ==============================================================================
# 环境供给钩子（可选机制，由 provision.sh 调用；run.sh 不调用）
# ==============================================================================

# 现场造一套 ACP 环境。成功必须导出 PLATFORM_ADDRESS / PLATFORM_USERNAME / PLATFORM_PASSWORD。
# 具体实现在 provision-ctyun.sh 里（天翼云贵州3 relay 路径）。
project_provision() {
    local provider="${REGISTRY_PROVISION_PROVIDER:-ctyun}"
    local impl="${FRAMEWORK_ROOT}/projects/registry/provision-${provider}.sh"

    if [ ! -f "${impl}" ]; then
        log_error "未找到环境供给实现: ${impl}"
        log_error "可用 provider: $(ls -1 "${FRAMEWORK_ROOT}/projects/registry/" 2>/dev/null | sed -n 's/^provision-\(.*\)\.sh$/\1/p' | tr '\n' ' ')"
        return 1
    fi

    log_info "使用 provider: ${provider}"
    # shellcheck disable=SC1090
    source "${impl}"

    if ! declare -F provision_ctyun >/dev/null 2>&1; then
        log_error "${impl} 未定义 provision_ctyun()"
        return 1
    fi
    provision_ctyun
}

# 释放由 project_provision 造出来的环境
project_provision_cleanup() {
    local provider="${REGISTRY_PROVISION_PROVIDER:-ctyun}"
    local impl="${FRAMEWORK_ROOT}/projects/registry/provision-${provider}.sh"
    [ -f "${impl}" ] || return 0
    # shellcheck disable=SC1090
    source "${impl}"
    if declare -F provision_ctyun_cleanup >/dev/null 2>&1; then
        provision_ctyun_cleanup
    fi
    return 0
}
