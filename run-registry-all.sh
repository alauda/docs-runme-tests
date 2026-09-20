#!/usr/bin/env bash
# registry 项目全量测试编排脚本
# 执行 Alauda Container Platform Registry 文档的所有测试任务
#
# ── 前置 ──────────────────────────────────────────────────────────────────────
# 需要一个 ACP 4.4 环境。二选一：
#   A. 已有环境：导出 PLATFORM_ADDRESS / PLATFORM_USERNAME / PLATFORM_PASSWORD
#   B. 现场造：./provision.sh --project registry   （天翼云路径，见 provision-ctyun.sh）
#
# ── 与 mesh/otel/tracing 的差异 ───────────────────────────────────────────────
# Registry 是**平台内置能力**，不是可安装的集群插件：
#   - 被测对象是 image-registry-system 里的 cluster-image-registry-operator
#   - Operator 包不在全新 ACP 环境的 OperatorHub 里，project_init 负责上架
#   - 存储后端默认走 emptyDir（临时），因为文档明确说明这是快速起步路径；
#     需要持久化的场景由 PVC 用例覆盖（本编排不含，见「暂不纳入」）

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
report_init registry
trap report_finalize EXIT

log_header "开始执行 registry 项目所有测试任务"

# ------------------------------------------------------------------
# Case 1: Registry Operator 安装与状态
# 覆盖 image_registry_operator.mdx 的安装路径与状态检查。
#
# 关键点：Operator 包必须在 OperatorHub 里存在，否则 Subscription 会被
# check-subscription.cpaas.io 准入 webhook 拒（文档 § Install by Using YAML 的第一步）。
# project_init 已负责上架；本 Case 的步骤 0 再断言一次，让失败原因一眼可见。
#
# 顺序：安装（含命名空间、label、Subscription、InstallPlan 审批、CSV 就绪）
#       → 状态检查（Config/cluster 条件、组件清单、APIService）
# 不卸载：Registry 是平台能力，后续 Case 都依赖它。
# ------------------------------------------------------------------
if case_begin_if "1" "Registry Operator 安装与状态" smoke install registry operator; then
    if (
        set -e
        ./run.sh --project registry --file image-registry-operator --force-init --no-cleanup
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 2: 存储配置与 Registry 启用
# 覆盖 setting_up_and_configuring_the_registry.mdx 的 emptyDir 起步路径。
#
# 为什么先 emptyDir：文档把它列为快速起步路径，且不依赖任何外部存储，
# 是唯一能在无存储后端的 dailybuild 环境上跑通的选项。
# 踩过的坑：managementState 无默认值，未设置时 Config/cluster 报
# Available=True (Removed)，image-registry / image-api-server 根本不存在——
# 而文档 § Check Operator and Registry Status 的期望是它们都在。
#
# 同时断言 storage.oss 不可用（文档未说明该字段是上游继承但未实现）。
# ------------------------------------------------------------------
if case_begin_if "2" "Registry 存储配置与启用" smoke install storage; then
    if (
        set -e
        ./run.sh --project registry --file setting-up-and-configuring-the-registry --no-cleanup
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 3: 访问 Registry 与镜像管理
# 覆盖 accessing_the_registry.mdx 与 managing_images_with_ac.mdx。
#
# 前置：Case 2 已把 Registry 启用（本 Case 用 --force-init 保证独立可跑）。
# 断言重点：
#   - ac config set-registry-mode modern / legacy 双向可切
#   - ac registry info / --internal 的输出形态
#   - ImageStream / ImageStreamTag / Image 三层元数据
#   - ac import-image / ac tag / ac get images 的输出列位置
#     （文档的 awk 依赖这些列位置，错了会静默产出垃圾）
# ------------------------------------------------------------------
if case_begin_if "3" "Registry 访问与镜像管理" smoke install images; then
    if (
        set -e
        ./run.sh --project registry --file accessing-the-registry --force-init --no-cleanup
        ./run.sh --project registry --file managing-images-with-ac --no-cleanup
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 4: 权限、用量与清理
# 覆盖 managing_access_and_cleanup.mdx。
#
# 断言重点：
#   - 7 个 ClusterRole 全部存在
#   - 权限检查必须用 SubjectAccessReview，不能用 kubectl auth can-i
#     （registry/metrics 不在 API discovery 里，can-i 恒返回 no，
#       文档原来的写法会误导管理员以为配置失败）
#   - ac adm top / prune images / registry gc 的 dry-run 语义
# ------------------------------------------------------------------
if case_begin_if "4" "Registry 权限、用量与清理" install cleanup; then
    if (
        set -e
        ./run.sh --project registry --file managing-access-and-cleanup --force-init
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 5: 暴露 Registry
# 覆盖 exposing_the_registry.mdx 的 defaultRoute 与自定义路由。
#
# 环境能力差异：defaultRoute 依赖 LoadBalancer / Ingress 控制器。
# 无该能力时用例应 skip_test_env，而不是失败——环境能力不要用标签表达。
# ------------------------------------------------------------------
if case_begin_if "5" "Registry 暴露（Ingress / 自定义路由）" install exposing; then
    if [ "${ENABLE_REGISTRY_EXPOSING:-true}" != "true" ]; then
        case_skip "5" "Registry 暴露（Ingress / 自定义路由）" "环境未启用 LoadBalancer / Ingress 能力" env
    elif (
        set -e
        ./run.sh --project registry --file exposing-the-registry --force-init
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# 说明：Operator 升级不单列 Case
#
# § Upgrade 是 image_registry_operator.mdx 的一节，不是独立文档，
# 其测试步骤已在 Case 1 的测试脚本里（_registry_step_upgrade），
# 由 REGISTRY_UPGRADE_PACKAGE_URL 门控：未提供时 skip_test_env，
# 不会让 Case 1 失败。单列 Case 会重复执行同一份脚本。
# ------------------------------------------------------------------

log_header "registry 项目所有测试任务执行完成！"

# 注意：report_finalize 已通过 trap 注册，脚本退出时自动汇总三层报告，此处无需再次调用
