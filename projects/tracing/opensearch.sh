#!/usr/bin/env bash
# tracing 项目 OpenSearch 存储后端自动安装模块（TopoLVM + OpenSearch）
#
# 背景：installing-distributed-tracing-opensearch 文档测试需要一个 OpenSearch 实例。
# 本模块在自动安装开启时（见 tracing_opensearch_auto_install_enabled），作为该测试的
# 前置步骤自动安装 TopoLVM（存储依赖）与 OpenSearch，并用实际安装结果覆盖
# TRACING_OPENSEARCH_ENDPOINT/USER/PASS（不要求用户手动设置）。
#
# 前提约束：
#   - OpenSearch 目前仅支持 ACP 离线环境；opensearch-operator 插件包需手动 violet
#     上架（下载地址为带签名的临时 URL，无法自动下载，见下方 TODO）
#   - 业务集群至少 3 个节点（OpenSearchCluster 3 副本，TopoLVM 逐节点建 VG）
#   - 各节点存在空闲磁盘设备（默认 /dev/vdb，可用 TRACING_TOPOLVM_DEVICE 覆盖）
#
# 安装步骤复刻 UI 操作（TopoLVM 仅有 UI 安装文档，无 CLI 文档；OpenSearch 离线安装
# 指引见 alauda/knowledge 仓库 OpenSearch_Installation_Guide.md）：
#   TopoLVM:    acp-storage-operator(Manual 审批) → topolvm-operator → TopolvmCluster → StorageClass
#   OpenSearch: opensearch-operator → OpenSearchCluster（含 dashboards）
#
# 由 projects/tracing/project.sh source；operator 安装复用 framework/common.sh 的
# install_operator_cli（纯 kubectl，不依赖文档 runme 块）。

# ==============================================================================
# 可覆盖配置（默认值与已验证环境一致）
# ==============================================================================

# 是否自动安装 OpenSearch（默认 true；设为 false 时完全走手动 TRACING_OPENSEARCH_* 配置）
TRACING_INSTALL_OPENSEARCH="${TRACING_INSTALL_OPENSEARCH:-true}"
# TopolvmCluster 各节点使用的磁盘设备（需为无分区/无文件系统的空闲块设备）
TRACING_TOPOLVM_DEVICE="${TRACING_TOPOLVM_DEVICE:-/dev/vdb}"
# 存储类名（贯穿 TopolvmCluster deviceClass / StorageClass / OpenSearchCluster PVC）
TRACING_TOPOLVM_STORAGECLASS="${TRACING_TOPOLVM_STORAGECLASS:-sc-topolvm}"
# TopolvmCluster spec.topolvmVersion（UI 安装的默认值；实测 operator 会将实际镜像
# 改写为平台仓库地址，该字段值不影响离线环境的镜像拉取）
TRACING_TOPOLVM_IMAGE="${TRACING_TOPOLVM_IMAGE:-build-harbor.alauda.cn/acp/topolvm:v3.8.1}"
# OpenSearch 实例位置与版本
TRACING_OPENSEARCH_NS="${TRACING_OPENSEARCH_NS:-opensearch-demo}"
TRACING_OPENSEARCH_NAME="${TRACING_OPENSEARCH_NAME:-my-opensearch}"
TRACING_OPENSEARCH_VERSION="${TRACING_OPENSEARCH_VERSION:-3.3.1}"
TRACING_OPENSEARCH_DASHBOARDS_VERSION="${TRACING_OPENSEARCH_DASHBOARDS_VERSION:-3.3.0}"

# ==============================================================================
# 判定函数
# ==============================================================================

# 自动安装是否可用：开关开启且 TopoLVM 两个插件包地址齐全。
# PKG URL 为软依赖：缺失时由调用方（测试脚本步骤 0）决定降级走手动配置或跳过，
# 与 project.sh 既有"存储后端软依赖"的约定一致，避免默认开启破坏未配置的环境。
tracing_opensearch_auto_install_enabled() {
    [ "$TRACING_INSTALL_OPENSEARCH" = "true" ] \
        && [ -n "${PKG_ACP_STORAGE_OPERATOR_URL:-}" ] \
        && [ -n "${PKG_TOPOLVM_OPERATOR_URL:-}" ]
}

# 前置校验：业务集群节点数 >= 3
_tracing_opensearch_precheck() {
    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${node_count:-0}" -lt 3 ]; then
        log_error "OpenSearch 自动安装要求业务集群至少 3 个节点，当前: ${node_count:-0}"
        return 1
    fi
    log_info "节点数校验通过: $node_count 个节点"
    return 0
}

# ==============================================================================
# TopoLVM 安装（OpenSearch 的存储依赖）
# ==============================================================================

# 内联渲染 TopolvmCluster（逐字段对齐 UI 安装请求；节点列表由参数传入）
# 用法: _tracing_render_topolvmcluster <node>...
_tracing_render_topolvmcluster() {
    cat <<EOF
apiVersion: topolvm.cybozu.com/v2
kind: TopolvmCluster
metadata:
  name: topolvm
  namespace: nativestor-system
spec:
  topolvmVersion: ${TRACING_TOPOLVM_IMAGE}
  storage:
    useAllNodes: false
    useAllDevices: false
    useLoop: false
    deviceClasses:
EOF
    local node
    for node in "$@"; do
        cat <<EOF
      - nodeName: "${node}"
        classes:
          - className: ${TRACING_TOPOLVM_STORAGECLASS}
            default: true
            devices:
              - name: ${TRACING_TOPOLVM_DEVICE}
                type: disk
            thinPoolConfig:
              overprovisionRatio: 2
              sizePercent: 90
              metadataSizeCalculationPolicy: Host
              chunkSizeCalculationPolicy: Static
EOF
    done
}

# 内联渲染 StorageClass（同 UI 安装请求：xfs、支持快照/扩容、共享给所有项目）
_tracing_render_topolvm_storageclass() {
    cat <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${TRACING_TOPOLVM_STORAGECLASS}
  annotations:
    cpaas.io/display-name: ""
    cpaas.io/features: "snapshot,expansion"
  labels:
    topolvm.storageclass: "default"
    project.cpaas.io/ALL_ALL: "true"
provisioner: topolvm.cybozu.com
parameters:
  csi.storage.k8s.io/fstype: xfs
  topolvm.cybozu.com/device-class: ${TRACING_TOPOLVM_STORAGECLASS}
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
}

# 安装 TopoLVM 链：acp-storage-operator(Manual) → topolvm-operator → TopolvmCluster → StorageClass
# 全流程幂等，可重复调用
_tracing_install_topolvm() {
    log_header "安装 TopoLVM（OpenSearch 存储依赖）"

    # 1. Alauda Container Platform Storage Essentials（UI 安装为 Manual 审批，函数内自动批准）
    install_operator_cli acp-storage-operator acp-storage stable Manual || return 1

    # 2. Alauda Build of TopoLVM
    install_operator_cli topolvm-operator nativestor-system alpha Automatic || return 1

    # 3. 创建 TopolvmCluster（已存在则跳过；每个节点用同一空闲设备建 deviceClass）
    if kubectl -n nativestor-system get topolvmcluster topolvm >/dev/null 2>&1; then
        log_info "TopolvmCluster topolvm 已存在，跳过创建"
    else
        local nodes=()
        local node_line
        while IFS= read -r node_line; do
            [ -n "$node_line" ] && nodes+=("$node_line")
        done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
        if [ ${#nodes[@]} -eq 0 ]; then
            log_error "未获取到节点列表，无法创建 TopolvmCluster"
            return 1
        fi
        log_info "创建 TopolvmCluster (节点: ${nodes[*]}, 设备: $TRACING_TOPOLVM_DEVICE)"
        local cluster_yaml
        cluster_yaml=$(_tracing_render_topolvmcluster "${nodes[@]}")
        printf '%s\n' "$cluster_yaml" | kubectl apply -f - || {
            log_error "创建 TopolvmCluster 失败"
            return 1
        }
    fi

    # 4. 等待 TopolvmCluster 就绪（各节点建 VG + CSI 组件拉起需数分钟）
    log_info "等待 TopolvmCluster 就绪 (.status.phase=Ready)"
    local attempt phase=""
    for ((attempt=1; attempt<=60; attempt++)); do
        phase=$(kubectl -n nativestor-system get topolvmcluster topolvm \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$phase" = "Ready" ]; then
            log_success "TopolvmCluster 已就绪"
            break
        fi
        log_warn "等待 TopolvmCluster 就绪: phase=${phase:-<none>} (${attempt}/60)"
        [ "$attempt" -lt 60 ] && sleep 10
    done
    if [ "$phase" != "Ready" ]; then
        log_error "TopolvmCluster 未在预期时间内就绪"
        kubectl -n nativestor-system get topolvmcluster topolvm 2>/dev/null || true
        kubectl -n nativestor-system get pods 2>/dev/null || true
        return 1
    fi

    # 5. 创建 StorageClass（已存在则跳过）
    if kubectl get storageclass "$TRACING_TOPOLVM_STORAGECLASS" >/dev/null 2>&1; then
        log_info "StorageClass $TRACING_TOPOLVM_STORAGECLASS 已存在，跳过创建"
    else
        log_info "创建 StorageClass $TRACING_TOPOLVM_STORAGECLASS"
        _tracing_render_topolvm_storageclass | kubectl apply -f - || {
            log_error "创建 StorageClass 失败"
            return 1
        }
    fi

    log_success "TopoLVM 安装完成"
    return 0
}

# ==============================================================================
# OpenSearch 安装
# ==============================================================================

# 内联渲染 OpenSearchCluster（同 OpenSearch_Installation_Guide.md 的安装 yaml，
# 存储类与版本参数化；TLS 自动生成，dashboards 一并启用）
_tracing_render_opensearchcluster() {
    cat <<EOF
apiVersion: opensearch.opster.io/v1
kind: OpenSearchCluster
metadata:
  name: ${TRACING_OPENSEARCH_NAME}
  namespace: ${TRACING_OPENSEARCH_NS}
spec:
  general:
    serviceName: ${TRACING_OPENSEARCH_NAME}
    version: ${TRACING_OPENSEARCH_VERSION}
    httpPort: 9200
  security:
    tls:
      transport:
        generate: true
        perNode: true
      http:
        generate: true
  dashboards:
    enable: true
    version: ${TRACING_OPENSEARCH_DASHBOARDS_VERSION}
    replicas: 1
    resources:
      requests:
        memory: "256Mi"
        cpu: "100m"
      limits:
        memory: "512Mi"
        cpu: "200m"
  nodePools:
    - component: nodes
      replicas: 3
      diskSize: "10Gi"
      persistence:
        pvc:
          accessModes:
            - ReadWriteOnce
          storageClass: ${TRACING_TOPOLVM_STORAGECLASS}
      resources:
        requests:
          memory: "1Gi"
          cpu: "500m"
        limits:
          memory: "4Gi"
          cpu: "2"
      roles:
        - "cluster_manager"
        - "data"
EOF
}

# 安装 OpenSearch：opensearch-operator → OpenSearchCluster（等待 RUNNING + green）
# TODO: opensearch-operator 插件包目前仅支持离线环境手动 violet 上架（下载地址为带
#       签名的临时 URL，无法自动下载）。待 OpenSearch 支持在线环境后，新增
#       PKG_OPENSEARCH_OPERATOR_URL 并在 project_init 中走 download_package +
#       upload_package 自动下载上架（同 TopoLVM 两个插件包的处理方式）。
_tracing_install_opensearch_cluster() {
    log_header "安装 OpenSearch"

    # 1. Opensearch Cluster Operator（包未上架时函数内等待 PackageManifest 超时报错）
    install_operator_cli opensearch-operator opensearch-system stable Automatic || return 1

    # 2. 创建命名空间与 OpenSearchCluster（已存在则跳过）
    kubectl create namespace "$TRACING_OPENSEARCH_NS" 2>/dev/null || true
    kubectl get namespace "$TRACING_OPENSEARCH_NS" >/dev/null || {
        log_error "创建命名空间失败: $TRACING_OPENSEARCH_NS"
        return 1
    }
    if kubectl -n "$TRACING_OPENSEARCH_NS" get opensearchcluster "$TRACING_OPENSEARCH_NAME" >/dev/null 2>&1; then
        log_info "OpenSearchCluster $TRACING_OPENSEARCH_NAME 已存在，跳过创建"
    else
        log_info "创建 OpenSearchCluster ${TRACING_OPENSEARCH_NS}/${TRACING_OPENSEARCH_NAME}"
        _tracing_render_opensearchcluster | kubectl apply -f - || {
            log_error "创建 OpenSearchCluster 失败"
            return 1
        }
    fi

    # 3. 等待实例就绪（首装需起 bootstrap、逐个拉起 3 个数据节点并完成安全初始化，耗时较长）
    log_info "等待 OpenSearchCluster 就绪 (.status.phase=RUNNING 且 .status.health=green)"
    local attempt phase="" health=""
    for ((attempt=1; attempt<=80; attempt++)); do
        phase=$(kubectl -n "$TRACING_OPENSEARCH_NS" get opensearchcluster "$TRACING_OPENSEARCH_NAME" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        health=$(kubectl -n "$TRACING_OPENSEARCH_NS" get opensearchcluster "$TRACING_OPENSEARCH_NAME" \
            -o jsonpath='{.status.health}' 2>/dev/null || echo "")
        if [ "$phase" = "RUNNING" ] && [ "$health" = "green" ]; then
            log_success "OpenSearchCluster 已就绪 (phase=$phase health=$health)"
            break
        fi
        log_warn "等待 OpenSearchCluster 就绪: phase=${phase:-<none>} health=${health:-<none>} (${attempt}/80)"
        [ "$attempt" -lt 80 ] && sleep 15
    done
    if [ "$phase" != "RUNNING" ] || [ "$health" != "green" ]; then
        log_error "OpenSearchCluster 未在预期时间内就绪"
        kubectl -n "$TRACING_OPENSEARCH_NS" get opensearchcluster "$TRACING_OPENSEARCH_NAME" 2>/dev/null || true
        kubectl -n "$TRACING_OPENSEARCH_NS" get pods 2>/dev/null || true
        return 1
    fi
    return 0
}

# ==============================================================================
# 对外入口
# ==============================================================================

# 确保 OpenSearch 可用（幂等），并用实际安装结果覆盖 TRACING_OPENSEARCH_*。
# 仅供 runme-test_installing-distributed-tracing-opensearch.sh 在自动安装开启时
# 作为前置步骤调用（OpenSearch 安装只适用于该文档测试）。
tracing_ensure_opensearch() {
    log_header "OpenSearch 存储后端准备（自动安装）"

    _tracing_opensearch_precheck || return 1
    _tracing_install_topolvm || return 1
    _tracing_install_opensearch_cluster || return 1

    # 等待 operator 生成的 admin 凭据 Secret
    local secret_name="${TRACING_OPENSEARCH_NAME}-admin-password"
    log_info "读取 OpenSearch admin 凭据: ${TRACING_OPENSEARCH_NS}/${secret_name}"
    retry_command "kubectl -n $TRACING_OPENSEARCH_NS get secret $secret_name >/dev/null 2>&1" 10 5 || {
        log_error "未找到 OpenSearch admin 凭据 Secret: ${TRACING_OPENSEARCH_NS}/${secret_name}"
        return 1
    }

    local secret_json user_b64 pass_b64 os_user os_pass
    secret_json=$(kubectl -n "$TRACING_OPENSEARCH_NS" get secret "$secret_name" -o json 2>&1) || {
        log_error "获取 OpenSearch admin Secret 失败: $secret_json"
        return 1
    }
    user_b64=$(printf '%s' "$secret_json" | jq -r '.data.username // empty')
    pass_b64=$(printf '%s' "$secret_json" | jq -r '.data.password // empty')
    if [ -z "$user_b64" ] || [ -z "$pass_b64" ]; then
        log_error "OpenSearch admin Secret 缺少 username 或 password 字段"
        return 1
    fi
    os_user=$(_tracing_base64_decode "$user_b64") || { log_error "解码 username 失败"; return 1; }
    os_pass=$(_tracing_base64_decode "$pass_b64") || { log_error "解码 password 失败"; return 1; }

    # 用实际安装结果覆盖 TRACING_OPENSEARCH_*（自动安装模式下不要求用户设置，已设置的也以实际安装为准）
    if [ -n "${TRACING_OPENSEARCH_ENDPOINT:-}" ]; then
        log_warn "TRACING_OPENSEARCH_* 将被自动安装结果覆盖（原 endpoint: $TRACING_OPENSEARCH_ENDPOINT）"
    fi
    export TRACING_OPENSEARCH_ENDPOINT="https://${TRACING_OPENSEARCH_NAME}.${TRACING_OPENSEARCH_NS}.svc.cluster.local:9200"
    export TRACING_OPENSEARCH_USER="$os_user"
    export TRACING_OPENSEARCH_PASS="$os_pass"

    log_success "OpenSearch 存储后端就绪: endpoint=$TRACING_OPENSEARCH_ENDPOINT user=$os_user"
    return 0
}
