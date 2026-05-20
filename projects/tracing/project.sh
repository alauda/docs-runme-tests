#!/usr/bin/env bash
# tracing 项目专属逻辑（Alauda Distributed Tracing 文档测试）
#
# 由 run.sh 引擎在 source framework/{common,verify,kubeconfig,tools}.sh 之后加载。

# ==============================================================================
# 项目钩子（由 run.sh 引擎调用）
# ==============================================================================

# 校验 tracing 项目专属环境变量
project_check_env() {
    if [ -z "$PKG_OPENTELEMETRY_OPERATOR2_URL" ]; then
        log_error "tracing 项目缺少必要的环境变量: PKG_OPENTELEMETRY_OPERATOR2_URL"
        return 1
    fi
    # Elasticsearch 依赖为软检查：缺失时测试脚本会以 SKIPPED 退出，不在此阻断
    if [ -z "${TRACING_ES_ENDPOINT:-}" ] || [ -z "${TRACING_ES_USER:-}" ] || [ -z "${TRACING_ES_PASS:-}" ]; then
        log_warn "未设置 TRACING_ES_ENDPOINT/USER/PASS，分布式调用链测试将以 SKIPPED 退出"
    fi
    return 0
}

# tracing 重量级初始化（仅 --init-only / --force-init 时调用）
# 通用工具（runme/violet）已由引擎安装；此处负责 kubeconfig 与 OTel Operator 插件包上传。
# OTel Operator 是分布式调用链安装的前置依赖，Operator 本身由安装测试脚本步骤 1 安装。
# 用法: project_init <cluster>...
project_init() {
    if [ $# -eq 0 ]; then
        log_error "tracing project_init: 至少需要一个集群参数"
        return 1
    fi

    local clusters=("$@")
    log_info "tracing 环境初始化（集群: ${clusters[*]}）..."

    ensure_kubeconfig "${clusters[@]}" || return 1

    # 下载并上传 OTel Operator 插件包（install_operator 依赖其 PackageManifest 存在）
    download_package "$PKG_OPENTELEMETRY_OPERATOR2_URL" || return 1
    local cluster
    for cluster in "${clusters[@]}"; do
        if ! check_package_uploaded "$cluster" "$PKG_OPENTELEMETRY_OPERATOR2_URL"; then
            upload_package "$cluster" "$PKG_OPENTELEMETRY_OPERATOR2_URL" || return 1
        fi
    done

    log_success "tracing 环境初始化完成!"
}

# tracing 轻量级准备（每次运行测试前调用）
project_prepare() {
    load_kubeconfig || return 1
    return 0
}
