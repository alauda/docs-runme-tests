#!/usr/bin/env bash
# tracing 项目 OpenSearch 存储后端自动安装模块（TopoLVM + OpenSearch）
#
# 背景：installing-distributed-tracing-opensearch 文档测试需要一个 OpenSearch 实例。
# 本模块在自动安装开启时（见 tracing_opensearch_auto_install_enabled），作为该测试的
# 前置步骤自动安装 TopoLVM（存储依赖）与 OpenSearch，并用实际安装结果覆盖
# TRACING_OPENSEARCH_ENDPOINT/USER/PASS（不要求用户手动设置）。
#
# 前提约束：
#   - 业务集群至少 3 个节点（OpenSearchCluster 3 副本，TopoLVM 逐节点建 VG）
#   - 各节点存在空闲磁盘设备（默认 /dev/vdb，可用 TRACING_TOPOLVM_DEVICE 覆盖）
#
# 三个插件包（acp-storage-operator / topolvm-operator / opensearch-operator）都由
# _tracing_prepare_opensearch_packages 按需下载并 violet 上架到业务集群；地址留空即
# verify-only（要求平台已预上架），与框架其余 PKG_*_URL 的约定一致。
#
# 安装步骤复刻 UI 操作（TopoLVM 仅有 UI 安装文档，无 CLI 文档；OpenSearch 离线安装
# 指引见 alauda/knowledge 仓库 OpenSearch_Installation_Guide.md）：
#   TopoLVM:    acp-storage-operator(Manual 审批) → topolvm-operator → TopolvmCluster → StorageClass
#   OpenSearch: opensearch-operator → OpenSearchCluster（含 dashboards）
#   Ingress:    HTTP API (9200) 与 Dashboards (5601) 各一条，均以 /clusters/<集群名>/... 子路径暴露
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
# 版本需与插件包内置的镜像 tag 对应（离线环境只有包里带的那几个 tag）：
# opensearch-operator v2.8.0 随包发布 opensearch / opensearch-dashboards 的 3.7.0 与 2.19.6，
# 取其中较新的 3.7.0
TRACING_OPENSEARCH_VERSION="${TRACING_OPENSEARCH_VERSION:-3.7.0}"
TRACING_OPENSEARCH_DASHBOARDS_VERSION="${TRACING_OPENSEARCH_DASHBOARDS_VERSION:-3.7.0}"
# opensearch-operator 的安装命名空间与订阅 channel。命名空间默认取 CSV 的
# operatorframework.io/suggested-namespace（即 UI 安装的落点），与 UI 装出来的实例
# 互相幂等；channel 留空则由 install_operator_cli 取 PackageManifest 的 defaultChannel
# （v2.8.0 的包只有 alpha 一条 channel，写死 stable 会解析不到 startingCSV）
TRACING_OPENSEARCH_OPERATOR_NS="${TRACING_OPENSEARCH_OPERATOR_NS:-opensearch-operator}"
TRACING_OPENSEARCH_OPERATOR_CHANNEL="${TRACING_OPENSEARCH_OPERATOR_CHANNEL:-}"
# Dashboards 经 Ingress 暴露的访问路径（留空则自动派生
# /clusters/<集群名>/opensearch-dashboards，与 Jaeger UI 的 basepath 模式一致）
TRACING_OPENSEARCH_DASHBOARDS_BASEPATH="${TRACING_OPENSEARCH_DASHBOARDS_BASEPATH:-}"
# OpenSearch HTTP API (9200) 经 Ingress 暴露的访问路径（留空则自动派生
# /clusters/<集群名>/opensearch）；TRACING_OPENSEARCH_ENDPOINT 即平台地址 + 该路径
TRACING_OPENSEARCH_BASEPATH="${TRACING_OPENSEARCH_BASEPATH:-}"

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

# 按需下载并上架单个插件包到当前业务集群（幂等）。
# 先查 ArtifactVersion 再决定要不要下载：opensearch-operator 的包有 3GB 级别，
# 已上架时白下一遍既慢又占磁盘（download_package 只按文件名缓存，不看是否已上架）。
# 用法: _tracing_upload_package_if_needed <cluster> <package_url>
_tracing_upload_package_if_needed() {
    local cluster="$1" pkg_url="$2"

    if check_package_uploaded "$cluster" "$pkg_url"; then
        log_info "插件包已上架，跳过下载上架: $(basename "$pkg_url")"
        return 0
    fi
    download_package "$pkg_url" || return 1
    upload_package "$cluster" "$pkg_url" || return 1
    return 0
}

# 准备插件包（原属 project_init，挪到测试步骤 0 内闭环：仅 OpenSearch 安装测试
# 需要这些包，测试 ES 等场景不应连带下载上架）。
# 三个包都上架到当前业务集群（Operator 包按集群上架，不同于集群插件只上架 Global）：
#   - acp-storage-operator / topolvm-operator：TopoLVM 存储链
#   - opensearch-operator：OpenSearch 本体
# 每个包的地址留空即 verify-only：不下载不上架，改为校验它已在本集群上架，
# 未上架则报错退出并给出排查方向（同 jaeger 集群插件的 verify-only 处理）。
_tracing_prepare_opensearch_packages() {
    local cluster
    cluster=$(kubectl config current-context 2>/dev/null)
    if [ -z "$cluster" ]; then
        log_error "无法确定当前业务集群 (kubectl config current-context 为空)"
        return 1
    fi

    log_info "准备 OpenSearch 相关插件包 (集群 ${cluster})..."

    # entry 形如 "<PackageManifest 名>|<插件包地址>"：地址非空则下载上架，
    # 为空则退回按 PackageManifest 校验是否已预上架
    local entry pm_name pkg_url
    for entry in \
        "acp-storage-operator|${PKG_ACP_STORAGE_OPERATOR_URL:-}" \
        "topolvm-operator|${PKG_TOPOLVM_OPERATOR_URL:-}" \
        "opensearch-operator|${PKG_OPENSEARCH_OPERATOR_URL:-}"; do
        pm_name="${entry%%|*}"
        pkg_url="${entry#*|}"

        if [ -n "$pkg_url" ]; then
            _tracing_upload_package_if_needed "$cluster" "$pkg_url" || return 1
            continue
        fi

        if kubectl get packagemanifest "$pm_name" >/dev/null 2>&1; then
            log_info "插件 ${pm_name} 已上架到集群 ${cluster}（verify-only）"
            continue
        fi
        # 变量名转大写拼出对应的 PKG_*_URL，提示里直接给出要设的变量
        local pkg_var
        pkg_var="PKG_$(printf '%s' "$pm_name" | tr 'a-z-' 'A-Z_')_URL"
        log_error "集群 ${cluster} 未上架插件 ${pm_name}，且未提供 ${pkg_var}（verify-only 模式）"
        log_error "- dailybuild：确认 release-config 的 Release YAML 已声明该插件包"
        log_error "- 本地：export ${pkg_var}=<包地址>"
        return 1
    done
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

# 解析 dashboards 访问路径并打印到 stdout（本函数经命令替换捕获，勿向 stdout 打日志）：
# 优先取 TRACING_OPENSEARCH_DASHBOARDS_BASEPATH，否则按 Jaeger UI 的模式从
# kube-public/global-info 派生 /clusters/<集群名>/opensearch-dashboards
_tracing_dashboards_basepath() {
    if [ -n "$TRACING_OPENSEARCH_DASHBOARDS_BASEPATH" ]; then
        printf '%s' "$TRACING_OPENSEARCH_DASHBOARDS_BASEPATH"
        return 0
    fi
    local cluster_name
    cluster_name=$(kubectl -nkube-public get configmap global-info \
        -o jsonpath='{.data.clusterName}' 2>/dev/null)
    [ -n "$cluster_name" ] || return 1
    printf '/clusters/%s/opensearch-dashboards' "$cluster_name"
}

# 解析 OpenSearch HTTP API 访问路径并打印到 stdout（本函数经命令替换捕获，勿向 stdout 打日志）：
# 优先取 TRACING_OPENSEARCH_BASEPATH，否则同 dashboards 派生 /clusters/<集群名>/opensearch
_tracing_opensearch_basepath() {
    if [ -n "$TRACING_OPENSEARCH_BASEPATH" ]; then
        printf '%s' "$TRACING_OPENSEARCH_BASEPATH"
        return 0
    fi
    local cluster_name
    cluster_name=$(kubectl -nkube-public get configmap global-info \
        -o jsonpath='{.data.clusterName}' 2>/dev/null)
    [ -n "$cluster_name" ] || return 1
    printf '/clusters/%s/opensearch' "$cluster_name"
}

# 拼出 OpenSearch 经 Ingress 暴露的访问地址并打印到 stdout（同 Jaeger UI 的访问方式：
# 平台地址 + /clusters/<集群名>/<子路径>，由平台转发到本集群的系统 Ingress 控制器）。
# 本函数经命令替换捕获，勿向 stdout 打日志。
_tracing_opensearch_endpoint() {
    local platform_url basepath
    platform_url=$(kubectl -nkube-public get configmap global-info \
        -o jsonpath='{.data.platformURL}' 2>/dev/null)
    [ -n "$platform_url" ] || return 1
    basepath=$(_tracing_opensearch_basepath) || return 1
    printf '%s%s' "${platform_url%/}" "$basepath"
}

# 内联渲染 OpenSearchCluster（同 OpenSearch_Installation_Guide.md 的安装 yaml，
# 存储类与版本参数化；TLS 自动生成，dashboards 一并启用）。
# dashboards.basePath 使 operator 下发 server.basePath/server.rewriteBasePath 配置，
# dashboards 才能在 Ingress 子路径下正确服务（见 _tracing_install_dashboards_ingress）。
# 用法: _tracing_render_opensearchcluster <dashboards_basepath>
_tracing_render_opensearchcluster() {
    local dashboards_basepath="$1"
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
    basePath: ${dashboards_basepath}
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

# 解析 opensearch-operator 的安装命名空间并打印到 stdout（本函数经命令替换捕获，
# 勿向 stdout 打日志）：已装过就沿用它所在的命名空间，否则用 TRACING_OPENSEARCH_OPERATOR_NS。
# install_operator_cli 的幂等判断只看指定命名空间，不认这一条会在换过默认命名空间的
# 环境上再装一套 operator，两套 operator 同时 reconcile 同一批 OpenSearchCluster。
_tracing_opensearch_operator_ns() {
    local existing_ns
    existing_ns=$(kubectl get subscription --all-namespaces \
        -o jsonpath='{range .items[?(@.spec.name=="opensearch-operator")]}{.metadata.namespace}{"\n"}{end}' \
        2>/dev/null | head -n 1)
    if [ -n "$existing_ns" ]; then
        printf '%s' "$existing_ns"
        return 0
    fi
    printf '%s' "$TRACING_OPENSEARCH_OPERATOR_NS"
}

# 安装 OpenSearch：opensearch-operator → OpenSearchCluster（等待 RUNNING + green）
# 插件包由 _tracing_prepare_opensearch_packages 提前下载上架，这里只管安装。
_tracing_install_opensearch_cluster() {
    log_header "安装 OpenSearch"

    # 1. Opensearch Cluster Operator（channel 留空则取 PackageManifest 的 defaultChannel）
    local operator_ns
    operator_ns=$(_tracing_opensearch_operator_ns)
    if [ "$operator_ns" != "$TRACING_OPENSEARCH_OPERATOR_NS" ]; then
        log_info "沿用已存在的 opensearch-operator 命名空间: ${operator_ns}"
    fi
    install_operator_cli opensearch-operator "$operator_ns" \
        "$TRACING_OPENSEARCH_OPERATOR_CHANNEL" Automatic || return 1

    # 2. 创建命名空间与 OpenSearchCluster（已存在则跳过）
    kubectl create namespace "$TRACING_OPENSEARCH_NS" 2>/dev/null || true
    kubectl get namespace "$TRACING_OPENSEARCH_NS" >/dev/null || {
        log_error "创建命名空间失败: $TRACING_OPENSEARCH_NS"
        return 1
    }
    # 命名空间归属 cpaas-system 项目（与 istio-system 一致）：系统 Ingress 控制器
    # 只服务归属其项目的命名空间，无项目标签时 Dashboards Ingress 不会被接管
    kubectl label namespace "$TRACING_OPENSEARCH_NS" "cpaas.io/project=cpaas-system" --overwrite >/dev/null || {
        log_error "标记命名空间项目归属失败: $TRACING_OPENSEARCH_NS"
        return 1
    }
    if kubectl -n "$TRACING_OPENSEARCH_NS" get opensearchcluster "$TRACING_OPENSEARCH_NAME" >/dev/null 2>&1; then
        log_info "OpenSearchCluster $TRACING_OPENSEARCH_NAME 已存在，跳过创建"
    else
        local dashboards_basepath
        dashboards_basepath=$(_tracing_dashboards_basepath) || {
            log_error "未能派生 dashboards 访问路径（读取 kube-public/global-info 的 clusterName 失败）"
            return 1
        }
        log_info "创建 OpenSearchCluster ${TRACING_OPENSEARCH_NS}/${TRACING_OPENSEARCH_NAME}"
        _tracing_render_opensearchcluster "$dashboards_basepath" | kubectl apply -f - || {
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

# 内联渲染 OpenSearch HTTP API Ingress（子路径模式同 Dashboards Ingress，差异在于
# OpenSearch 自身不支持 basePath：子路径前缀必须由 Ingress 控制器改写掉再转给后端，
# 故用 ingress-nginx 标准捕获组写法 <basepath>(/|$)(.*) + rewrite-target /$2；
# 后端 9200 由 OpenSearchCluster 的 security.tls.http 开了 TLS，需声明 HTTPS 回源。
# use-regex 仅 ingress-nginx 需要，ALB 按路径是否含正则字符自动判定、忽略该注解）
# 用法: _tracing_render_opensearch_ingress <ingress_class> <basepath>
_tracing_render_opensearch_ingress() {
    local ingress_class="$1" basepath="$2"
    cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${TRACING_OPENSEARCH_NAME}
  namespace: ${TRACING_OPENSEARCH_NS}
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/rewrite-target: /\$2
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: ${ingress_class}
  rules:
    - http:
        paths:
          - path: ${basepath}(/|\$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: ${TRACING_OPENSEARCH_NAME}
                port:
                  number: 9200
EOF
}

# 通过 Ingress 暴露 OpenSearch HTTP API（幂等，可重复调用）：创建 Ingress（已存在跳过）
# 并等待地址就绪。暴露后 TRACING_OPENSEARCH_ENDPOINT 用该地址而非集群内 svc 域名——
# 文档步骤里的 curl 在测试执行机上跑，集群外解析不到 *.svc.cluster.local。
_tracing_install_opensearch_ingress() {
    log_header "暴露 OpenSearch HTTP API（Ingress）"

    local basepath ingress_class
    basepath=$(_tracing_opensearch_basepath) || {
        log_error "未能派生 OpenSearch 访问路径（读取 kube-public/global-info 的 clusterName 失败）"
        return 1
    }
    ingress_class=$(kubectl -nkube-public get configmap global-info \
        -o jsonpath='{.data.systemAlbIngressClassName}' 2>/dev/null)
    if [ -z "$ingress_class" ]; then
        log_error "未能从 kube-public/global-info 读取 systemAlbIngressClassName"
        return 1
    fi

    local ingress_name="$TRACING_OPENSEARCH_NAME"
    if kubectl -n "$TRACING_OPENSEARCH_NS" get ingress "$ingress_name" >/dev/null 2>&1; then
        log_info "Ingress $ingress_name 已存在，跳过创建"
    else
        log_info "创建 Ingress ${TRACING_OPENSEARCH_NS}/${ingress_name} (class=$ingress_class, path=$basepath)"
        _tracing_render_opensearch_ingress "$ingress_class" "$basepath" | kubectl apply -f - || {
            log_error "创建 Ingress 失败"
            return 1
        }
    fi

    # 等待 Ingress 地址就绪（同 Dashboards Ingress 的等待方式）
    kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' "ingress/$ingress_name" \
        -n "$TRACING_OPENSEARCH_NS" --timeout=180s || {
        log_error "Ingress 未在预期时间内就绪: ${TRACING_OPENSEARCH_NS}/${ingress_name}"
        log_error "请检查命名空间 $TRACING_OPENSEARCH_NS 的项目标签 (cpaas.io/project) 与 Ingress 控制器状态"
        return 1
    }
    return 0
}

# 等待经 Ingress 暴露的 OpenSearch API 真正可用：Ingress 规则下发到控制器有延迟，
# 且子路径改写配错时只有实际发请求才看得出来（后续文档步骤全靠该地址读写 OpenSearch）。
# 用法: _tracing_wait_opensearch_endpoint <endpoint> <user> <pass>
_tracing_wait_opensearch_endpoint() {
    local endpoint="$1" user="$2" pass="$3"
    local attempt code=""
    for ((attempt=1; attempt<=24; attempt++)); do
        # curl 连不上时 %{http_code} 输出 000，故不另做 || echo 兜底（会拼出两行）
        code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -u "${user}:${pass}" "${endpoint}/_cluster/health" 2>/dev/null) || true
        [ -n "$code" ] || code="000"
        if [ "$code" = "200" ]; then
            log_success "OpenSearch API 经 Ingress 可访问: ${endpoint}"
            return 0
        fi
        log_warn "等待 OpenSearch API 经 Ingress 就绪: HTTP ${code} (${attempt}/24)"
        [ "$attempt" -lt 24 ] && sleep 5
    done
    log_error "OpenSearch API 经 Ingress 不可访问: ${endpoint}/_cluster/health (最后一次 HTTP ${code})"
    log_error "请检查 Ingress ${TRACING_OPENSEARCH_NS}/${TRACING_OPENSEARCH_NAME} 的路径改写与后端 HTTPS 回源配置"
    return 1
}

# 内联渲染 Dashboards Ingress（仿 installing 文档 Jaeger UI Ingress 的写法：
# 系统 IngressClass + 子路径路由；dashboards 自带 OpenSearch 账号登录，
# 无需 oauth2-proxy 等额外授权层，Ingress 直连 dashboards 5601 端口）
# 用法: _tracing_render_dashboards_ingress <ingress_class> <basepath>
_tracing_render_dashboards_ingress() {
    local ingress_class="$1" basepath="$2"
    cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${TRACING_OPENSEARCH_NAME}-dashboards
  namespace: ${TRACING_OPENSEARCH_NS}
  annotations:
    nginx.ingress.kubernetes.io/enable-cors: "true"
spec:
  ingressClassName: ${ingress_class}
  rules:
    - http:
        paths:
          - path: ${basepath}
            pathType: ImplementationSpecific
            backend:
              service:
                name: ${TRACING_OPENSEARCH_NAME}-dashboards
                port:
                  number: 5601
EOF
}

# 通过 Ingress 暴露 OpenSearch Dashboards（幂等，可重复调用）：
#   1. 对齐 OpenSearchCluster 的 dashboards.basePath（不一致时 patch，operator 会
#      滚动重建 dashboards Deployment，不影响 OpenSearch 数据节点）
#   2. 等待 dashboards Deployment 就绪
#   3. 创建 Ingress（已存在跳过）并等待地址就绪
_tracing_install_dashboards_ingress() {
    log_header "暴露 OpenSearch Dashboards（Ingress）"

    local basepath ingress_class
    basepath=$(_tracing_dashboards_basepath) || {
        log_error "未能派生 dashboards 访问路径（读取 kube-public/global-info 的 clusterName 失败）"
        return 1
    }
    ingress_class=$(kubectl -nkube-public get configmap global-info \
        -o jsonpath='{.data.systemAlbIngressClassName}' 2>/dev/null)
    if [ -z "$ingress_class" ]; then
        log_error "未能从 kube-public/global-info 读取 systemAlbIngressClassName"
        return 1
    fi

    # 1. 对齐 dashboards.basePath（operator 将其写入 <name>-dashboards-config ConfigMap
    #    的 opensearch_dashboards.yml：server.basePath + server.rewriteBasePath，并通过
    #    Deployment 的 checksum/dashboards.yml pod 注解触发滚动重建）
    local dashboards_deploy="${TRACING_OPENSEARCH_NAME}-dashboards"
    local dashboards_cm="${TRACING_OPENSEARCH_NAME}-dashboards-config"
    local checksum_jsonpath='{.spec.template.metadata.annotations.checksum/dashboards\.yml}'
    local current_basepath
    current_basepath=$(kubectl -n "$TRACING_OPENSEARCH_NS" get opensearchcluster "$TRACING_OPENSEARCH_NAME" \
        -o jsonpath='{.spec.dashboards.basePath}' 2>/dev/null)
    if [ "$current_basepath" = "$basepath" ]; then
        log_info "dashboards basePath 已对齐: $basepath"
    else
        local old_checksum
        old_checksum=$(kubectl -n "$TRACING_OPENSEARCH_NS" get deployment "$dashboards_deploy" \
            -o jsonpath="$checksum_jsonpath" 2>/dev/null)
        log_info "设置 dashboards basePath: ${current_basepath:-<未设置>} -> $basepath"
        kubectl -n "$TRACING_OPENSEARCH_NS" patch opensearchcluster "$TRACING_OPENSEARCH_NAME" \
            --type=merge -p "{\"spec\":{\"dashboards\":{\"basePath\":\"${basepath}\"}}}" || {
            log_error "设置 dashboards basePath 失败"
            return 1
        }
        # 等 operator 把 basePath 同步进 ConfigMap 并更新 Deployment 的 checksum 注解
        local attempt synced=""
        for ((attempt=1; attempt<=30; attempt++)); do
            local new_checksum
            new_checksum=$(kubectl -n "$TRACING_OPENSEARCH_NS" get deployment "$dashboards_deploy" \
                -o jsonpath="$checksum_jsonpath" 2>/dev/null)
            if [ "$new_checksum" != "$old_checksum" ] \
                && kubectl -n "$TRACING_OPENSEARCH_NS" get configmap "$dashboards_cm" \
                    -o jsonpath='{.data.opensearch_dashboards\.yml}' 2>/dev/null \
                    | grep -q "server.basePath: ${basepath}$"; then
                synced="yes"
                break
            fi
            log_warn "等待 dashboards Deployment 同步 basePath 配置 (${attempt}/30)"
            [ "$attempt" -lt 30 ] && sleep 5
        done
        if [ -z "$synced" ]; then
            log_error "dashboards 配置未同步 basePath（ConfigMap ${dashboards_cm} / checksum 注解未更新）"
            return 1
        fi
    fi

    # 2. 等待 dashboards Deployment 就绪（basePath 变更会触发滚动重建）
    kubectl -n "$TRACING_OPENSEARCH_NS" rollout status "deployment/$dashboards_deploy" --timeout=300s || {
        log_error "dashboards Deployment 未就绪: ${TRACING_OPENSEARCH_NS}/${dashboards_deploy}"
        return 1
    }

    # 3. 创建 Ingress（已存在则跳过）
    local ingress_name="${TRACING_OPENSEARCH_NAME}-dashboards"
    if kubectl -n "$TRACING_OPENSEARCH_NS" get ingress "$ingress_name" >/dev/null 2>&1; then
        log_info "Ingress $ingress_name 已存在，跳过创建"
    else
        log_info "创建 Ingress ${TRACING_OPENSEARCH_NS}/${ingress_name} (class=$ingress_class, path=$basepath)"
        _tracing_render_dashboards_ingress "$ingress_class" "$basepath" | kubectl apply -f - || {
            log_error "创建 Ingress 失败"
            return 1
        }
    fi

    # 4. 等待 Ingress 地址就绪（同 installing 文档 Jaeger Ingress 的等待方式）
    kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' "ingress/$ingress_name" \
        -n "$TRACING_OPENSEARCH_NS" --timeout=180s || {
        log_error "Ingress 未在预期时间内就绪: ${TRACING_OPENSEARCH_NS}/${ingress_name}"
        log_error "请检查命名空间 $TRACING_OPENSEARCH_NS 的项目标签 (cpaas.io/project) 与 Ingress 控制器状态"
        return 1
    }

    local platform_url
    platform_url=$(kubectl -nkube-public get configmap global-info \
        -o jsonpath='{.data.platformURL}' 2>/dev/null)
    log_success "OpenSearch Dashboards 已暴露: ${platform_url}${basepath} (使用 OpenSearch admin 账号登录)"
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
    _tracing_prepare_opensearch_packages || return 1
    _tracing_install_topolvm || return 1
    _tracing_install_opensearch_cluster || return 1
    _tracing_install_opensearch_ingress || return 1
    _tracing_install_dashboards_ingress || return 1

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
        # 日志中变量不与全角字符相邻（macOS bash 3.2 解析 $var 紧跟多字节字符时会输出坏字节）
        log_warn "TRACING_OPENSEARCH_* 将被自动安装结果覆盖 (原 endpoint: ${TRACING_OPENSEARCH_ENDPOINT})"
    fi
    # endpoint 用 Ingress 暴露的地址而非集群内 svc 域名：文档步骤里的 curl 在测试执行机上
    # 跑，集群外解析不到 *.svc.cluster.local；集群内的 rollover Job / Jaeger 实例走该地址
    # 同样可达。地址可用后再覆盖变量，避免把不通的地址传给后续步骤。
    local endpoint
    endpoint=$(_tracing_opensearch_endpoint) || {
        log_error "未能拼出 OpenSearch 访问地址（读取 kube-public/global-info 的 platformURL 失败）"
        return 1
    }
    _tracing_wait_opensearch_endpoint "$endpoint" "$os_user" "$os_pass" || return 1
    export TRACING_OPENSEARCH_ENDPOINT="$endpoint"
    export TRACING_OPENSEARCH_USER="$os_user"
    export TRACING_OPENSEARCH_PASS="$os_pass"

    log_success "OpenSearch 存储后端就绪: endpoint=$TRACING_OPENSEARCH_ENDPOINT user=$os_user"
    return 0
}

# ==============================================================================
# Jaeger ISM policy 相关的共享辅助函数
#
# OpenSearch 安装文档测试与 OpenSearch 升级文档测试都要处理同一套 ISM policy，
# 且两处的处理方式完全一致，故抽到本模块，两个测试脚本经 project.sh 共用。
# ==============================================================================

# 清理上一次测试遗留的 ISM policy。
# 文档给出的是全新创建场景的 PUT；OpenSearch 对已存在的 policy 直接 PUT 会返回
# version_conflict_engine_exception（409，需带 if_seq_no/if_primary_term），
# 因此重复执行前先删掉同名 policy，把环境还原成 policy 尚不存在的形态。
tracing_reset_ism_policy() {
    local code
    code=$(curl -k -sS -o /dev/null -w '%{http_code}' \
        -u "${OPENSEARCH_USER}:${OPENSEARCH_PASS}" \
        -X DELETE "${OPENSEARCH_ENDPOINT}/_plugins/_ism/policies/jaeger-ism-policy" 2>/dev/null || true)
    case "$code" in
        200) log_info "已删除遗留的 ISM policy jaeger-ism-policy" ;;
        404) log_info "ISM policy jaeger-ism-policy 不存在，无需清理" ;;
        *)   log_warn "删除 ISM policy 返回 HTTP ${code}，继续执行" ;;
    esac
    return 0
}

# 校验 ISM 是否已接管 span 写索引。
# ISM 靠后台 sweep 发现新索引（coordinator.sweep_period 默认 10 分钟，评估再叠加
# job_interval 5 分钟与 jitter），因此这里最多等 TRACING_ISM_ATTACH_RETRIES × 间隔；
# 超时只告警不失败——此时 init 建出的模板/别名已在上一步断言过，ISM 调度延迟不应判红。
tracing_verify_ism_attached() {
    local write_index
    write_index=$(curl -k -sS -u "${OPENSEARCH_USER}:${OPENSEARCH_PASS}" \
        "${OPENSEARCH_ENDPOINT}/_cat/aliases/${JAEGER_ES_INDEX_PREFIX}-jaeger-span-write?h=index,is_write_index" \
        2>/dev/null | awk '$2=="true"{print $1}' | head -n1)
    if [ -z "$write_index" ]; then
        log_error "未找到 ${JAEGER_ES_INDEX_PREFIX}-jaeger-span-write 的写索引"
        return 1
    fi
    log_info "span 写索引: ${write_index}"

    if retry_command "curl -k -sS -u '${OPENSEARCH_USER}:${OPENSEARCH_PASS}' \
            '${OPENSEARCH_ENDPOINT}/_plugins/_ism/explain/${write_index}' \
            | grep -q '\"policy_id\":\"jaeger-ism-policy\"'" \
            "${TRACING_ISM_ATTACH_RETRIES:-15}" "${TRACING_ISM_ATTACH_INTERVAL:-60}"; then
        log_success "ISM policy jaeger-ism-policy 已接管 ${write_index}"
    else
        log_warn "等待超时：${write_index} 仍未挂载 ISM policy（ISM sweep 延迟或 ism_template 不匹配），请人工复核"
    fi
    return 0
}
