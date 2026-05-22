#!/usr/bin/env bash
# tracing 项目专属逻辑（Alauda Distributed Tracing 文档测试）
#
# 由 run.sh 引擎在 source framework/{common,verify,kubeconfig,tools}.sh 之后加载。

# ==============================================================================
# 项目钩子（由 run.sh 引擎调用）
# ==============================================================================

_tracing_set_default_acp_es_cluster() {
    if [ -z "${TRACING_ACP_ES_CLUSTER+x}" ]; then
        export TRACING_ACP_ES_CLUSTER="global"
    fi
}

_tracing_base64_decode() {
    local value="$1"

    if printf '%s' "$value" | base64 -d 2>/dev/null; then
        return 0
    fi
    printf '%s' "$value" | base64 -D 2>/dev/null
}

_tracing_load_acp_es_config() {
    local cluster="${TRACING_ACP_ES_CLUSTER:-}"
    if [ -z "$cluster" ]; then
        return 0
    fi

    local kubeconfig_path="${KUBECONFIG_DIR}/tracing-acp-es-${cluster}.yaml"
    fetch_cluster_kubeconfig "$cluster" "$kubeconfig_path" || {
        log_error "获取 ACP ES 集群 kubeconfig 失败: $cluster"
        return 1
    }

    local feature_json
    feature_json=$(KUBECONFIG="$kubeconfig_path" kubectl get features.infrastructure.alauda.io/log-center -o json 2>&1) || {
        log_error "获取 log-center Feature 失败: cluster=$cluster"
        log_error "kubectl 输出: $feature_json"
        return 1
    }

    local es_endpoint secret_name secret_namespace
    es_endpoint=$(printf '%s' "$feature_json" | jq -r '.spec.accessInfo.elasticsearch.address // empty')
    secret_name=$(printf '%s' "$feature_json" | jq -r '.spec.accessInfo.elasticsearch.basicAuth.secretName // empty')
    secret_namespace=$(printf '%s' "$feature_json" | jq -r '.spec.accessInfo.elasticsearch.basicAuth.secretNamespace // "cpaas-system"')
    secret_namespace="${secret_namespace:-cpaas-system}"

    if [ -z "$es_endpoint" ] || [ -z "$secret_name" ]; then
        log_error "log-center Feature 缺少 Elasticsearch 地址或 Secret 名称"
        log_error "需要字段: spec.accessInfo.elasticsearch.address / basicAuth.secretName"
        return 1
    fi

    local secret_json
    secret_json=$(KUBECONFIG="$kubeconfig_path" kubectl -n "$secret_namespace" get secret "$secret_name" -o json 2>&1) || {
        log_error "获取 Elasticsearch Secret 失败: cluster=$cluster secret=${secret_namespace}/${secret_name}"
        log_error "kubectl 输出: $secret_json"
        return 1
    }

    local username_b64 password_b64 es_user es_pass
    username_b64=$(printf '%s' "$secret_json" | jq -r '.data.username // empty')
    password_b64=$(printf '%s' "$secret_json" | jq -r '.data.password // empty')
    if [ -z "$username_b64" ] || [ -z "$password_b64" ]; then
        log_error "Elasticsearch Secret 缺少 username 或 password"
        return 1
    fi

    es_user=$(_tracing_base64_decode "$username_b64") || {
        log_error "解码 Elasticsearch username 失败"
        return 1
    }
    es_pass=$(_tracing_base64_decode "$password_b64") || {
        log_error "解码 Elasticsearch password 失败"
        return 1
    }

    export TRACING_ES_ENDPOINT="$es_endpoint"
    export TRACING_ES_USER="$es_user"
    export TRACING_ES_PASS="$es_pass"

    log_success "已从 ACP ES 配置注入 Elasticsearch 连接信息: cluster=$cluster endpoint=$es_endpoint secret=${secret_namespace}/${secret_name}"
    return 0
}

# 校验 tracing 项目专属环境变量
project_check_env() {
    _tracing_set_default_acp_es_cluster

    if [ -z "$PKG_OPENTELEMETRY_OPERATOR2_URL" ]; then
        log_error "tracing 项目缺少必要的环境变量: PKG_OPENTELEMETRY_OPERATOR2_URL"
        return 1
    fi

    if [ -n "${TRACING_ACP_ES_CLUSTER:-}" ]; then
        log_info "将从 ACP 集群自动获取 Elasticsearch 配置: TRACING_ACP_ES_CLUSTER=${TRACING_ACP_ES_CLUSTER}"
        return 0
    fi

    # Elasticsearch 依赖为软检查：缺失时测试脚本会以 SKIPPED 退出，不在此阻断
    if [ -z "${TRACING_ES_ENDPOINT:-}" ] || [ -z "${TRACING_ES_USER:-}" ] || [ -z "${TRACING_ES_PASS:-}" ]; then
        log_warn "TRACING_ACP_ES_CLUSTER 为空且未设置 TRACING_ES_ENDPOINT/USER/PASS，分布式调用链测试将以 SKIPPED 退出"
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
    local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"
    log_info "tracing 环境初始化（业务集群: ${clusters[*]} + Global 集群: ${global_cluster}）..."

    # 末尾追加 Global 集群：与 mesh project_init 保持一致，避免 mesh↔tracing 交替时
    # kubeconfig fingerprint 失配触发重拉；同时 _tracing_load_acp_es_config 读取 ACP ES
    # 配置也需要访问 Global 集群。
    ensure_kubeconfig "${clusters[@]}" "$global_cluster" || return 1

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

    _tracing_set_default_acp_es_cluster
    if [ -n "${TRACING_ACP_ES_CLUSTER:-}" ]; then
        _tracing_load_acp_es_config || return 1
    else
        log_info "TRACING_ACP_ES_CLUSTER 为空，使用 TRACING_ES_ENDPOINT/USER/PASS 配置 Elasticsearch"
    fi

    return 0
}
