#!/usr/bin/env bash
# mesh 项目专属逻辑（Alauda Service Mesh v2 文档测试）
#
# 由 run.sh 引擎在 source framework/{common,verify,kubeconfig,tools}.sh 之后加载。
# 包含：
#   - mesh 测试脚本使用的辅助函数（kubectl_apply_with_mirror）
#   - mesh 初始化专属函数（install_istioctl / upload_all_packages /
#     install_all_cluster_plugins / install_all_servicemesh_operators / fetch_platform_ca）
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

# (可选) 在 bookinfo 的 ratings pod 中后台生成请求流量
# 用法: maybe_gen_bookinfo_traffic [namespace]   # namespace 默认 bookinfo
# 说明:
#   - 仅当 AUTO_GEN_BOOKINFO_TRAFFIC=true 时执行，否则静默返回（与原内联逻辑一致）。
#   - 找到 app=ratings 的 pod，在其 ratings 容器内启动一个后台循环，每 ~10s 访问一次
#     productpage:9080/productpage，使 Kiali 等可观测到持续流量。
#   - 未找到 ratings pod 时打印 warning 并跳过（不视为失败）。
#   - bookinfo 工作负载被重启后，承载循环的 ratings pod 会被销毁，需在重启就绪后再次调用本函数。
maybe_gen_bookinfo_traffic() {
    [ "${AUTO_GEN_BOOKINFO_TRAFFIC:-false}" == "true" ] || return 0

    local ns="${1:-bookinfo}"
    log_info "生成请求流量 (AUTO_GEN_BOOKINFO_TRAFFIC=true, namespace=$ns)"

    local ratings_pod
    ratings_pod=$(kubectl get pod -l app=ratings -n "$ns" -o jsonpath='{.items[0].metadata.name}')
    if [ -n "$ratings_pod" ]; then
        log_info "在 ratings pod ($ratings_pod) 中启动流量生成..."
        kubectl exec "$ratings_pod" -c ratings -n "$ns" -- bash -lc "(while true; do curl -sS productpage:9080/productpage >/dev/null; sleep 9.9; done) >/dev/null 2>&1 & disown"
        log_success "流量生成已启动"
    else
        log_warn "未找到 ratings pod, 跳过流量生成"
    fi
    return 0
}

# ==============================================================================
# 网关安装 / Linux 内核兼容 公共函数
# ------------------------------------------------------------------------------
# 供 directing-traffic-into-the-mesh / directing-outbound-traffic /
# install-*-multi-network 等测试复用，封装自:
#   - gateways/gateway-installation/installing-a-gateway-via-injection.mdx
#   - gateways/gateway-installation/linux-kernel-compatibility-notice.mdx
# 开关 ENABLE_GW_LINUX_KERNEL_COMPAT=true 时按内核 < 4.11 (CentOS7) 做网关兼容处理:
#   - run_as_root=false → Scenario 1: 仅去除 pod 的 sysctls (高端口网关，如东西向/waypoint)
#   - run_as_root=true  → Scenario 2: 去 sysctls + 加 NET_BIND_SERVICE + 以 root 运行
#                                     (特权端口 < 1024，如监听 80 的 ingress/egress 网关)
# 注: 内部文本处理兼容 GNU(Linux CI) 与 BSD(macOS) 的 sed/awk，不依赖 GNU sed 的 \n 替换扩展。
# ==============================================================================

# 渲染 runme 块并替换网关占位符 <gateway_name>/<gateway_namespace>
# 用法: _gw_render_block <block_name> <gw_name> <gw_ns>
_gw_render_block() {
    runme print "$1" | sed -e "s|<gateway_name>|$2|g" -e "s|<gateway_namespace>|$3|g"
}

# 对以 kubectl 开头的命令串注入 --context (ctx 为空则原样返回)
# 用法: cmd=$(_gw_inject_ctx "$ctx" "$cmd")
_gw_inject_ctx() {
    local ctx="$1"; shift
    local cmd="$*"
    if [ -n "$ctx" ]; then
        printf '%s' "${cmd//kubectl /kubectl --context $ctx }"
    else
        printf '%s' "$cmd"
    fi
}

# 通过 gateway injection 安装网关 (installing-a-gateway-via-injection.mdx)
# 用法: install_gateway_via_injection <gateway_name> <gateway_namespace> [run_as_root=true] [context]
# 说明:
#   - 默认严格按文档渲染各 YAML 块 (替换占位符) 并下发，覆盖含可选 HPA/PDB 的全部命名块；
#     唯一例外: 内核兼容且以 root 运行时，将 Deployment 的 istio-proxy 容器 runAsNonRoot 改为 false
#     (与被修补注入模板的 runAsUser: 0 保持一致，避免容器级 runAsNonRoot: true 覆盖模板致 pod 被拒)
#   - 内核 < 4.11 兼容在本函数内处理: 创建网关 Deployment 前先调 apply_kernel_compat_istio_gateway,
#     按 linux-kernel-compatibility-notice.mdx 修补 mesh 级 gateway 注入模板 (开关关时 no-op);
#     注入时模板的 securityContext (sysctls / NET_BIND_SERVICE / root) 会 overlay 到 istio-proxy 容器;
#     监听特权端口 < 1024 (如 80) 的网关传 run_as_root=true 走 Scenario 2, 高端口传 false 走 Scenario 1
install_gateway_via_injection() {
    local gw_name="$1" gw_ns="$2" run_as_root="${3:-true}" ctx="${4:-}"
    if [ -z "$gw_name" ] || [ -z "$gw_ns" ]; then
        log_error "install_gateway_via_injection: 用法 <gateway_name> <gateway_namespace> [run_as_root] [context]"
        return 1
    fi

    log_info "=========================================="
    log_info "通过 gateway injection 安装网关: name=$gw_name ns=$gw_ns${ctx:+ context=$ctx}"
    log_info "=========================================="

    # 内核 < 4.11 兼容: 必须在创建网关 Deployment 前修补 mesh 级注入模板 (ENABLE_GW_LINUX_KERNEL_COMPAT 关时 no-op)
    apply_kernel_compat_istio_gateway "$run_as_root" "$ctx" || return 1

    local workdir; workdir=$(mktemp -d -t gwi-XXXXXX)

    # 注: runme 需 CWD 位于文档仓库根 (引擎已 cd 至此) 才能解析代码块，
    #     故所有 runme print / 渲染先在此完成，最后再切到 workdir 执行 apply。

    # 渲染各 YAML 落盘 (替换占位符)
    _gw_render_block install-gateway-injection:secret-reader-yaml "$gw_name" "$gw_ns" > "$workdir/secret-reader.yaml"
    _gw_render_block install-gateway-injection:gateway-service-yaml "$gw_name" "$gw_ns" > "$workdir/gateway-service.yaml"
    _gw_render_block install-gateway-injection:gateway-hpa-yaml "$gw_name" "$gw_ns" > "$workdir/gateway-hpa.yaml"
    _gw_render_block install-gateway-injection:gateway-pdb-yaml "$gw_name" "$gw_ns" > "$workdir/gateway-pdb.yaml"
    # 内核 < 4.11 且以 root 运行 (Scenario 2 root) 时: 文档 gateway-deployment.yaml 的 istio-proxy 容器
    # 显式声明了容器级 runAsNonRoot: true，注入合并时其优先级高于被修补的注入模板 (runAsNonRoot: false)，
    # 会与模板下发的 runAsUser: 0 冲突，触发 kubelet "container's runAsUser breaks non-root policy"。
    # 故下发前将其改为 false，使网关安装配置与内核兼容处理保持一致
    # (详见 gateways/gateway-installation/linux-kernel-compatibility-notice.mdx)。开关关或非 root 时原样下发。
    # 注: 用「渲染管道 + 普通替换」而非 sed -i/-E，确保 GNU(Linux CI) 与 BSD(macOS) sed 均可用
    #     (BSD sed 的 -i 须紧跟备份后缀，会把 -E 误当后缀，致基本正则下 \1 反向引用未定义而报错)。
    if [ "${ENABLE_GW_LINUX_KERNEL_COMPAT:-false}" = "true" ] && [ "$run_as_root" = "true" ]; then
        _gw_render_block install-gateway-injection:gateway-deployment-yaml "$gw_name" "$gw_ns" \
            | sed 's/runAsNonRoot: true/runAsNonRoot: false/' > "$workdir/gateway-deployment.yaml"
    else
        _gw_render_block install-gateway-injection:gateway-deployment-yaml "$gw_name" "$gw_ns" > "$workdir/gateway-deployment.yaml"
    fi

    # 捕获各命令 (含占位符替换与 --context 注入；在 workdir 外完成 runme 解析)
    local ns_cmd apply_sr apply_dep roll apply_svc ep apply_hpa apply_pdb
    ns_cmd=$(_gw_inject_ctx "$ctx" "$(_gw_render_block install-gateway-injection:create-namespace "$gw_name" "$gw_ns")")
    apply_sr=$(_gw_inject_ctx "$ctx" "$(runme print install-gateway-injection:apply-secret-reader)")
    apply_dep=$(_gw_inject_ctx "$ctx" "$(runme print install-gateway-injection:apply-gateway-deployment)")
    roll=$(_gw_inject_ctx "$ctx" "$(_gw_render_block install-gateway-injection:verify-rollout "$gw_name" "$gw_ns")")
    apply_svc=$(_gw_inject_ctx "$ctx" "$(runme print install-gateway-injection:apply-gateway-service)")
    ep=$(_gw_inject_ctx "$ctx" "$(_gw_render_block install-gateway-injection:verify-endpoints "$gw_name" "$gw_ns")")
    apply_hpa=$(_gw_inject_ctx "$ctx" "$(runme print install-gateway-injection:apply-gateway-hpa)")
    apply_pdb=$(_gw_inject_ctx "$ctx" "$(runme print install-gateway-injection:apply-gateway-pdb)")

    # 切到 workdir 执行 (apply 块内使用相对文件名)
    local rc=0
    (
        set -e
        cd "$workdir"
        eval "$ns_cmd" 2>&1 || true   # 命名空间容忍 AlreadyExists
        eval "$apply_sr"
        eval "$apply_dep"
        eval "$roll"
        eval "$apply_svc"
        eval "$ep"
        eval "$apply_hpa"
        eval "$apply_pdb"
    ) || rc=1

    rm -rf "$workdir"
    if [ "$rc" -ne 0 ]; then
        log_error "gateway injection 安装失败: name=$gw_name ns=$gw_ns"
        return 1
    fi
    log_success "gateway injection 安装完成: name=$gw_name ns=$gw_ns"
    return 0
}

# Istio Gateway (gateway injection) 路径的内核兼容: 修补 mesh 级注入模板并等待 Istio Ready
# 用法: apply_kernel_compat_istio_gateway [run_as_root=true] [context]
# 说明: 关时直接返回; 多集群东西向网关 (高端口) 传 run_as_root=false (Scenario 1)
apply_kernel_compat_istio_gateway() {
    [ "${ENABLE_GW_LINUX_KERNEL_COMPAT:-false}" = "true" ] || return 0
    local run_as_root="${1:-true}" ctx="${2:-}"

    log_info "Istio Gateway 注入模板内核兼容: run_as_root=$run_as_root${ctx:+ context=$ctx}"

    local workdir; workdir=$(mktemp -d -t gwkc-XXXXXX)
    local tmpl="$workdir/gateway-injection-template.txt"

    # 在文档仓库根解析 runme 块 (引擎已 cd 至此；勿在 workdir 内调用 runme)
    if [ "$run_as_root" = "true" ]; then
        # Scenario 2: 模板已含 sysctls: []，再加 NET_BIND_SERVICE 并改为 root 运行。
        # 用 awk 逐行匹配并按原缩进展开多行（而非 GNU sed 的 \n 替换扩展），以兼容 BSD(macOS) 与 GNU(Linux CI)；
        # 已验证与原 sed \n 版本输出字节级一致。正则用 [{] [|] [.] 括号表达式，避免部分 awk 的转义告警。
        runme print kernel-compat:istio-injection-template \
            | awk '
                /^[[:space:]]*runAsUser: [{][{] [.]ProxyUID [|] default "1337" [}][}]$/ {
                    match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
                    print ind "capabilities:"; print ind "  add:"; print ind "  - NET_BIND_SERVICE"; print ind "runAsUser: 0"; next
                }
                /^[[:space:]]*runAsGroup: [{][{] [.]ProxyGID [|] default "1337" [}][}]$/ {
                    match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
                    print ind "runAsGroup: 0"; print ind "runAsNonRoot: false"; next
                }
                { print }
            ' > "$tmpl"
    else
        # Scenario 1: 仅去 sysctls (模板已含 sysctls: [])
        runme print kernel-compat:istio-injection-template > "$tmpl"
    fi
    if [ ! -s "$tmpl" ]; then
        log_error "获取/渲染注入模板失败 (kernel-compat:istio-injection-template)"
        rm -rf "$workdir"; return 1
    fi

    local patch_cmd wait_cmd
    patch_cmd=$(_gw_inject_ctx "$ctx" "$(runme print kernel-compat:patch-istio-template)")
    wait_cmd=$(_gw_inject_ctx "$ctx" "$(runme print kernel-compat:wait-istio-ready)")

    # 切到 workdir 执行 (patch 块内 `cat gateway-injection-template.txt` 依赖 CWD)
    local rc=0
    ( set -e; cd "$workdir"; eval "$patch_cmd"; eval "$wait_cmd" ) || rc=1

    rm -rf "$workdir"
    if [ "$rc" -ne 0 ]; then
        log_error "Istio Gateway 注入模板内核兼容处理失败"
        return 1
    fi
    log_success "Istio Gateway 注入模板内核兼容处理完成"
    return 0
}

# 内核 < 4.11 + 以 root 运行的「注入网关」一致性修正: 将其 Deployment 的 istio-proxy 容器
# runAsNonRoot 置为 false，与被修补注入模板的 runAsUser: 0 保持一致。
# 背景: gateway injection 的 Deployment (如上游 ingress-gateway.yaml) 容器级 securityContext 常含
#       runAsNonRoot: true，注入合并时其优先级高于注入模板的 runAsNonRoot: false，会与 runAsUser: 0
#       冲突，触发 kubelet "container's runAsUser breaks non-root policy"，pod 无法创建、rollout 卡住。
# 适用: 经 kubectl apply 直接下发的注入网关；install_gateway_via_injection 已在渲染期 sed 处理，无需调用本函数。
# 用法: reconcile_injected_gateway_runasroot <namespace> <deployment> [run_as_root=true] [context]
# 说明: 仅 ENABLE_GW_LINUX_KERNEL_COMPAT=true 且 run_as_root=true 时生效，否则 no-op。
reconcile_injected_gateway_runasroot() {
    [ "${ENABLE_GW_LINUX_KERNEL_COMPAT:-false}" = "true" ] || return 0
    local ns="$1" dep="$2" run_as_root="${3:-true}" ctx="${4:-}"
    [ "$run_as_root" = "true" ] || return 0
    if [ -z "$ns" ] || [ -z "$dep" ]; then
        log_error "reconcile_injected_gateway_runasroot: 用法 <namespace> <deployment> [run_as_root] [context]"
        return 1
    fi
    local kargs=(kubectl); [ -n "$ctx" ] && kargs+=(--context "$ctx")

    log_info "内核兼容(root): 修正注入网关 Deployment $dep 的 istio-proxy runAsNonRoot=false (ns=$ns)"
    # 策略合并 (默认 strategic): 按容器名 istio-proxy 合并，仅改 runAsNonRoot，保留其余 securityContext 字段；
    # patch 触发滚动更新，新副本以一致的 securityContext 重新注入后即可被准入。
    "${kargs[@]}" -n "$ns" patch deployment "$dep" \
        -p '{"spec":{"template":{"spec":{"containers":[{"name":"istio-proxy","securityContext":{"runAsNonRoot":false}}]}}}}' || {
        log_error "修正注入网关 $dep 的 runAsNonRoot 失败 (ns=$ns)"
        return 1
    }
    return 0
}

# Kubernetes Gateway API 路径的内核兼容: 创建 asm-kube-gateway-options ConfigMap 并给 Gateway 挂 parametersRef
# 用法: apply_kernel_compat_k8s_gateway_api <namespace> <gateway_name> [run_as_root=true] [context]
# 说明: 关时直接返回; 高端口网关 (如 waypoint 15008) 传 run_as_root=false (Scenario 1)
apply_kernel_compat_k8s_gateway_api() {
    [ "${ENABLE_GW_LINUX_KERNEL_COMPAT:-false}" = "true" ] || return 0
    local ns="$1" gw_name="$2" run_as_root="${3:-true}" ctx="${4:-}"
    if [ -z "$ns" ] || [ -z "$gw_name" ]; then
        log_error "apply_kernel_compat_k8s_gateway_api: 用法 <namespace> <gateway_name> [run_as_root] [context]"
        return 1
    fi
    local kargs=(kubectl); [ -n "$ctx" ] && kargs+=(--context "$ctx")

    log_info "K8s Gateway API 内核兼容: ns=$ns gw=$gw_name run_as_root=$run_as_root${ctx:+ context=$ctx}"

    # 1. asm-kube-gateway-options ConfigMap (幂等)
    local cm_block cm_yaml
    if [ "$run_as_root" = "true" ]; then
        cm_block="kernel-compat:k8s-gateway-options-scenario2"
    else
        cm_block="kernel-compat:k8s-gateway-options-scenario1"
    fi
    cm_yaml=$(runme print "$cm_block" | sed "s|<your-gateway-namespace>|$ns|g")
    if [ "$run_as_root" = "true" ]; then
        # 取消 root 行注释 (# 为内容字符，sed 用 @ 作分隔符)
        cm_yaml=$(printf '%s\n' "$cm_yaml" | sed -E 's@^([[:space:]]*)# (runAsUser: 0|runAsGroup: 0|runAsNonRoot: false)$@\1\2@')
    fi
    printf '%s\n' "$cm_yaml" | "${kargs[@]}" apply -f - || {
        log_error "创建 asm-kube-gateway-options ConfigMap 失败 (ns=$ns)"
        return 1
    }

    # 2. 给目标 Gateway 挂接 parametersRef，使其使用上述 ConfigMap
    "${kargs[@]}" -n "$ns" patch gateway "$gw_name" --type=merge \
        -p '{"spec":{"infrastructure":{"parametersRef":{"group":"","kind":"ConfigMap","name":"asm-kube-gateway-options"}}}}' || {
        log_error "为 Gateway $gw_name 挂接 parametersRef 失败 (ns=$ns)"
        return 1
    }

    # 3. 等待该 Gateway 生成的 Deployment 重新就绪 (parametersRef 触发控制器重建；按 gateway-name 标签定位，类无关)
    #    Deployment 可能滞后于 parametersRef patch，故先轮询等待其出现，再等 rollout
    local dep="" attempt
    for ((attempt=1; attempt<=12; attempt++)); do
        dep=$("${kargs[@]}" -n "$ns" get deploy -l "gateway.networking.k8s.io/gateway-name=$gw_name" -o name 2>/dev/null | head -n1)
        [ -n "$dep" ] && break
        sleep 5
    done
    if [ -n "$dep" ]; then
        "${kargs[@]}" -n "$ns" rollout status "$dep" --timeout=5m || {
            log_error "Gateway $gw_name 的 Deployment 重建未就绪 (ns=$ns)"
            return 1
        }
    else
        log_warn "未找到 Gateway $gw_name 生成的 Deployment (ns=$ns)，跳过 rollout 等待"
    fi

    log_success "K8s Gateway API 内核兼容处理完成: ns=$ns gw=$gw_name"
    return 0
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

    # 注：metallb-operator 不在此无条件上传；它作为 MetalLB 集群插件的前置，
    # 仅 ENABLE_METALLB=true 时由 install_all_cluster_plugins 按需上架到 Global 集群。
    local packages=(
        "$PKG_SERVICEMESH_OPERATOR2_URL"
        "$PKG_KIALI_OPERATOR_URL"
        "$PKG_OPENTELEMETRY_OPERATOR2_URL"
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

# 在 Global 集群为每个业务集群安装所需集群插件（Multus 始终；MetalLB / mesh-v2-test-suite 按开关）
# 用法: install_all_cluster_plugins <cluster>...
# 说明:
#   - Multus 是 Service Mesh 的前提（install-mesh.mdx），必须先于 servicemesh-operator2 安装
#   - MetalLB 仅多集群网格 / 网关场景需要，由 ENABLE_METALLB 控制；安装前需上架 metallb-operator
#   - mesh-v2-test-suite 由 USE_MESH_V2_TEST_SUITE_PLUGIN 控制
#   - 所有操作经 Global 集群进行，插件落地到对应业务集群（见 common.sh install_cluster_plugin）
install_all_cluster_plugins() {
    local clusters=("$@")
    if [ ${#clusters[@]} -eq 0 ]; then
        log_warn "没有传入集群，跳过集群插件安装"
        return 0
    fi

    local cluster
    for cluster in "${clusters[@]}"; do
        log_info "为业务集群 $cluster 安装集群插件..."

        # Multus：mesh 前提，始终安装
        install_cluster_plugin "multus" "$cluster" "$PKG_MULTUS_URL" || return 1

        # MetalLB：仅 ENABLE_METALLB=true；需上架 metallb-operator 作为前置（仅上架不安装）
        if [ "${ENABLE_METALLB:-false}" = "true" ]; then
            install_cluster_plugin "metallb" "$cluster" \
                "$PKG_METALLB_URL" "$PKG_METALLB_OPERATOR_URL" || return 1
        fi

        # mesh-v2-test-suite：仅 USE_MESH_V2_TEST_SUITE_PLUGIN=true
        if [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ]; then
            install_cluster_plugin "mesh-v2-test-suite" "$cluster" \
                "$PKG_MESH_V2_TEST_SUITE_URL" || return 1
        fi
    done

    log_success "所有业务集群的集群插件安装完成"
    return 0
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
        "PKG_MULTUS_URL"
    )

    # MetalLB 相关变量仅 ENABLE_METALLB=true 时必需（metallb 插件包 + 其前置 metallb-operator 包）
    if [ "${ENABLE_METALLB:-false}" = "true" ]; then
        required+=("PKG_METALLB_URL" "PKG_METALLB_OPERATOR_URL")
    fi

    # mesh-v2-test-suite 插件包仅 USE_MESH_V2_TEST_SUITE_PLUGIN=true 时必需
    if [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ]; then
        required+=("PKG_MESH_V2_TEST_SUITE_URL")
    fi

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
    log_info "mesh 环境初始化 (业务集群: ${clusters[*]} + Global 集群: ${global_cluster})..."

    install_istioctl
    # ensure_kubeconfig: fingerprint 一致则复用 merged.yaml，变更时才重新拉取。
    # 末尾追加 Global 集群（用于 fetch_platform_ca）；列表去重由内部处理。
    ensure_kubeconfig "${clusters[@]}" "$global_cluster" || return 1
    upload_all_packages "${clusters[@]}" || return 1
    # 集群插件需先于 servicemesh-operator2 安装（Multus 是 mesh 前提）
    install_all_cluster_plugins "${clusters[@]}" || return 1
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
        log_success "PLATFORM_CA 已从 Global 集群获取 (长度: ${#PLATFORM_CA})"
    fi
    return 0
}
