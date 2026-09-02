#!/usr/bin/env bash
# mesh 项目全量测试编排脚本
# 按预定义顺序执行 Alauda Service Mesh v2 文档的所有测试任务

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export FRAMEWORK_ROOT="$SCRIPT_DIR"
# 加载公共函数
source "$SCRIPT_DIR/framework/common.sh"
source "$SCRIPT_DIR/framework/report.sh"

# 确保在框架仓库根目录执行
cd "$SCRIPT_DIR"

# 编排模式：子 run.sh 不各自 finalize，由本脚本退出时统一汇总三层报告
export RUNME_TEST_ORCHESTRATED=1
report_init mesh
trap report_finalize EXIT

log_header "开始执行 mesh 项目所有测试任务"

# ------------------------------------------------------------------
# Case 1: 环境初始化（默认使用 SINGLE_CLUSTER_NAME）
# 注：multi-cluster 文档测试需在对应 case 中再次执行
#     ./run.sh --project mesh --init-only --cluster "$EAST_CLUSTER_NAME" --cluster "$WEST_CLUSTER_NAME"
# 致命前置：带保留标签 always，不参与 CASE_TYPE 求值，任何子集都必须先跑。
# ------------------------------------------------------------------
if case_begin_if "1" "环境初始化（默认 SINGLE_CLUSTER_NAME）" always install; then
    if (
        set -e
        ./run.sh --project mesh --init-only
    ); then
        case_end 0
    else
        case_end_fatal 1
    fi
fi

# ------------------------------------------------------------------
# Case 2: 双栈网格安装
# 环境判断（IS_DUAL_STACK）与标签门控（dualstack install）并列：
# 环境不支持 → env 分类跳过；环境支持但标签未选中 → case_begin_if 内部按 expected 分类跳过。
# ------------------------------------------------------------------
if [ "${IS_DUAL_STACK:-false}" != "true" ]; then
    case_skip "2" "双栈网格安装测试" "IS_DUAL_STACK != true" env
elif case_begin_if "2" "双栈网格安装测试 (Dual Stack)" dualstack install; then
    if (
        set -e
        ./run.sh --project mesh --file install-mesh-in-dual-stack-mode --no-cleanup
        ./run.sh --project mesh --file install-mesh-in-dual-stack-mode --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 3: 单网格安装与应用测试（含调用链集成）
# 顺序：先装调用链再装 kiali；清理逆序（先卸 kiali、再卸调用链）。
# 卸载调用链使用 --skip-operator-and-crds 与 --skip-cluster-plugin，保留 OTel Operator、CRDs
# 与 Jaeger v2 集群插件供后续 case 复用。
# ------------------------------------------------------------------
if case_begin_if "3" "单网格安装与应用测试 (Single Mesh & App + Tracing)" smoke install sidecar; then
    # 用子 shell ( cmds ) 把多条命令归拢成一个 Case。
    # 注意：子 shell 处在 if 的条件语境里，bash 会屏蔽 errexit——里面写的 set -e
    # 不生效，中途失败不会中断后续命令，子 shell 的退出码也只等于最后一条命令的。
    # 这一点是刻意保留的：Case 的清理步骤都排在末尾，中途断掉会把脏环境留给后面的
    # Case。Case 的真实成败由 report.sh 的 case_end 回查本 Case 的 doctest 结果兜底
    # （见 _case_has_failed_doctest），不要依赖这里的 set -e。
    if (
        set -e
        # 安装网格和应用
        ./run.sh --project mesh --file install-mesh
        # Pod Security Admission：给 istio / istio-waypoint 两个网关类打 seccompProfile overlay，
        # 使 Gateway API 网关与 waypoint 能被 Restricted 命名空间准入（须在建 Gateway 之前）
        ./run.sh --project mesh --file pod-security-admission
        # 入口网关 (sidecar 模式) 测试：复用 sidecar 控制面（含 IstioCNI），各自带清理。
        # 两篇都要把网关 Service 改成 type: LoadBalancer 再取 EXTERNAL-IP 发流量，
        # 没有 MetalLB 就永远等不到地址、必然失败，故受 ENABLE_METALLB 门控
        # （天翼云 openSUSE MicroOS 暂不支持自动配 VIP，dailybuild 已置 false）。
        if [ "${ENABLE_METALLB:-false}" = "true" ]; then
            ./run.sh --project mesh --file exposing-a-service-via-istio-gateway --no-cleanup
            ./run.sh --project mesh --file exposing-a-service-via-istio-gateway --cleanup-only
            ./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-sidecar-mode --no-cleanup
            ./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-sidecar-mode --cleanup-only
        else
            log_warn "ENABLE_METALLB != true，跳过入口网关 LoadBalancer 测试 (exposing-a-service-via-istio-gateway / exposing-a-service-via-k8s-gateway-api-in-sidecar-mode)"
        fi
        # 出口网关 (sidecar 模式) 测试：需要集群侧访问外网（httpbingo.org），
        # 离线环境用 CASE_TYPE 的 `not egress` 排除。
        # 注：doctest_selected 内部 case_selected 遇表达式非法会 exit 1，但这里处于
        # `(set -e; ...)` 子 shell 内，exit 只会终止该子 shell（外层 if 捕获非 0 状态转
        # 为 case_end 1 的失败），不会中止整个 Run。这不构成实际风险：本 Case 的
        # case_begin_if 已在顶层用同一 CASE_TYPE 校验过表达式合法性，若表达式非法在
        # 到达这里之前脚本就已经整体退出了。
        if doctest_selected egress; then
            ./run.sh --project mesh --file routing-egress-traffic-via-istio-apis --no-cleanup
            ./run.sh --project mesh --file routing-egress-traffic-via-istio-apis --cleanup-only
            ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-sidecar-mode --no-cleanup
            ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-sidecar-mode --cleanup-only
        fi
        ./run.sh --project mesh --file metrics-and-mesh
        ./run.sh --project mesh --file deploying-the-bookinfo-application --no-cleanup
        # 为 bookinfo 命名空间启用严格 mTLS（PeerAuthentication STRICT）
        ./run.sh --project mesh --file mtls --no-cleanup
        # 调用链集成：先装调用链平台，再配置网格上报，再装含调用链集成的 kiali
        # mesh 场景下由 bookinfo 业务流量产生 trace，无需 telemetrygen 端到端验证
        #
        # 调用链平台目前只有 Elasticsearch 一条可用的存储链，故装/卸两步受 DocTest 级
        # 标签 elasticsearch 门控（与下面 egress 同一套机制）：天翼云 openSUSE MicroOS
        # 根文件系统不可变只读，装不了 hostPath 方式的本地 ES 存储，dailybuild 环境没有
        # ES 可用。CASE_TYPE 未设置（本地手工全量跑）时照常执行，行为不变。
        # 中间的 config-with-service-mesh 与 kiali 不受门控：前者步骤 1 检测不到
        # jaeger-system 命名空间就跳过、后者检测不到 jaeger-collector svc 就跳过调用链
        # 集成部分，二者在没有调用链平台时都能跑完（Case 5 走的就是这条路径）。
        if doctest_selected elasticsearch; then
            ./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --skip-telemetrygen
        else
            log_warn "CASE_TYPE 未选中 elasticsearch，跳过调用链平台安装，网格调用链集成只做配置不校验链路"
        fi
        ./run.sh --project mesh --file config-with-service-mesh --no-cleanup
        ./run.sh --project mesh --file kiali
        # 清理（逆序）：先卸 kiali，再卸网格调用链配置，再卸调用链平台
        ./run.sh --project mesh --file uninstalling-alauda-build-of-kiali
        ./run.sh --project mesh --file config-with-service-mesh --cleanup-only
        if doctest_selected elasticsearch; then
            ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds --skip-cluster-plugin
        fi
        # 清理 bookinfo 命名空间的严格 mTLS 配置（在删除 bookinfo 前移除 PeerAuthentication）
        ./run.sh --project mesh --file mtls --cleanup-only
        ./run.sh --project mesh --file deploying-the-bookinfo-application --cleanup-only
        ./run.sh --project mesh --file uninstalling-alauda-service-mesh
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 4: Istio HA 配置测试
# ------------------------------------------------------------------
if case_begin_if "4" "Istio HA 配置测试" ha install; then
    if (
        set -e
        ./run.sh --project mesh --file install-mesh --force-init
        ./run.sh --project mesh --file configuring-istio-ha-by-using-autoscaling
        ./run.sh --project mesh --file uninstalling-alauda-service-mesh --skip-operator-and-crds
        ./run.sh --project mesh --file install-mesh
        ./run.sh --project mesh --file configuring-istio-ha-by-using-replica-count
        ./run.sh --project mesh --file uninstalling-alauda-service-mesh --skip-operator-and-crds
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 5: Ambient Mode 安装测试
# ------------------------------------------------------------------
if case_begin_if "5" "Ambient Mode 安装测试" smoke install ambient; then
    if (
        set -e
        # 安装 ambient 网格和应用（operator 可能已经被删除，所以要 --force-init）
        ./run.sh --project mesh --file installing-ambient-mode --force-init
        ./run.sh --project mesh --file metrics-and-mesh
        ./run.sh --project mesh --file deploying-ambient-bookinfo --no-cleanup
        # 为 bookinfo 命名空间启用严格 mTLS（PeerAuthentication STRICT）
        ./run.sh --project mesh --file mtls --no-cleanup
        ./run.sh --project mesh --file config-with-service-mesh --no-cleanup
        ./run.sh --project mesh --file kiali
        ./run.sh --project mesh --file waypoint-proxies
        # L7 特性测试（独立测试，包含清理步骤）
        ./run.sh --project mesh --file ambient-l7-features --no-cleanup
        ./run.sh --project mesh --file ambient-l7-features --cleanup-only
        # 入口网关 K8S Gateway API 测试（集群需要支持 `LoadBalancer`）：
        # 同 Case 3，取不到 EXTERNAL-IP 必然失败，故受 ENABLE_METALLB 门控。
        if [ "${ENABLE_METALLB:-false}" = "true" ]; then
            ./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-ambient-mode --no-cleanup
            ./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-ambient-mode --cleanup-only
        else
            log_warn "ENABLE_METALLB != true，跳过入口网关 LoadBalancer 测试 (exposing-a-service-via-k8s-gateway-api-in-ambient-mode)"
        fi
        # 出口网关 (Egress Gateway) 测试：同上，需要集群侧访问外网，离线环境用
        # CASE_TYPE 的 `not egress` 排除。
        # 注：doctest_selected 遇表达式非法会 exit 1，这里的 exit 只会终止本
        # `(set -e; ...)` 子 shell（外层 if 捕获非 0 转为 case_end 1），不会中止
        # 整个 Run——因为本 Case 的 case_begin_if 已在顶层校验过表达式合法性，
        # 非法表达式根本不会执行到这里。
        if doctest_selected egress; then
            ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode --no-cleanup
            ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode --cleanup-only
        fi
        # 清理 bookinfo 命名空间的严格 mTLS 配置（在卸载网格前移除 PeerAuthentication）
        ./run.sh --project mesh --file mtls --cleanup-only
        # 卸载 kiali
        ./run.sh --project mesh --file uninstalling-alauda-build-of-kiali
        # 卸载 ambient 网格
        ./run.sh --project mesh --file uninstalling-alauda-service-mesh-in-ambient-mode
        # 清理 bookinfo
        ./run.sh --project mesh --file deploying-ambient-bookinfo --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 6: 多集群 - 多主多网络拓扑 (Multi-Primary Multi-Network)
# 注：会切换到双集群 kubeconfig，必须放在所有单集群 case 之后
# ------------------------------------------------------------------
if [ "${ENABLE_METALLB:-false}" != "true" ]; then
    # 两种拓扑都靠东西向网关的 LoadBalancer 地址互联（install-multi-primary-multi-network
    # 与 install-primary-remote-multi-network 都会读 .status.loadBalancer.ingress[0].ip），
    # 没有 MetalLB 就取不到地址、必然失败，直接按环境不支持跳过。
    case_skip "6" "多集群-多主多网络拓扑" "ENABLE_METALLB != true（东西向网关需要 LoadBalancer 地址）" env
    case_skip "7" "多集群-主-远多网络拓扑" "ENABLE_METALLB != true（东西向网关需要 LoadBalancer 地址）" env
elif [ -z "${EAST_CLUSTER_NAME:-}" ] || [ -z "${WEST_CLUSTER_NAME:-}" ]; then
    case_skip "6" "多集群-多主多网络拓扑" "未设置 EAST_CLUSTER_NAME / WEST_CLUSTER_NAME" env
    case_skip "7" "多集群-主-远多网络拓扑" "未设置 EAST_CLUSTER_NAME / WEST_CLUSTER_NAME" env
else
    if case_begin_if "6" "多集群 - 多主多网络拓扑 (Multi-Primary Multi-Network)" multicluster; then
        if (
            set -e
            # 切到双集群 kubeconfig
            ./run.sh --project mesh --init-only --cluster "$EAST_CLUSTER_NAME" --cluster "$WEST_CLUSTER_NAME"
            # 公共前置: 生成 CA 证书并下发 cacerts 到两个集群
            ./run.sh --project mesh --file configuration-overview
            # 多主多网络安装 + 验证 + 卸载
            ./run.sh --project mesh --file install-multi-primary-multi-network --no-cleanup
            ./run.sh --project mesh --file install-multi-primary-multi-network --cleanup-only
        ); then
            case_end 0
        else
            case_end 1
        fi
    fi

    # ------------------------------------------------------------------
    # Case 7: 多集群 - 主-远多网络拓扑 (Primary-Remote Multi-Network)
    # ------------------------------------------------------------------
    if case_begin_if "7" "多集群 - 主-远多网络拓扑 (Primary-Remote Multi-Network)" multicluster; then
        if (
            set -e
            # 重新初始化双集群 kubeconfig (Case 7 卸载后保险一步,确保上下文干净)
            ./run.sh --project mesh --init-only --cluster "$EAST_CLUSTER_NAME" --cluster "$WEST_CLUSTER_NAME"
            # 重新下发 cacerts (Case 7 cleanup 已删除 istio-system,需要重建)
            ./run.sh --project mesh --file configuration-overview
            # 主-远多网络安装 + 验证 + 卸载
            ./run.sh --project mesh --file install-primary-remote-multi-network --no-cleanup
            ./run.sh --project mesh --file install-primary-remote-multi-network --cleanup-only
        ); then
            case_end 0
        else
            case_end 1
        fi
    fi
fi

# ------------------------------------------------------------------
# Case 8: InPlace 更新策略测试（含 Istio CNI 升级）
# 顺序：update-inplace --no-cleanup 完整更新流程 → --cleanup-only 统一清理
# 注：Istio CNI 升级已并入 update-inplace 文档步骤 4（测试经公共步骤库
#     istio-cni-update-steps.sh 执行），不再单独调用 --file istio-cni
# ------------------------------------------------------------------
if case_begin_if "8" "InPlace 更新策略测试（含 Istio CNI 升级）(Update InPlace + Istio CNI)" update; then
    if (
        set -e
        ./run.sh --project mesh --file update-inplace --no-cleanup --force-init
        ./run.sh --project mesh --file update-inplace --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 9: RevisionBased 更新策略测试（含 Istio CNI 升级）
# 顺序：update-revisionbased --no-cleanup 安装+升级验证 → --cleanup-only 统一清理
# 注：Istio CNI 升级已并入 update-revisionbased 文档步骤 5（公共步骤库执行）
# ------------------------------------------------------------------
if case_begin_if "9" "RevisionBased 更新策略测试 (Update RevisionBased)" update; then
    if (
        set -e
        ./run.sh --project mesh --file update-revisionbased --no-cleanup --force-init
        ./run.sh --project mesh --file update-revisionbased --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 10: RevisionBased + IstioRevisionTag 更新策略测试（含 Istio CNI 升级）
# 顺序：update-revisionbased-and-istiorevisiontag --no-cleanup 安装+升级验证 → --cleanup-only 统一清理
# 注：Istio CNI 升级已并入 update-revisionbased-and-istiorevisiontag 文档步骤 5（公共步骤库执行）
# ------------------------------------------------------------------
if case_begin_if "10" "RevisionBased + IstioRevisionTag 更新策略测试 (Update RevisionBased + IstioRevisionTag)" update; then
    if (
        set -e
        ./run.sh --project mesh --file update-revisionbased-and-istiorevisiontag --no-cleanup --force-init
        ./run.sh --project mesh --file update-revisionbased-and-istiorevisiontag --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 11: Ambient 模式更新测试 (Update Ambient Mode)
# 顺序：updating-ambient-components --no-cleanup 铺垫 v1.28.3 ambient 环境并升级三组件到 v1.28.6
#       → waypoint-proxies 部署 waypoint（复用 Case 5 测试，bookinfo 已由上一步就绪）
#       → updating-waypoint-proxies 验证 waypoint 版本与 L7 行为（自带 curl 前置）
#       → updating-ambient-components --cleanup-only 统一清理（waypoint 随 bookinfo 命名空间回收）
# ------------------------------------------------------------------
if case_begin_if "11" "Ambient 模式更新测试 (Update Ambient Mode)" update ambient; then
    if (
        set -e
        ./run.sh --project mesh --file updating-ambient-components --no-cleanup --force-init
        ./run.sh --project mesh --file waypoint-proxies
        ./run.sh --project mesh --file updating-waypoint-proxies --no-cleanup
        ./run.sh --project mesh --file updating-waypoint-proxies --cleanup-only
        ./run.sh --project mesh --file updating-ambient-components --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

log_header "mesh 项目所有测试任务执行完成！"

# 注意：report_finalize 已通过 trap 注册，脚本退出时自动汇总三层报告，此处无需再次调用
