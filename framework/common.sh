#!/usr/bin/env bash
# 公共函数库

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志输出函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_header() {
    echo ""
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
    echo ""
}

# 检查必要工具是否存在
check_required_tools() {
    local missing_tools=()
    
    for tool in "$@"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "缺少必要工具: ${missing_tools[*]}"
        log_error "请安装缺少的工具后再试"
        return 1
    fi
    
    return 0
}

# 切换到指定目录执行 runme block，然后再切换回来
# 用法: kubectl_apply_runme_block <block_name> [resource_dir]
kubectl_apply_runme_block() {
    local block_name="$1"
    local resource_dir="${2:-/tmp/}"
    
    # 使用 runme print 获取命令内容
    local cmd_content
    cmd_content=$(runme print "$block_name" 2>/dev/null)

    # 使用 pushd/popd 更安全
    pushd "$resource_dir" > /dev/null || return 1
    
    if [ -z "$cmd_content" ]; then
        log_error "无法获取代码块内容: $block_name"
        popd > /dev/null || return 1
        return 1
    fi
    
    # 执行命令
    eval "$cmd_content" || {
        log_error "应用 $block_name 失败"
        popd > /dev/null || return 1
        return 1
    }
    
    popd > /dev/null || return 1
    return 0
}

# 从插件包 URL 解析出 ArtifactVersion 名称
# 用法: parse_artifact_version_from_package <package_url>
# 例如: servicemesh-operator2.stable.ALL.v2.1.0.tgz -> servicemesh-operator2.v2.1.0
parse_artifact_version_from_package() {
    local package_url="$1"
    local filename
    filename=$(basename "$package_url")
    
    # 移除 .stable/.alpha/.beta 和 .ALL/.amd64/.arm64 部分,保留版本号
    echo "$filename" | sed -E 's/\.(stable|alpha|beta)\.(ALL|amd64|arm64)\.v/\.v/' | sed 's/\.tgz$//'
}

# 从插件包 URL 解析出插件 CSV name
# 注意: 当前实现与 parse_artifact_version_from_package 逻辑相同,直接复用
parse_csv_name_from_package() {
    parse_artifact_version_from_package "$1"
}

# 文档测试脚本主动声明「跳过」：设置标记后 return 0；
# 引擎 run.sh 检测 __TEST_SKIPPED 后将该 DocTest 记为 status=skipped。
skip_test() {
    __TEST_SKIPPED=1
    __TEST_SKIP_REASON="$1"
    log_warn "SKIPPED: $1"
    return 0
}

# Wait for resource to be created
# usage: _wait_for_resource <kind> <namespace> <name>
# refer: https://github.com/istio/istio.io/blob/master/tests/util/helpers.sh#L108
_wait_for_resource() {
    local kind="$1"
    local namespace="$2"
    local name="$3"
    local start_time=$(date +%s)
    if ! kubectl wait --for=create -n "$namespace" "$kind/$name" --timeout 30s; then
        local end_time=$(date +%s)
        echo "Timed out waiting for $kind $name in namespace $namespace to be created."
        echo "Duration: $(( end_time - start_time )) seconds"
        return 1
    fi
    return 0
}

# Wait for rollout of named deployment
# usage: _wait_for_deployment <namespace> <deployment name> <optional: context>
_wait_for_deployment() {
    local namespace="$1"
    local name="$2"
    local context="${3:-}"
    if ! kubectl --context="$context" -n "$namespace" rollout status deployment "$name" --timeout 5m; then
        echo "Failed rollout of deployment $name in namespace $namespace"
        return 1
    fi
    return 0
}

# Wait for rollout of named daemonset
# usage: _wait_for_daemonset <namespace> <daemonset name> <optional: context>
_wait_for_daemonset() {
    local namespace="$1"
    local name="$2"
    local context="${3:-}"
    if ! kubectl --context="$context" -n "$namespace" rollout status daemonset "$name" --timeout 5m; then
        echo "Failed rollout of daemonset $name in namespace $namespace"
        return 1
    fi
    return 0
}

# 等待 Service 的 LoadBalancer ingress (IP 或 hostname) 就绪
# 用法: _wait_for_ingress_lb <namespace> <service> [context] [timeout]
# 说明:
#   - 通过 kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' 等待
#     ingress 字段被填充 (IP 或 hostname 均可,无需关心具体类型)
#   - context 可选,留空时使用 kubectl 当前默认 context
#   - timeout 默认 2m,可传入 30s / 5m 等 kubectl 接受的时长格式
_wait_for_ingress_lb() {
    local namespace="$1"
    local service="$2"
    local context="${3:-}"
    local timeout="${4:-2m}"

    if [ -n "$context" ]; then
        log_info "等待 LoadBalancer ingress 就绪: ns=$namespace svc=$service context=$context (timeout=$timeout)"
    else
        log_info "等待 LoadBalancer ingress 就绪: ns=$namespace svc=$service (timeout=$timeout)"
    fi

    if ! kubectl --context "$context" -n "$namespace" wait \
            --for=jsonpath='{.status.loadBalancer.ingress}' \
            "svc/$service" --timeout="$timeout"; then
        log_error "等待 LoadBalancer ingress 超时: ns=$namespace svc=$service"
        return 1
    fi
    log_success "LoadBalancer ingress 就绪: ns=$namespace svc=$service"
    return 0
}

# 创建命名空间 (容忍 AlreadyExists),并验证命名空间已就绪
# 用法: _create_namespace_safe <runme_block_name> <namespace_list> [context]
# 参数:
#   - runme_block_name: 文档中执行 `kubectl create namespace ...` 的代码块名
#   - namespace_list:   要验证的命名空间(空格分隔可传多个,如 "ns1 ns2 ns3")
#   - context:          可选,留空时使用 kubectl 当前默认 context
# 说明:
#   - 适用于"重复执行可能遇到 AlreadyExists"的场景 (如多集群多次重建)
#   - 命令本身的失败被忽略,以最终 `kubectl get ns` 是否成功作为判定依据
_create_namespace_safe() {
    local block_name="$1"
    local ns_list="$2"
    local context="${3:-}"

    if [ -z "$block_name" ] || [ -z "$ns_list" ]; then
        log_error "_create_namespace_safe: 缺少必要参数"
        log_error "用法: _create_namespace_safe <block_name> <namespace_list> [context]"
        return 1
    fi

    # 执行 runme 块,容忍 AlreadyExists 等错误
    runme run "$block_name" 2>&1 || true

    # 验证每个命名空间已存在
    local ns
    for ns in $ns_list; do
        if ! kubectl --context "$context" get namespace "$ns" >/dev/null 2>&1; then
            if [ -n "$context" ]; then
                log_error "命名空间创建失败: ns=$ns context=$context"
            else
                log_error "命名空间创建失败: ns=$ns"
            fi
            return 1
        fi
    done
    return 0
}

# 等待指定标签选择器匹配的 Pod 数达到期望值
# 用法: _wait_for_pod_count <namespace> <label_selector> <expected_count> [context] [phase] [max_retries] [interval]
_wait_for_pod_count() {
    local namespace="$1"
    local label_selector="$2"
    local expected_count="$3"
    local context="${4:-}"
    local phase="${5:-Running}"
    local max_retries="${6:-20}"
    local interval="${7:-5}"
    local kubectl_args=(kubectl)
    local attempt count

    if [ -z "$namespace" ] || [ -z "$label_selector" ] || [ -z "$expected_count" ]; then
        log_error "_wait_for_pod_count: 缺少必要参数"
        log_error "用法: _wait_for_pod_count <namespace> <label_selector> <expected_count> [context] [phase] [max_retries] [interval]"
        return 1
    fi

    [ -n "$context" ] && kubectl_args+=(--context "$context")
    kubectl_args+=(-n "$namespace" get pods -l "$label_selector")
    [ -n "$phase" ] && kubectl_args+=(--field-selector "status.phase=$phase")
    kubectl_args+=(-o name)

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        count=$("${kubectl_args[@]}" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -ge "$expected_count" ]; then
            return 0
        fi

        log_warn "等待 Pod 数达到期望值: ns=$namespace selector=$label_selector expected=$expected_count actual=$count phase=${phase:-all} (${attempt}/${max_retries})"
        [ "$attempt" -lt "$max_retries" ] && sleep "$interval"
    done

    return 1
}

# 重试执行命令
# 用法: retry_command <command> [max_retries] [interval]
retry_command() {
    local command="$1"
    local max_retries="${2:-5}"
    local interval="${3:-10}"
    local count=0
    
    while [ $count -lt $max_retries ]; do
        if eval "$command"; then
            return 0
        fi
        
        count=$((count + 1))
        if [ $count -lt $max_retries ]; then
            log_warn "命令执行失败，等待 ${interval} 秒后重试 ($((count + 1))/$max_retries)..."
            sleep "$interval"
        fi
    done
    
    log_error "命令执行失败，已重试 $max_retries 次"
    return 1
}

# 通用 operator 安装函数
# 用法: install_operator <operator_name> <namespace> <package_url> <runme_prefix>
# 参数:
#   operator_name  - operator 名称 (如 servicemesh-operator2, kiali-operator)
#   namespace      - 安装的 namespace (如 sail-operator, kiali-operator)
#   package_url    - 插件包 URL (用于解析 CSV 名称)
#   runme_prefix   - runme block 前缀 (如 install-mesh, install-kiali)
# NOTE: 调用该函数前请确保已切换到正确的 kubectl context
install_operator() {
    local operator_name="$1"
    local namespace="$2"
    local package_url="$3"
    local runme_prefix="$4"

    # 参数校验
    if [ -z "$operator_name" ] || [ -z "$namespace" ] || [ -z "$package_url" ] || [ -z "$runme_prefix" ]; then
        log_error "install_operator: 缺少必要参数"
        log_error "用法: install_operator <operator_name> <namespace> <package_url> <runme_prefix>"
        return 1
    fi

    log_info "=========================================="
    log_info "安装 $operator_name 到 namespace $namespace"
    log_info "=========================================="

    local csv_name
    csv_name=$(parse_csv_name_from_package "$package_url")

    # 检查是否已经安装
    if kubectl -n "$namespace" get csv "$csv_name" 2>/dev/null; then
        local csv_phase
        csv_phase=$(kubectl -n "$namespace" get csv "$csv_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [ "$csv_phase" = "Succeeded" ]; then
            log_success "$operator_name 已安装"
            return 0
        else
            log_error "$operator_name 存在但状态不是 Succeeded，当前状态: $csv_phase"
            return 1
        fi
    fi

    # 定义 check_packagemanifest_version 内部函数
    _check_packagemanifest_version() {
        local target_csv="$1"
        local prefix="$2"
        local versions_output
        versions_output=$(runme run "${prefix}:check-packagemanifest-versions" 2>/dev/null || echo "")

        echo "$versions_output"

        if [ -n "$versions_output" ] && echo "$versions_output" | awk '$2 == "'"$target_csv"'" { found=1 } END { exit !found }'; then
            log_success "找到匹配的版本: $target_csv"
            echo "$versions_output"
            return 0
        fi
        return 1
    }

    # 0.1 检查可用版本
    log_info "步骤 0.1: 检查可用版本"
    if ! retry_command "_check_packagemanifest_version $csv_name $runme_prefix" 20 5; then
        log_error "无法找到预期 PackageManifest 资源中的 CSV 内容: $csv_name"
        return 1
    fi

    # 0.2 确认 catalogSource
    log_info "步骤 0.2: 确认 catalogSource"
    local output expected
    output=$(runme run "${runme_prefix}:confirm-catalogsource" 2>/dev/null)
    expected=$(runme print "${runme_prefix}:confirm-catalogsource-output" 2>/dev/null)
    if ! __cmp_contains "$output" "$expected"; then
        log_error "CatalogSource 不匹配,期待: $expected, 实际: $output"
        return 1
    fi
    log_success "CatalogSource 验证通过: $output"

    # 1. 创建命名空间
    log_info "步骤 1: 创建 $namespace 命名空间"
    _create_namespace_safe "${runme_prefix}:create-namespace-${namespace}" "$namespace" || {
        log_error "创建命名空间失败"
        return 1
    }
    log_success "命名空间创建成功"

    # 2. 创建 Subscription
    log_info "步骤 2: 创建 Subscription"
    local subscription_yaml
    subscription_yaml=$(runme print "${runme_prefix}:create-subscription-${operator_name}" 2>/dev/null | \
        sed -E "s/startingCSV: ${operator_name}\\.v.+/startingCSV: $csv_name/")
    if [ -z "$subscription_yaml" ]; then
        log_error "无法获取 Subscription 模板"
        return 1
    fi
    echo "$subscription_yaml" | bash || {
        log_error "创建 Subscription 失败"
        return 1
    }
    log_success "Subscription 创建成功"

    # 3. 等待 InstallPlan 准备就绪
    log_info "步骤 3: 等待 InstallPlan 准备就绪"
    runme run "${runme_prefix}:wait-installplan-pending" || {
        log_error "等待 InstallPlan 超时"
        return 1
    }
    log_success "InstallPlan 已准备就绪"

    # 4. 批准 InstallPlan
    log_info "步骤 4: 批准 InstallPlan"
    runme run "${runme_prefix}:approve-installplan-manual" || {
        log_error "批准 InstallPlan 失败"
        return 1
    }
    log_success "InstallPlan 批准成功"

    # 等待 CSV 资源被创建
    log_info "等待 CSV 资源创建..."
    _wait_for_resource "csv" "$namespace" "$csv_name" || {
        log_warn "等待 CSV 资源创建超时,继续执行..."
    }

    # 5. 等待 CSV 安装完成
    log_info "步骤 5: 等待 CSV 安装完成"
    runme run "${runme_prefix}:wait-csv-succeeded" || {
        log_error "CSV 安装超时或失败"
        log_info "当前 CSV 状态:"
        kubectl -n "$namespace" get csv
        return 1
    }
    log_success "CSV 安装成功"

    # 6. 验证安装
    log_info "步骤 6: 验证安装"
    local csv_output
    csv_output=$(runme run "${runme_prefix}:check-csv-status" 2>/dev/null || echo "")

    if [ -n "$csv_output" ]; then
        log_success "$operator_name 安装验证通过"
        echo "$csv_output"
    else
        log_error "无法获取 CSV 状态"
        return 1
    fi

    log_success "=========================================="
    log_success "$operator_name 安装完成"
    log_success "=========================================="
    return 0
}

# ==============================================================================
# 集群插件（ACP Cluster Plugin）通用安装
#
# 与 install_operator 平级的公共函数。集群插件不同于 OLM Operator：
#   - 上架：violet push 到 Global 集群，平台自动创建 ModulePlugin / ModuleConfig
#   - 安装：在 Global 集群创建 ModuleInfo，由 cpaas.io/cluster-name 决定落地集群
# 详见 acp-docs/docs/en/extend/cluster_plugin.mdx。
# ==============================================================================

# 内联渲染 ModuleInfo（默认配置安装：不带 .spec.config、不带 affinity）
# 用法: _render_moduleinfo <module_name> <version> <target_cluster>
# 说明:
#   - 临时名 <target_cluster>-<module_name>，平台创建后会按内容重命名为 <cluster>-<hash>
#   - 按 cluster_plugin.mdx 3.1：即使 config 为空也不写 config 字段
_render_moduleinfo() {
    local module_name="$1" version="$2" target_cluster="$3"
    cat <<EOF
apiVersion: cluster.alauda.io/v1alpha1
kind: ModuleInfo
metadata:
  labels:
    cpaas.io/cluster-name: ${target_cluster}
    cpaas.io/module-name: ${module_name}
    cpaas.io/module-type: plugin
  name: ${target_cluster}-${module_name}
spec:
  version: ${version}
EOF
}

# 解析集群插件目标版本（从 Global 集群已发布的 ModuleConfig 读取）
# 用法: version=$(_cluster_plugin_resolve_version <module_name> <package_url>)
# 策略: 优先用包名解析出的 vX.Y.Z 去匹配 ModuleConfig，否则取最高版本（sort -V）
# 输出: 标准输出仅打印版本号（如 v4.0.4）；诊断信息走 log_error(stderr) 以免污染捕获
# NOTE: 依赖调用方已将 KUBECONFIG 指向 Global 集群
_cluster_plugin_resolve_version() {
    local module_name="$1"
    local package_url="$2"

    # 从包名解析期望版本（如 metallb.v4.0.4.tgz -> v4.0.4），可能为空
    local pkg_version
    pkg_version=$(basename "$package_url" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

    # 列出该 module 已发布的所有 ModuleConfig 版本（每行一个）
    local versions
    versions=$(kubectl get moduleconfigs -l "cpaas.io/module-name=${module_name}" \
        -o jsonpath='{range .items[*]}{.spec.version}{"\n"}{end}' 2>/dev/null)

    if [ -z "$versions" ]; then
        log_error "未找到 ModuleConfig (module-name=${module_name})，插件可能尚未上架完成"
        return 1
    fi

    # 包名版本存在于已发布版本中则直接采用
    if [ -n "$pkg_version" ] && echo "$versions" | grep -qx "$pkg_version"; then
        printf '%s' "$pkg_version"
        return 0
    fi

    # 否则取最高版本
    local latest
    latest=$(echo "$versions" | sort -V | tail -n 1)
    if [ -z "$latest" ]; then
        log_error "无法解析 ${module_name} 的 ModuleConfig 版本"
        return 1
    fi
    printf '%s' "$latest"
    return 0
}

# 等待集群插件的 ModuleConfig 被创建（上架 violet push 成功后，平台异步创建
# ModulePlugin / ModuleConfig，需轮询等待 ModuleConfig 出现后才能解析版本并安装）
# 用法: _wait_for_moduleconfig <module_name> [max_retries] [interval]
# NOTE: 依赖调用方已将 KUBECONFIG 指向 Global 集群
_wait_for_moduleconfig() {
    local module_name="$1"
    local max_retries="${2:-30}"
    local interval="${3:-10}"
    local attempt count

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        count=$(kubectl get moduleconfigs -l "cpaas.io/module-name=${module_name}" \
            -o name 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -gt 0 ]; then
            return 0
        fi
        log_warn "等待 ModuleConfig 创建: module-name=$module_name (${attempt}/${max_retries})"
        [ "$attempt" -lt "$max_retries" ] && sleep "$interval"
    done
    return 1
}

# 等待集群插件的 ModuleInfo 进入 Running（按 module-name + cluster-name label 定位）
# 用法: _wait_for_moduleinfo_running <module_name> <target_cluster> [max_retries] [interval]
# NOTE: 依赖调用方已将 KUBECONFIG 指向 Global 集群；状态字段为 .status.phase
_wait_for_moduleinfo_running() {
    local module_name="$1"
    local target_cluster="$2"
    local max_retries="${3:-60}"
    local interval="${4:-10}"
    local selector="cpaas.io/module-name=${module_name},cpaas.io/cluster-name=${target_cluster}"
    local attempt phase

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        phase=$(kubectl get moduleinfo -l "$selector" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [ "$phase" = "Running" ]; then
            return 0
        fi
        log_warn "等待集群插件就绪: ${module_name}@${target_cluster} phase=${phase:-<none>} (${attempt}/${max_retries})"
        [ "$attempt" -lt "$max_retries" ] && sleep "$interval"
    done
    return 1
}

# 通用集群插件安装函数（在 Global 集群上架 ACP 集群插件，并安装到目标业务集群）
# 用法: install_cluster_plugin <module_name> <target_cluster> <package_url> [prereq_package_url...]
# 参数:
#   module_name         - 集群插件名（ModulePlugin 名，如 multus / metallb / mesh-v2-test-suite）
#   target_cluster      - 插件落地的目标集群（写入 ModuleInfo 的 cpaas.io/cluster-name）
#   package_url         - 上架并安装的插件包 URL
#   prereq_package_url  - 可选，仅上架不安装的前置插件包（如 metallb 需要 metallb-operator）
# 说明:
#   - 集群插件查询、创建 ModuleInfo、主插件包上架均针对 Global 集群（ModulePlugin/ModuleConfig/ModuleInfo 仅存于 Global）
#   - 前置 operator 包（prereq_package_url）上架到目标业务集群（与其他 operator 一致）
#   - 函数内 local export KUBECONFIG 指向 Global 集群独立 kubeconfig，返回后自动还原，
#     不污染调用方 / merged.yaml 的 current-context
#   - ModuleInfo 按默认配置安装：不带 .spec.config、不带 affinity（见 cluster_plugin.mdx 3.1）
# NOTE: 依赖 Global 集群独立 kubeconfig 已生成（各项目 project_init 的 ensure_kubeconfig 会追加 Global）
install_cluster_plugin() {
    local module_name="$1"
    local target_cluster="$2"
    local package_url="$3"

    if [ -z "$module_name" ] || [ -z "$target_cluster" ] || [ -z "$package_url" ]; then
        log_error "install_cluster_plugin: 缺少必要参数"
        log_error "用法: install_cluster_plugin <module_name> <target_cluster> <package_url> [prereq_package_url...]"
        return 1
    fi
    shift 3
    local prereq_urls=("$@")

    local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"
    local global_kc="$KUBECONFIG_DIR/${global_cluster}.yaml"
    if [ ! -f "$global_kc" ]; then
        log_error "install_cluster_plugin: 未找到 Global kubeconfig: $global_kc"
        log_error "请先执行 './run.sh --project <项目> --init-only' 让框架拉取 ${global_cluster} 集群 kubeconfig"
        return 1
    fi

    # 函数内 local export KUBECONFIG，返回后自动还原，避免污染 merged.yaml 的 current-context
    local KUBECONFIG="$global_kc"
    export KUBECONFIG

    log_info "=========================================="
    log_info "安装集群插件 $module_name 到目标集群 $target_cluster (经 Global 集群 $global_cluster 操作)"
    log_info "=========================================="

    local selector="cpaas.io/module-name=${module_name},cpaas.io/cluster-name=${target_cluster}"

    # 0. 幂等检查：已 Running 直接跳过
    local existing_phase existing_name
    existing_phase=$(kubectl get moduleinfo -l "$selector" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [ "$existing_phase" = "Running" ]; then
        log_success "集群插件 $module_name 已安装于 $target_cluster (phase=Running)，跳过"
        return 0
    fi
    existing_name=$(kubectl get moduleinfo -l "$selector" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    # 1. 上架插件包（每次未就绪时都执行，确保依赖就位；violet 对已存在的包/镜像会自动跳过）。
    #    主插件包到 Global 集群，前置 operator 包到目标业务集群。
    #    即使 ModuleInfo 已存在但未就绪（如卡在 Processing），也重新确保前置 operator 已上架，
    #    使此前因依赖缺失而卡住的安装能够自愈。
    log_info "步骤 1: 上架插件包"
    local pkg
    for pkg in "$package_url" "${prereq_urls[@]}"; do
        download_package "$pkg" || return 1
    done
    # 主包：若对应 ModuleConfig 已存在则跳过 push
    if kubectl get moduleconfigs -l "cpaas.io/module-name=${module_name}" -o name 2>/dev/null | grep -q .; then
        log_info "插件 $module_name 已上架（ModuleConfig 存在），跳过 push"
    else
        upload_package "$global_cluster" "$package_url" || return 1
    fi
    # 前置包：上架到目标业务集群（与其他 operator 一致，仅上架不安装、不创建 ModuleInfo）
    for pkg in "${prereq_urls[@]}"; do
        log_info "上架前置插件包到业务集群 $target_cluster (仅上架不安装): $(basename "$pkg")"
        upload_package "$target_cluster" "$pkg" || return 1
    done

    # 2 & 3. 仅当不存在 ModuleInfo 时才解析版本并创建；已存在则复用并等待其就绪（避免重复创建）
    if [ -n "$existing_name" ]; then
        log_info "检测到已存在的 ModuleInfo: $existing_name (phase=${existing_phase:-<none>})，复用并等待就绪"
    else
        # 2. 等待 ModuleConfig 就绪并解析版本
        #    上架成功后平台需异步创建 ModulePlugin / ModuleConfig（ModuleConfig 可能滞后于
        #    ModulePlugin），故轮询等待 ModuleConfig 出现，它是版本解析与后续安装的前置。
        log_info "步骤 2: 等待 ModuleConfig (module-name=$module_name) 就绪"
        if ! _wait_for_moduleconfig "$module_name"; then
            log_error "等待 ModuleConfig 超时: module-name=$module_name (上架后平台未在预期时间内创建 ModuleConfig)"
            return 1
        fi
        local version
        version=$(_cluster_plugin_resolve_version "$module_name" "$package_url") || return 1
        log_success "目标版本: $version"

        # 3. 创建 ModuleInfo（默认配置，不带 config / affinity）
        log_info "步骤 3: 创建 ModuleInfo 安装插件到 $target_cluster"
        _render_moduleinfo "$module_name" "$version" "$target_cluster" | kubectl apply -f - || {
            log_error "创建 ModuleInfo 失败"
            return 1
        }
    fi

    # 4. 等待 ModuleInfo 进入 Running
    log_info "步骤 4: 等待集群插件安装完成 (phase=Running)"
    if ! _wait_for_moduleinfo_running "$module_name" "$target_cluster"; then
        log_error "集群插件 $module_name 安装超时或失败"
        kubectl get moduleinfo -l "$selector" 2>/dev/null || true
        return 1
    fi

    log_success "=========================================="
    log_success "集群插件 $module_name 安装完成 (目标集群 $target_cluster)"
    log_success "=========================================="
    return 0
}

# ==============================================================================
# MetalLB 外部 IP 地址池（IPAddressPool + L2Advertisement）
# ------------------------------------------------------------------------------
# 多集群网格/网关测试（run-mesh-all.sh Case 6/7）依赖 MetalLB 暴露东西向网关的
# LoadBalancer 地址。本组函数在各业务集群创建 / 校验 / 删除外部地址池，受 ENABLE_METALLB
# 门控（未开启即 no-op）。创建/删除走 kubectl（按业务集群独立 kubeconfig），可用地址检查
# 直接读 IPAddressPool 的 .status.availableIPv4 / .status.availableIPv6——创建/检查/删除
# 三者统一同一访问路径，函数内 local export KUBECONFIG，返回即还原、不污染 merged.yaml。
# 参考: acp-docs/docs/en/networking/functions/configure_metallb.mdx
# ==============================================================================

# 外部地址池所在命名空间（MetalLB 资源固定部署于此）
METALLB_NAMESPACE="${METALLB_NAMESPACE:-metallb-system}"
# 外部地址池资源名（需求固定为 mesh-v2）
METALLB_EXTERNAL_POOL_NAME="${METALLB_EXTERNAL_POOL_NAME:-mesh-v2}"

# 返回业务集群独立 kubeconfig 路径（不存在则报错）；调用方据此 local export KUBECONFIG
# 用法: kc=$(_cluster_kubeconfig_path <cluster>) || return 1
_cluster_kubeconfig_path() {
    local cluster="$1"
    local kc="$KUBECONFIG_DIR/${cluster}.yaml"
    if [ ! -f "$kc" ]; then
        log_error "未找到业务集群 kubeconfig: $kc"
        log_error "请先执行 './run.sh --project mesh --init-only --cluster $cluster ...' 进行初始化"
        return 1
    fi
    printf '%s' "$kc"
}

# 内联渲染 IPAddressPool + L2Advertisement
# 用法: _render_external_ip_pool <pool> <namespace> <addr...>
# 说明:
#   - spec.avoidBuggyIPs: true；L2Advertisement spec.nodeSelectors: null（按真实环境验证载荷）
#   - addresses 由地址参数逐行展开（CIDR，如 192.168.139.13/32）
_render_external_ip_pool() {
    local pool="$1" namespace="$2"
    shift 2
    local addresses=("$@")

    cat <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${pool}
  namespace: ${namespace}
spec:
  avoidBuggyIPs: true
  addresses:
EOF
    local addr
    for addr in "${addresses[@]}"; do
        printf '    - %s\n' "$addr"
    done
    cat <<EOF
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${pool}
  namespace: ${namespace}
spec:
  ipAddressPools:
    - ${pool}
  nodeSelectors: null
EOF
}

# 在指定业务集群创建外部 IP 地址池（IPAddressPool + L2Advertisement）
# 用法: create_external_ip_pool <cluster> <pool> <addr...>
create_external_ip_pool() {
    local cluster="$1" pool="$2"
    shift 2
    local addresses=("$@")

    if [ -z "$cluster" ] || [ -z "$pool" ] || [ ${#addresses[@]} -eq 0 ]; then
        log_error "create_external_ip_pool: 缺少参数 (cluster=$cluster, pool=$pool, addresses=${addresses[*]})"
        return 1
    fi

    local kc
    kc=$(_cluster_kubeconfig_path "$cluster") || return 1
    # 函数内 local export KUBECONFIG，返回后自动还原，不污染 merged.yaml 的 current-context
    local KUBECONFIG="$kc"
    export KUBECONFIG

    log_info "创建外部 IP 地址池 $pool 于集群 $cluster (地址: ${addresses[*]})"
    _render_external_ip_pool "$pool" "$METALLB_NAMESPACE" "${addresses[@]}" | kubectl apply -f - || {
        log_error "创建外部 IP 地址池失败: $pool@$cluster"
        return 1
    }
    return 0
}

# 轮询等待 IPAddressPool 可用地址 >= 1（读 .status.availableIPv4 + .status.availableIPv6）
# 用法: _wait_ipaddresspool_available <cluster> <pool> [max_retries] [interval]
# 说明: metallb 控制器 reconcile 后才回填 .status，故需重试；字段缺失/为空按 0 处理
_wait_ipaddresspool_available() {
    local cluster="$1" pool="$2"
    local max_retries="${3:-30}"
    local interval="${4:-10}"

    local kc
    kc=$(_cluster_kubeconfig_path "$cluster") || return 1
    local KUBECONFIG="$kc"
    export KUBECONFIG

    local attempt status_line v4 v6 total
    for ((attempt=1; attempt<=max_retries; attempt++)); do
        status_line=$(kubectl -n "$METALLB_NAMESPACE" get ipaddresspool "$pool" \
            -o jsonpath='{.status.availableIPv4} {.status.availableIPv6}' 2>/dev/null || echo "")
        read -r v4 v6 <<<"$status_line"
        [[ "$v4" =~ ^[0-9]+$ ]] || v4=0
        [[ "$v6" =~ ^[0-9]+$ ]] || v6=0
        total=$((v4 + v6))
        if [ "$total" -ge 1 ]; then
            log_success "外部 IP 地址池就绪: $pool@$cluster (availableIPv4=$v4, availableIPv6=$v6)"
            return 0
        fi
        log_warn "等待外部 IP 地址池可用地址 >= 1: $pool@$cluster (availableIPv4=$v4, availableIPv6=$v6) (${attempt}/${max_retries})"
        [ "$attempt" -lt "$max_retries" ] && sleep "$interval"
    done
    log_error "外部 IP 地址池可用地址始终不足: $pool@$cluster"
    kubectl -n "$METALLB_NAMESPACE" get ipaddresspool "$pool" -o yaml 2>/dev/null || true
    return 1
}

# 删除指定业务集群的外部 IP 地址池（先删 L2Advertisement 再删 IPAddressPool）
# 用法: delete_external_ip_pool <cluster> <pool>
delete_external_ip_pool() {
    local cluster="$1" pool="$2"

    if [ -z "$cluster" ] || [ -z "$pool" ]; then
        log_error "delete_external_ip_pool: 缺少参数 (cluster=$cluster, pool=$pool)"
        return 1
    fi

    local kc
    kc=$(_cluster_kubeconfig_path "$cluster") || return 1
    local KUBECONFIG="$kc"
    export KUBECONFIG

    log_info "删除外部 IP 地址池 $pool 于集群 $cluster"
    kubectl -n "$METALLB_NAMESPACE" delete l2advertisement "$pool" --ignore-not-found || {
        log_error "删除 L2Advertisement 失败: $pool@$cluster"
        return 1
    }
    kubectl -n "$METALLB_NAMESPACE" delete ipaddresspool "$pool" --ignore-not-found || {
        log_error "删除 IPAddressPool 失败: $pool@$cluster"
        return 1
    }
    return 0
}

# 为多集群测试在各业务集群创建外部 IP 地址池并等待可用（受 ENABLE_METALLB 门控）
# 用法: setup_external_ip_pools <cluster>...
# 说明:
#   - ENABLE_METALLB != true 时直接 no-op 返回 0（可在编排脚本中无条件调用）
#   - 地址来源: METALLB_EXTERNAL_ADDRESSES_JSON（JSON 数组，按 cluster 匹配；含 ipv4Addresses，
#     前向兼容 ipv6Addresses），资源固定命名 $METALLB_EXTERNAL_POOL_NAME（mesh-v2）
setup_external_ip_pools() {
    [ "${ENABLE_METALLB:-false}" = "true" ] || return 0

    if [ $# -eq 0 ]; then
        log_error "setup_external_ip_pools: 至少需要一个集群参数"
        return 1
    fi

    local json="${METALLB_EXTERNAL_ADDRESSES_JSON:-}"
    if [ -z "$json" ]; then
        log_error "ENABLE_METALLB=true 但未设置 METALLB_EXTERNAL_ADDRESSES_JSON (多集群测试需要外部地址池)"
        log_error '示例: METALLB_EXTERNAL_ADDRESSES_JSON='\''[{"cluster":"business-1","ipv4Addresses":["192.168.139.13/32"]}]'\'''
        return 1
    fi
    if ! printf '%s' "$json" | jq empty 2>/dev/null; then
        log_error "METALLB_EXTERNAL_ADDRESSES_JSON 不是有效 JSON"
        return 1
    fi

    local pool="$METALLB_EXTERNAL_POOL_NAME"
    local cluster
    for cluster in "$@"; do
        # 取该集群地址（合并 ipv4Addresses 与 ipv6Addresses，后者缺省为空数组）
        # 用 while-read 逐行收集（兼容 macOS 自带 Bash 3.2，其无 mapfile/readarray）
        local addresses=()
        local addr_line
        while IFS= read -r addr_line; do
            if [ -n "$addr_line" ]; then
                addresses+=("$addr_line")
            fi
        done < <(printf '%s' "$json" | jq -r --arg c "$cluster" \
            '.[] | select(.cluster == $c) | ((.ipv4Addresses // []) + (.ipv6Addresses // []))[]')
        if [ ${#addresses[@]} -eq 0 ]; then
            log_error "METALLB_EXTERNAL_ADDRESSES_JSON 中集群 $cluster 无地址配置 (需含 cluster=$cluster 的条目及 ipv4Addresses)"
            return 1
        fi
        create_external_ip_pool "$cluster" "$pool" "${addresses[@]}" || return 1
        _wait_ipaddresspool_available "$cluster" "$pool" || return 1
    done
    log_success "外部 IP 地址池已就绪: 集群 $* (pool=$pool)"
    return 0
}

# 删除多集群测试创建的外部 IP 地址池（受 ENABLE_METALLB 门控，尽力清理所有集群）
# 用法: teardown_external_ip_pools <cluster>...
teardown_external_ip_pools() {
    [ "${ENABLE_METALLB:-false}" = "true" ] || return 0

    if [ $# -eq 0 ]; then
        log_error "teardown_external_ip_pools: 至少需要一个集群参数"
        return 1
    fi

    local pool="$METALLB_EXTERNAL_POOL_NAME"
    local cluster rc=0
    for cluster in "$@"; do
        delete_external_ip_pool "$cluster" "$pool" || rc=1
    done
    [ "$rc" -eq 0 ] && log_success "外部 IP 地址池已清理: 集群 $* (pool=$pool)"
    return "$rc"
}
