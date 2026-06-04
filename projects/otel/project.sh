#!/usr/bin/env bash
# otel 项目专属逻辑（Alauda Build of OpenTelemetry v2 文档测试）
#
# 由 run.sh 引擎在 source framework/{common,verify,kubeconfig,tools}.sh 之后加载。

# ==============================================================================
# 项目钩子（由 run.sh 引擎调用）
# ==============================================================================

# 校验 otel 项目专属环境变量
project_check_env() {
    if [ -z "$PKG_OPENTELEMETRY_OPERATOR2_URL" ]; then
        log_error "otel 项目缺少必要的环境变量: PKG_OPENTELEMETRY_OPERATOR2_URL"
        return 1
    fi

    # 启用 mesh-v2-test-suite 集群插件（java-instrumentation 示例依赖）时需要其插件包地址
    if [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ] && [ -z "$PKG_MESH_V2_TEST_SUITE_URL" ]; then
        log_error "USE_MESH_V2_TEST_SUITE_PLUGIN=true 但缺少 PKG_MESH_V2_TEST_SUITE_URL"
        return 1
    fi
    return 0
}

# otel 重量级初始化（仅 --init-only / --force-init 时调用）
# 通用工具（runme/violet）已由引擎安装；此处负责 kubeconfig 与 OTel Operator 插件包上传。
# Operator 本身由测试脚本 install_operator 安装。
# 用法: project_init <cluster>...
project_init() {
    if [ $# -eq 0 ]; then
        log_error "otel project_init: 至少需要一个集群参数"
        return 1
    fi

    local clusters=("$@")
    local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"
    log_info "otel 环境初始化 (业务集群: ${clusters[*]} + Global 集群: ${global_cluster})..."

    # 末尾追加 Global 集群：与 mesh project_init 保持一致，避免跨项目交替时
    # kubeconfig fingerprint 失配触发重拉。
    ensure_kubeconfig "${clusters[@]}" "$global_cluster" || return 1

    # 下载并上传 OTel Operator 插件包（install_operator 依赖其 PackageManifest 存在）
    download_package "$PKG_OPENTELEMETRY_OPERATOR2_URL" || return 1
    local cluster
    for cluster in "${clusters[@]}"; do
        if ! check_package_uploaded "$cluster" "$PKG_OPENTELEMETRY_OPERATOR2_URL"; then
            upload_package "$cluster" "$PKG_OPENTELEMETRY_OPERATOR2_URL" || return 1
        fi
    done

    # mesh-v2-test-suite 集群插件（java-instrumentation 示例依赖），由开关控制，安装到各业务集群
    if [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ]; then
        for cluster in "${clusters[@]}"; do
            install_cluster_plugin "mesh-v2-test-suite" "$cluster" \
                "$PKG_MESH_V2_TEST_SUITE_URL" || return 1
        done
    fi

    log_success "otel 环境初始化完成!"
}

# otel 轻量级准备（每次运行测试前调用）
project_prepare() {
    load_kubeconfig || return 1
    return 0
}
