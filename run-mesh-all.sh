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
# ------------------------------------------------------------------
case_begin "1" "环境初始化（默认 SINGLE_CLUSTER_NAME）"

if (
    set -e
    ./run.sh --project mesh --init-only
); then
    case_end 0
else
    case_end_fatal 1
fi

# ------------------------------------------------------------------
# Case 2: 双栈网格安装
# ------------------------------------------------------------------
if [ "${IS_DUAL_STACK:-false}" == "true" ]; then
    case_begin "2" "双栈网格安装测试 (Dual Stack)"
    if (
        set -e
        ./run.sh --project mesh --file install-mesh-in-dual-stack-mode --no-cleanup
        ./run.sh --project mesh --file install-mesh-in-dual-stack-mode --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
else
    case_skip "2" "双栈网格安装测试" "IS_DUAL_STACK != true"
fi

# ------------------------------------------------------------------
# Case 3: 单网格安装与应用测试（含调用链集成）
# 顺序：先装调用链再装 kiali；清理逆序（先卸 kiali、再卸调用链）。
# 卸载调用链使用 --skip-operator-and-crds 保留 OTel Operator 与 CRDs 供后续 case 复用。
# ------------------------------------------------------------------
case_begin "3" "单网格安装与应用测试 (Single Mesh & App + Tracing)"

# 使用子 shell ( cmds ) 将多个命令组合为一个原子 case
# 任何一个命令失败都会导致整个 block 返回非 0 状态
if (
    set -e
    # 安装网格和应用
    ./run.sh --project mesh --file install-mesh
    # 入口网关 (sidecar 模式) 测试：复用 sidecar 控制面（含 IstioCNI），各自带清理
    ./run.sh --project mesh --file exposing-a-service-via-istio-gateway --no-cleanup
    ./run.sh --project mesh --file exposing-a-service-via-istio-gateway --cleanup-only
    ./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-sidecar-mode --no-cleanup
    ./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-sidecar-mode --cleanup-only
    # 出口网关 (sidecar 模式) 测试：复用 sidecar 控制面（含 IstioCNI），各自带清理
    ./run.sh --project mesh --file routing-egress-traffic-via-istio-apis --no-cleanup
    ./run.sh --project mesh --file routing-egress-traffic-via-istio-apis --cleanup-only
    ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-sidecar-mode --no-cleanup
    ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-sidecar-mode --cleanup-only
    ./run.sh --project mesh --file metrics-and-mesh
    ./run.sh --project mesh --file deploying-the-bookinfo-application --no-cleanup
    # 调用链集成：先装调用链平台，再配置网格上报，再装含调用链集成的 kiali
    # mesh 场景下由 bookinfo 业务流量产生 trace，无需 telemetrygen 端到端验证
    ./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --skip-telemetrygen
    ./run.sh --project mesh --file config-with-service-mesh --no-cleanup
    ./run.sh --project mesh --file kiali
    # 清理（逆序）：先卸 kiali，再卸网格调用链配置，再卸调用链平台
    ./run.sh --project mesh --file uninstalling-alauda-build-of-kiali
    ./run.sh --project mesh --file config-with-service-mesh --cleanup-only
    ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds
    ./run.sh --project mesh --file deploying-the-bookinfo-application --cleanup-only
    ./run.sh --project mesh --file uninstalling-alauda-service-mesh
); then
    case_end 0
else
    case_end 1
fi

# ------------------------------------------------------------------
# Case 4: Istio HA 配置测试
# ------------------------------------------------------------------
case_begin "4" "Istio HA 配置测试"

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

# ------------------------------------------------------------------
# Case 5: Ambient Mode 安装测试
# ------------------------------------------------------------------
case_begin "5" "Ambient Mode 安装测试"

if (
    set -e
    # 安装 ambient 网格和应用（operator 可能已经被删除，所以要 --force-init）
    ./run.sh --project mesh --file installing-ambient-mode --force-init
    ./run.sh --project mesh --file metrics-and-mesh
    ./run.sh --project mesh --file deploying-ambient-bookinfo --no-cleanup
    ./run.sh --project mesh --file kiali
    ./run.sh --project mesh --file waypoint-proxies
    # L7 特性测试（独立测试，包含清理步骤）
    ./run.sh --project mesh --file ambient-l7-features --no-cleanup
    ./run.sh --project mesh --file ambient-l7-features --cleanup-only
    # 入口网关 K8S Gateway API 测试（集群需要支持 `LoadBalancer`）
    ./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-ambient-mode --no-cleanup
    ./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-ambient-mode --cleanup-only
    # 出口网关 (Egress Gateway) 测试
    ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode --no-cleanup
    ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode --cleanup-only
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

# ------------------------------------------------------------------
# Case 6: 多集群 - 多主多网络拓扑 (Multi-Primary Multi-Network)
# 注：会切换到双集群 kubeconfig，必须放在所有单集群 case 之后
# ------------------------------------------------------------------
if [ -z "${EAST_CLUSTER_NAME:-}" ] || [ -z "${WEST_CLUSTER_NAME:-}" ]; then
    case_skip "6" "多集群-多主多网络拓扑" "未设置 EAST_CLUSTER_NAME / WEST_CLUSTER_NAME"
    case_skip "7" "多集群-主-远多网络拓扑" "未设置 EAST_CLUSTER_NAME / WEST_CLUSTER_NAME"
else
    case_begin "6" "多集群 - 多主多网络拓扑 (Multi-Primary Multi-Network)"

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

    # ------------------------------------------------------------------
    # Case 7: 多集群 - 主-远多网络拓扑 (Primary-Remote Multi-Network)
    # ------------------------------------------------------------------
    case_begin "7" "多集群 - 主-远多网络拓扑 (Primary-Remote Multi-Network)"

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

# ------------------------------------------------------------------
# Case 8: InPlace 更新策略测试（含 Istio CNI 升级）
# 顺序：update-inplace --no-cleanup 完整更新流程 → --cleanup-only 统一清理
# 注：Istio CNI 升级已并入 update-inplace 文档步骤 4（测试经公共步骤库
#     istio-cni-update-steps.sh 执行），不再单独调用 --file istio-cni
# ------------------------------------------------------------------
case_begin "8" "InPlace 更新策略测试（含 Istio CNI 升级）(Update InPlace + Istio CNI)"

if (
    set -e
    ./run.sh --project mesh --file update-inplace --no-cleanup --force-init
    ./run.sh --project mesh --file update-inplace --cleanup-only
); then
    case_end 0
else
    case_end 1
fi

# ------------------------------------------------------------------
# Case 9: RevisionBased 更新策略测试（含 Istio CNI 升级）
# 顺序：update-revisionbased --no-cleanup 安装+升级验证 → --cleanup-only 统一清理
# 注：Istio CNI 升级已并入 update-revisionbased 文档步骤 5（公共步骤库执行）
# ------------------------------------------------------------------
case_begin "9" "RevisionBased 更新策略测试 (Update RevisionBased)"

if (
    set -e
    ./run.sh --project mesh --file update-revisionbased --no-cleanup --force-init
    ./run.sh --project mesh --file update-revisionbased --cleanup-only
); then
    case_end 0
else
    case_end 1
fi

# ------------------------------------------------------------------
# Case 10: RevisionBased + IstioRevisionTag 更新策略测试（含 Istio CNI 升级）
# 顺序：update-revisionbased-and-istiorevisiontag --no-cleanup 安装+升级验证 → --cleanup-only 统一清理
# 注：Istio CNI 升级已并入 update-revisionbased-and-istiorevisiontag 文档步骤 5（公共步骤库执行）
# ------------------------------------------------------------------
case_begin "10" "RevisionBased + IstioRevisionTag 更新策略测试 (Update RevisionBased + IstioRevisionTag)"

if (
    set -e
    ./run.sh --project mesh --file update-revisionbased-and-istiorevisiontag --no-cleanup --force-init
    ./run.sh --project mesh --file update-revisionbased-and-istiorevisiontag --cleanup-only
); then
    case_end 0
else
    case_end 1
fi

# ------------------------------------------------------------------
# Case 11: Ambient 模式更新测试 (Update Ambient Mode)
# 顺序：updating-ambient-components --no-cleanup 铺垫 v1.28.3 ambient 环境并升级三组件到 v1.28.6
#       → waypoint-proxies 部署 waypoint（复用 Case 5 测试，bookinfo 已由上一步就绪）
#       → updating-waypoint-proxies 验证 waypoint 版本与 L7 行为（自带 curl 前置）
#       → updating-ambient-components --cleanup-only 统一清理（waypoint 随 bookinfo 命名空间回收）
# ------------------------------------------------------------------
case_begin "11" "Ambient 模式更新测试 (Update Ambient Mode)"

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

log_header "mesh 项目所有测试任务执行完成！"

# 注意：report_finalize 已通过 trap 注册，脚本退出时自动汇总三层报告，此处无需再次调用
