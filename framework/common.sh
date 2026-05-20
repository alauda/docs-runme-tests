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
        popd > /dev/null
        return 1
    fi
    
    # 执行命令
    eval "$cmd_content" || {
        log_error "应用 $block_name 失败"
        popd > /dev/null
        return 1
    }
    
    popd > /dev/null
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

# 测试结果统计
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

record_test_result() {
    local result=$1
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    if [ "$result" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

print_test_summary() {
    echo ""
    echo "========================================"
    echo "测试总结"
    echo "========================================"
    echo "总计: $TESTS_TOTAL"
    if [ "$TESTS_PASSED" -gt 0 ]; then
        echo -e "${GREEN}通过: $TESTS_PASSED${NC}"
    fi
    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}失败: $TESTS_FAILED${NC}"
    fi
    echo "========================================"
    
    if [ "$TESTS_FAILED" -eq 0 ]; then
        log_success "所有测试通过!"
        return 0
    else
        log_error "有 $TESTS_FAILED 个测试失败"
        return 1
    fi
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
