#!/usr/bin/env bash
# tracing 项目 Elasticsearch 存储后端自动安装模块（ACP logcenter 集群插件）
#
# 背景：installing-distributed-tracing-elasticsearch 文档测试需要 ACP 日志存储
# Elasticsearch（"Alauda Container Platform Log Storage for Elasticsearch"，模块名
# logcenter）。本模块在自动安装开启时（见 tracing_es_auto_install_enabled），作为该
# 测试的前置步骤把 logcenter 集群插件安装到 TRACING_ACP_ES_CLUSTER 指定的集群
# （对应集群已安装过则跳过）；装好后仍由既有 _tracing_load_acp_es_config 从该集群的
# log-center Feature 注入 TRACING_ES_*，测试主体不感知 Elasticsearch 的安装来源。
#
# 集群插件的上架与安装模式同 framework/common.sh 的 install_cluster_plugin：
#   - 上架：violet push 到 Global 集群（集群插件只需上架 Global），平台自动创建
#     ModulePlugin / ModuleConfig
#   - 安装：在 Global 集群创建 ModuleInfo，由 cpaas.io/cluster-name 决定落地集群
# 区别在于 logcenter 需要携带 .spec.config（Single Node 模式、指定 Log/Kafka 节点、
# TTL 等），不能走 install_cluster_plugin 的默认配置安装，故本模块自渲染 ModuleInfo，
# 其余复用同组辅助函数（_wait_for_moduleconfig / _cluster_plugin_resolve_version /
# _wait_for_moduleinfo_running）。
#
# 由 projects/tracing/project.sh source。

# ==============================================================================
# 可覆盖配置（默认值与已验证环境一致）
# ==============================================================================

# 是否自动安装 Elasticsearch（默认 false；开启后安装到 TRACING_ACP_ES_CLUSTER 指定集群）
TRACING_INSTALL_ES="${TRACING_INSTALL_ES:-false}"
# Log Node / Kafka Node 所用节点（默认空 = 自动取目标集群第一个 Ready 节点；
# Single Node 模式下 Elasticsearch 与 Kafka 共用同一节点）
TRACING_ES_K8S_NODE="${TRACING_ES_K8S_NODE:-}"
# Elasticsearch 节点存储大小与 Kafka 存储大小（GB，LocalVolume 容量声明值）
TRACING_ES_NODE_STORAGE_SIZE="${TRACING_ES_NODE_STORAGE_SIZE:-200}"
TRACING_ES_KAFKA_STORAGE_SIZE="${TRACING_ES_KAFKA_STORAGE_SIZE:-10}"
# Elasticsearch 数据的宿主机路径（LocalVolume）
TRACING_ES_HOSTPATH="${TRACING_ES_HOSTPATH:-/cpaas/data/elasticsearch}"

# ==============================================================================
# 判定函数
# ==============================================================================

# 自动安装是否可用：开关开启且插件包地址非空。
# PKG_LOG_CENTER_URL 为软依赖：缺失时由调用方（测试脚本步骤 0）log_warn 后沿用
# 既有 Elasticsearch 配置逻辑，与 OpenSearch 自动安装的"存储后端软依赖"约定一致。
tracing_es_auto_install_enabled() {
    [ "$TRACING_INSTALL_ES" = "true" ] && [ -n "${PKG_LOG_CENTER_URL:-}" ]
}

# ==============================================================================
# logcenter 集群插件安装
# ==============================================================================

# 解析 Log/Kafka 节点并打印到 stdout（本函数经命令替换捕获，勿向 stdout 打日志）：
# 优先取 TRACING_ES_K8S_NODE，否则取目标集群第一个 Ready 节点
# 用法: _tracing_es_pick_node <biz_kubeconfig>
_tracing_es_pick_node() {
    local biz_kc="$1"
    if [ -n "$TRACING_ES_K8S_NODE" ]; then
        printf '%s' "$TRACING_ES_K8S_NODE"
        return 0
    fi
    local node
    node=$(KUBECONFIG="$biz_kc" kubectl get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
        | awk -F'\t' '$2=="True"{print $1; exit}')
    [ -n "$node" ] || return 1
    printf '%s' "$node"
}

# 内联渲染 logcenter ModuleInfo（Single Node 模式，逐字段对齐 UI 安装请求；
# 平台会补全其余默认字段，并按内容将 ModuleInfo 重命名为 <cluster>-<hash>）
# 用法: _tracing_render_logcenter_moduleinfo <target_cluster> <version> <node>
_tracing_render_logcenter_moduleinfo() {
    local target_cluster="$1" version="$2" node="$3"
    cat <<EOF
apiVersion: cluster.alauda.io/v1alpha1
kind: ModuleInfo
metadata:
  name: ${target_cluster}-logcenter
  labels:
    cpaas.io/cluster-name: ${target_cluster}
    cpaas.io/module-name: logcenter
    cpaas.io/module-type: plugin
spec:
  version: ${version}
  config:
    components:
      storageClassConfig:
        type: LocalVolume
      elasticsearch:
        type: single
        nodeStorageSize: ${TRACING_ES_NODE_STORAGE_SIZE}
        k8sNodes:
          - "${node}"
        hostpath: ${TRACING_ES_HOSTPATH}
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            cpu: "2"
            memory: 4Gi
      kafka:
        storageSize: ${TRACING_ES_KAFKA_STORAGE_SIZE}
        k8sNodes:
          - "${node}"
    self:
      storage:
        disabled: false
    clusterView:
      isPrivate: "true"
    ttl:
      logPlatform: 7
      logWorkload: 7
      logSystem: 7
      logKubernetes: 7
      event: 14
      audit: 14
EOF
}

# 等待目标集群的 log-center Feature 回填 Elasticsearch 访问信息（ModuleInfo Running
# 后 Feature 由平台在目标集群创建，可能滞后；_tracing_load_acp_es_config 依赖它）
# 用法: _tracing_wait_logcenter_feature <biz_kubeconfig>
_tracing_wait_logcenter_feature() {
    local biz_kc="$1"
    local attempt address
    for ((attempt=1; attempt<=30; attempt++)); do
        address=$(KUBECONFIG="$biz_kc" kubectl get features.infrastructure.alauda.io/log-center \
            -o jsonpath='{.spec.accessInfo.elasticsearch.address}' 2>/dev/null || echo "")
        if [ -n "$address" ]; then
            log_success "log-center Feature 已就绪: elasticsearch.address=$address"
            return 0
        fi
        log_warn "等待目标集群 log-center Feature 就绪 (${attempt}/30)"
        [ "$attempt" -lt 30 ] && sleep 10
    done
    log_error "log-center Feature 未在预期时间内就绪（目标集群未回填 Elasticsearch 访问信息）"
    return 1
}

# 安装 logcenter 集群插件到目标集群（幂等，可重复调用）：
# 已 Running 则跳过；未上架则 violet 上架到 Global；未安装则创建 ModuleInfo 并等待就绪
# 用法: _tracing_install_logcenter_plugin <target_cluster>
_tracing_install_logcenter_plugin() {
    local target_cluster="$1"
    local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"
    local global_kc="$KUBECONFIG_DIR/${global_cluster}.yaml"
    if [ ! -f "$global_kc" ]; then
        log_error "未找到 Global kubeconfig: $global_kc"
        log_error "请先执行 './run.sh --project tracing --init-only' 让框架拉取 ${global_cluster} 集群 kubeconfig"
        return 1
    fi

    # 目标集群 kubeconfig：选节点与等待 Feature 用（与 _tracing_load_acp_es_config 同路径，复用缓存）
    local biz_kc="${KUBECONFIG_DIR}/tracing-acp-es-${target_cluster}.yaml"
    fetch_cluster_kubeconfig "$target_cluster" "$biz_kc" || {
        log_error "获取目标集群 kubeconfig 失败: $target_cluster"
        return 1
    }

    # 集群插件资源（ModuleConfig / ModuleInfo）仅存于 Global 集群；
    # 函数内 local export KUBECONFIG，返回后自动还原，不污染调用方
    local KUBECONFIG="$global_kc"
    export KUBECONFIG

    local selector="cpaas.io/module-name=logcenter,cpaas.io/cluster-name=${target_cluster}"

    # 幂等检查：已 Running 直接跳过（平台会按内容把 ModuleInfo 重命名为 <cluster>-<hash>，
    # 故按 label 定位而非名字）
    local existing_phase existing_name
    existing_phase=$(kubectl get moduleinfo -l "$selector" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [ "$existing_phase" = "Running" ]; then
        log_success "logcenter 集群插件已安装于 ${target_cluster} (phase=Running)，跳过安装"
        _tracing_wait_logcenter_feature "$biz_kc" || return 1
        return 0
    fi
    existing_name=$(kubectl get moduleinfo -l "$selector" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    # 1. 上架插件包到 Global 集群（集群插件只需上架 Global；ModuleConfig 已存在则跳过 push）
    log_info "步骤 1: 上架 log-center 插件包到 Global 集群"
    if kubectl get moduleconfigs -l "cpaas.io/module-name=logcenter" -o name 2>/dev/null | grep -q .; then
        log_info "插件 logcenter 已上架（ModuleConfig 存在），跳过 push"
    else
        download_package "$PKG_LOG_CENTER_URL" || return 1
        upload_package "$global_cluster" "$PKG_LOG_CENTER_URL" || return 1
        # 上架成功后平台异步创建 ModulePlugin / ModuleConfig，等其出现才能解析版本
        if ! _wait_for_moduleconfig logcenter; then
            log_error "等待 ModuleConfig 超时: module-name=logcenter（上架后平台未在预期时间内创建 ModuleConfig）"
            return 1
        fi
    fi

    # 2. 仅当不存在 ModuleInfo 时才解析版本并创建；已存在则复用并等待其就绪（避免重复创建）
    if [ -n "$existing_name" ]; then
        log_info "检测到已存在的 ModuleInfo: ${existing_name} (phase=${existing_phase:-<none>})，复用并等待就绪"
    else
        local version
        version=$(_cluster_plugin_resolve_version logcenter "$PKG_LOG_CENTER_URL") || return 1
        log_success "目标版本: $version"

        local node
        node=$(_tracing_es_pick_node "$biz_kc") || {
            log_error "未能确定 Log/Kafka 节点：目标集群 $target_cluster 无 Ready 节点（或用 TRACING_ES_K8S_NODE 显式指定）"
            return 1
        }

        # 日志中变量不与全角字符相邻（macOS bash 3.2 解析 $var 紧跟多字节字符时会输出坏字节）
        log_info "步骤 2: 创建 ModuleInfo 安装 logcenter 到 ${target_cluster} (Single Node 模式, Log/Kafka 节点: ${node})"
        _tracing_render_logcenter_moduleinfo "$target_cluster" "$version" "$node" | kubectl apply -f - || {
            log_error "创建 ModuleInfo 失败"
            return 1
        }
    fi

    # 3. 等待 ModuleInfo 进入 Running（首装需部署 Elasticsearch / Kafka / ZooKeeper 等组件，放宽到 20 分钟）
    log_info "步骤 3: 等待 logcenter 集群插件安装完成 (phase=Running)"
    if ! _wait_for_moduleinfo_running logcenter "$target_cluster" 120 10; then
        log_error "logcenter 集群插件安装超时或失败"
        kubectl get moduleinfo -l "$selector" 2>/dev/null || true
        return 1
    fi

    # 4. 等待目标集群回填 log-center Feature（后续 ES 地址与凭据的读取来源）
    log_info "步骤 4: 等待目标集群 log-center Feature 就绪"
    _tracing_wait_logcenter_feature "$biz_kc" || return 1

    log_success "logcenter 集群插件安装完成 (目标集群 ${target_cluster})"
    return 0
}

# ==============================================================================
# 对外入口
# ==============================================================================

# 确保 TRACING_ACP_ES_CLUSTER 指定集群的 ACP Elasticsearch（logcenter 集群插件）
# 可用（幂等）。仅供 runme-test_installing-distributed-tracing-elasticsearch.sh 在
# 自动安装开启时作为前置步骤调用（Elasticsearch 自动安装只适用于该文档测试）；
# 装好后仍由既有 _tracing_load_acp_es_config 注入 TRACING_ES_ENDPOINT/USER/PASS。
tracing_ensure_acp_elasticsearch() {
    log_header "Elasticsearch 存储后端准备（自动安装 logcenter 集群插件）"

    local cluster="${TRACING_ACP_ES_CLUSTER:-}"
    if [ -z "$cluster" ]; then
        log_error "TRACING_INSTALL_ES=true 需要 TRACING_ACP_ES_CLUSTER 指定安装目标集群（当前为空）"
        return 1
    fi

    _tracing_install_logcenter_plugin "$cluster" || return 1

    log_success "Elasticsearch 存储后端就绪 (cluster=$cluster)"
    return 0
}
