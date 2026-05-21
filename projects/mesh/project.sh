#!/usr/bin/env bash
# mesh 项目专属逻辑（Alauda Service Mesh v2 文档测试）
#
# 由 run.sh 引擎在 source framework/{common,verify,kubeconfig,tools}.sh 之后加载。
# 包含：
#   - mesh 测试脚本使用的辅助函数（kubectl_apply_with_mirror）
#   - mesh 初始化专属函数（install_istioctl / upload_all_packages /
#     install_all_servicemesh_operators / fetch_platform_ca）
#   - 项目钩子 project_check_env / project_init / project_prepare

# ==============================================================================
# mesh 测试脚本辅助函数
# ==============================================================================

# 使用镜像加速地址执行 kubectl apply
# 用法: kubectl_apply_with_mirror <runme-block-name>
# 说明:
#   - 使用 runme print 获取代码块内容
#   - 按以下优先级选择镜像替换策略，命中后下载 YAML 并改写镜像后再 kubectl apply：
#       1. USE_MESH_V2_TEST_SUITE_PLUGIN=true（已安装 mesh-v2-test-suite 集群插件）
#          从 cpaas-system/mesh-v2-test-suite-manifest ConfigMap 的 data.registry
#          读取 ACP 内置镜像仓库地址，将 docker.io / registry.istio.io/release
#          改写到该仓库的 asm/ 命名空间下（所有镜像由插件预置）。
#       2. 否则若设置了 REGISTRY_MIRROR_ADDRESS，使用通用镜像加速地址替换。
#       3. 都未设置时，直接执行原命令。
kubectl_apply_with_mirror() {
    local block_name="$1"

    # 使用 runme print 获取命令内容
    local cmd_content
    cmd_content=$(runme print "$block_name" 2>/dev/null)

    if [ -z "$cmd_content" ]; then
        log_error "无法获取代码块内容: $block_name"
        return 1
    fi

    # 选择镜像替换目标：docker_io_target 替代 docker.io,
    # istio_release_target 替代 registry.istio.io/release。
    local docker_io_target=""
    local istio_release_target=""

    if [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ]; then
        local registry
        registry=$(kubectl -n cpaas-system get cm mesh-v2-test-suite-manifest \
            -o jsonpath='{.data.registry}' 2>/dev/null)
        if [ -z "$registry" ]; then
            log_error "USE_MESH_V2_TEST_SUITE_PLUGIN=true 但未能从 cpaas-system/mesh-v2-test-suite-manifest 读取 data.registry"
            log_error "请确认已在当前集群安装 mesh-v2-test-suite 集群插件 (charts/mesh-v2-test-suite/)"
            return 1
        fi
        log_info "使用 mesh-v2-test-suite 集群插件镜像仓库: $registry"
        docker_io_target="${registry}/asm"
        istio_release_target="${registry}/asm/istio"
    elif [ -n "${REGISTRY_MIRROR_ADDRESS:-}" ]; then
        log_info "使用镜像加速地址: $REGISTRY_MIRROR_ADDRESS"
        docker_io_target="${REGISTRY_MIRROR_ADDRESS}"
        istio_release_target="${REGISTRY_MIRROR_ADDRESS}/istio"
    else
        # 没有镜像替换策略，直接执行原命令
        eval "$cmd_content"
        return $?
    fi

    # 从命令中提取 URL
    local url
    url=$(echo "$cmd_content" | grep -oE 'https://[^ ]+\.yaml' | head -n 1)

    if [ -z "$url" ]; then
        log_error "无法从命令中提取 YAML 文件 URL"
        return 1
    fi

    # 下载 YAML 文件，替换镜像地址，然后应用
    log_info "下载并替换镜像地址: $url"
    curl -fsSL "$url" \
        | sed "s|docker\.io|${docker_io_target}|g" \
        | sed "s|registry\.istio\.io/release|${istio_release_target}|g" \
        | eval "${cmd_content//-f $url/-f -}"
}

# ==============================================================================
# mesh 初始化专属函数
# ==============================================================================

# 安装 istioctl 工具
# 版本号通过 runme print 从 install-multi-primary-multi-network.mdx 的
#   multi-primary-multi-network:set-istio-version
# 代码块中读取 (例: export ISTIO_VERSION=1.28.6 → 1.28.6)
# 验证: istioctl version --remote=false 输出形如 "client version: 1.28.6"
# NOTE: 依赖 CWD 位于 servicemesh2-docs 仓库内（引擎已 cd 到 DOC_REPO_ROOT）。
install_istioctl() {
    # 从 runme 块中提取 istio 版本号
    local istio_version
    istio_version=$("$BIN_DIR/runme" print multi-primary-multi-network:set-istio-version 2>/dev/null \
        | grep -oE 'ISTIO_VERSION=[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n 1 \
        | cut -d= -f2)

    if [ -z "$istio_version" ]; then
        log_error "无法从 multi-primary-multi-network:set-istio-version 块中提取 ISTIO_VERSION"
        exit 1
    fi
    log_info "目标 istioctl 版本: $istio_version"

    # istioctl 发布包命名: Darwin → osx (与 runme/violet 不同)
    _detect_os_arch osx linux amd64 arm64
    local url="https://github.com/istio/istio/releases/download/${istio_version}/istioctl-${istio_version}-${DETECTED_OS}-${DETECTED_ARCH}.tar.gz"
    _install_tool istioctl "version --remote=false" "client version: $istio_version" "$url" true
}

# 上传 mesh 测试所需的全部插件包到指定集群列表
# 用法: upload_all_packages <cluster>...
upload_all_packages() {
    log_info "开始上传插件包..."

    local clusters=("$@")
    if [ ${#clusters[@]} -eq 0 ]; then
        log_warn "没有传入集群，跳过插件包上传"
        return 0
    fi

    local packages=(
        "$PKG_SERVICEMESH_OPERATOR2_URL"
        "$PKG_KIALI_OPERATOR_URL"
        "$PKG_OPENTELEMETRY_OPERATOR2_URL"
        "$PKG_METALLB_OPERATOR_URL"
    )

    # 下载所有插件包
    for pkg_url in "${packages[@]}"; do
        download_package "$pkg_url"
    done

    # 上传插件包到各集群
    for cluster in "${clusters[@]}"; do
        log_info "处理集群: $cluster"

        for pkg_url in "${packages[@]}"; do
            if ! check_package_uploaded "$cluster" "$pkg_url"; then
                upload_package "$cluster" "$pkg_url"
            fi
        done
    done

    log_success "所有插件包上传完成"
}

# 在指定集群列表上安装 servicemesh-operator2
# 用法: install_all_servicemesh_operators <cluster>...
install_all_servicemesh_operators() {
    log_info "开始安装 servicemesh-operator2 ..."

    local clusters=("$@")
    if [ ${#clusters[@]} -eq 0 ]; then
        log_warn "没有传入集群，跳过 servicemesh-operator2 安装"
        return 0
    fi

    for cluster in "${clusters[@]}"; do
        log_info "安装 servicemesh-operator2 到集群: $cluster"
        # 通过临时覆盖 KUBECONFIG 指向单集群 kubeconfig (其 current-context 已是 $cluster)
        # 避免 kubectl config use-context 持久化改写 merged.yaml 的 current-context,
        # 否则循环结束时 merged.yaml 的 current-context 会停在最后一个集群
        KUBECONFIG="$KUBECONFIG_DIR/${cluster}.yaml" install_operator \
            "servicemesh-operator2" \
            "sail-operator" \
            "$PKG_SERVICEMESH_OPERATOR2_URL" \
            "install-mesh"
    done

    log_success "所有集群的 servicemesh-operator2 安装完成"
}

# 通过 Global 集群的独立 kubeconfig 拉取平台 CA 证书（base64 编码）
# - 不污染当前 KUBECONFIG / merged.yaml：用 $KUBECONFIG_DIR/$GLOBAL_CLUSTER_NAME.yaml
#   作为子 shell 的 KUBECONFIG，仅作用于本次执行
# - 优先 config-kiali:get-ca-certificate（dex.tls 的 ca.crt 字段）
# - 为空则 fallback config-kiali:get-ca-certificate-alternative（dex.tls 的 tls.crt 字段）
# - 仍为空则报错退出
# 输出: 标准输出仅打印 base64 字符串（无尾随换行）
# 用法: ca=$(fetch_platform_ca) || return 1
# NOTE: config-kiali:* 块位于 servicemesh2-docs 仓库（引擎已 cd 到 DOC_REPO_ROOT）。
fetch_platform_ca() {
    local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"
    local global_kc="$KUBECONFIG_DIR/${global_cluster}.yaml"
    if [ ! -f "$global_kc" ]; then
        log_error "fetch_platform_ca: 未找到 Global kubeconfig: $global_kc"
        log_error "请重新执行 './run.sh --project mesh --init-only' 让框架自动拉取 ${global_cluster} 集群的 kubeconfig"
        return 1
    fi

    if ! command -v runme > /dev/null 2>&1; then
        log_error "fetch_platform_ca: 缺少 runme 工具，请先执行 './run.sh --project mesh --init-only' 安装"
        return 1
    fi

    local ca
    ca=$(_run_runme_block_isolated config-kiali:get-ca-certificate "$global_kc")
    if [ -n "$ca" ]; then
        printf '%s' "$ca"
        return 0
    fi

    log_warn "fetch_platform_ca: config-kiali:get-ca-certificate 返回空，回退到 alternative 块"
    ca=$(_run_runme_block_isolated config-kiali:get-ca-certificate-alternative "$global_kc")
    if [ -n "$ca" ]; then
        printf '%s' "$ca"
        return 0
    fi

    log_error "fetch_platform_ca: 两个 runme 块均返回空，无法获取 PLATFORM_CA"
    log_error "请检查 ${global_cluster} 集群上 cpaas-system/dex.tls Secret 是否存在，或显式 export PLATFORM_CA"
    return 1
}

# ==============================================================================
# 项目钩子（由 run.sh 引擎调用）
# ==============================================================================

# 校验 mesh 项目专属环境变量
project_check_env() {
    local required=(
        "PKG_SERVICEMESH_OPERATOR2_URL"
        "PKG_KIALI_OPERATOR_URL"
        "PKG_OPENTELEMETRY_OPERATOR2_URL"
        "PKG_METALLB_OPERATOR_URL"
    )
    local missing=()
    local var
    for var in "${required[@]}"; do
        if [ -z "${!var}" ]; then
            missing+=("$var")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "mesh 项目缺少必要的环境变量: ${missing[*]}"
        return 1
    fi
    return 0
}

# mesh 重量级初始化（仅 --init-only / --force-init 时调用）
# 通用工具（runme/violet）已由引擎安装；此处负责 istioctl + kubeconfig + 插件包 + operator。
# 用法: project_init <cluster>...
project_init() {
    if [ $# -eq 0 ]; then
        log_error "mesh project_init: 至少需要一个集群参数"
        return 1
    fi

    local clusters=("$@")
    local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"
    log_info "mesh 环境初始化（业务集群: ${clusters[*]} + Global 集群: ${global_cluster}）..."

    install_istioctl
    # ensure_kubeconfig: fingerprint 一致则复用 merged.yaml，变更时才重新拉取。
    # 末尾追加 Global 集群（用于 fetch_platform_ca）；列表去重由内部处理。
    ensure_kubeconfig "${clusters[@]}" "$global_cluster" || return 1
    upload_all_packages "${clusters[@]}" || return 1
    install_all_servicemesh_operators "${clusters[@]}" || return 1

    log_success "mesh 环境初始化完成!"
}

# mesh 轻量级准备（每次运行测试前调用）
# 复用既有 kubeconfig，并统一解析 PLATFORM_CA。
project_prepare() {
    load_kubeconfig || return 1

    # 统一解析 PLATFORM_CA
    # - 已通过环境变量设置: 直接使用
    # - 未设置: 从 Global 集群独立 kubeconfig 自动获取（不污染当前 KUBECONFIG）
    if [ -n "${PLATFORM_CA:-}" ]; then
        log_info "使用环境变量中的 PLATFORM_CA"
    else
        log_info "PLATFORM_CA 未设置，从 Global 集群自动获取..."
        PLATFORM_CA=$(fetch_platform_ca) || return 1
        export PLATFORM_CA
        log_success "PLATFORM_CA 已从 Global 集群获取（长度: ${#PLATFORM_CA}）"
    fi
    return 0
}
