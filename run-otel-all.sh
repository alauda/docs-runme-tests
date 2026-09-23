#!/usr/bin/env bash
# otel 项目全量测试编排脚本
# 执行 Alauda Build of OpenTelemetry v2 文档的所有测试任务

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
report_init otel
trap report_finalize EXIT

log_header "开始执行 otel 项目所有测试任务"

# ------------------------------------------------------------------
# Case 1: OpenTelemetry v2 安装与卸载测试
# 安装覆盖 install-opentelemetry.mdx 全部 CLI 章节（Operator + Collector）
# 卸载覆盖 uninstalling-opentelemetry.mdx 全部 CLI 章节（Instrumentation/Collector/Subscription/CRDs）
# 注：跨 suite 复用 OTel Operator 的场景，调用方可加 --skip-operator-and-crds 保留 Operator 与 CRDs。
#
# 执行顺序（前后依赖）：
#   1) rbac-resources：先授予 Operator 管理集群级 RBAC 的权限。须在装 Operator 之前完成，
#      Operator 启动即可探测到该能力（文档中重启 Operator 为可选步骤）。带 --force-init
#      承担本 Case 的环境初始化。
#   2) install-opentelemetry：安装 Operator + 部署 Collector。
#   3) without-sidecar：以 deployment 模式部署带 k8s_attributes 处理器的 Collector，
#      观察日志 30s 无 error，验证 Operator 自动创建集群级 RBAC 确实生效。
#   4) 清理按依赖逆序：without-sidecar（Collector 的 finalizer 需要 Operator 与 RBAC 授权
#      仍在位才能回收自动生成的集群级 RBAC）→ uninstalling-opentelemetry → rbac-resources。
# ------------------------------------------------------------------
if case_begin_if "1" "OpenTelemetry v2 安装与卸载测试" smoke install; then
    if (
        set -e
        ./run.sh --project otel --file rbac-resources --force-init --no-cleanup
        ./run.sh --project otel --file install-opentelemetry --force-init
        ./run.sh --project otel --file without-sidecar --no-cleanup
        # 清理
        ./run.sh --project otel --file without-sidecar --cleanup-only
        ./run.sh --project otel --file uninstalling-opentelemetry
        ./run.sh --project otel --file rbac-resources --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 2: Java 自动注入示例服务（mesh-v2-test-suite 插件）
# 前置：USE_MESH_V2_TEST_SUITE_PLUGIN=true（已装 mesh-v2-test-suite 集群插件，提供
#       cpaas-system/mesh-v2-test-suite-java-otel-demo ConfigMap 与配套镜像）；未设置时
#       java-instrumentation 测试以 SKIPPED 退出，不阻断编排。
# 顺序：先装 Operator + Collector（Java demo 依赖 Operator 的 Instrumentation CRD 与
#       自动注入 webhook，而 Case 1 收尾已把 Operator 与 CRDs 卸干净，故这里必须自己装）
#       → 部署 Java OTel demo → 卸载 Java OTel demo → 卸载 Operator 与 CRDs。
#
# 与 Case 3 的区别：本 Case 只验「Operator 自动注入 Java agent」这一能力，不装调用链平台，
# 因而不依赖任何存储后端，可以进 dailybuild 的 smoke 集合；span 真正上报到调用链的完整
# 链路由 Case 3 覆盖。
# ------------------------------------------------------------------
if case_begin_if "2" "Java 自动注入示例服务 (Java Instrumentation Demo)" smoke install java; then
    if (
        set -e
        ./run.sh --project otel --file install-opentelemetry --force-init
        ./run.sh --project otel --file java-instrumentation --no-cleanup
        # 清理
        ./run.sh --project otel --file java-instrumentation --cleanup-only
        ./run.sh --project otel --file uninstalling-opentelemetry
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 3: Java 自动注入示例服务（mesh-v2-test-suite 插件）+ 分布式调用链
# 前置：同 Case 2 的 USE_MESH_V2_TEST_SUITE_PLUGIN=true。
# 顺序：先装分布式调用链（提供 jaeger-system 的 OTel Collector 作为 javaagent 导出端点，
#       其步骤 2 会自动装好前置依赖 OTel Operator）→ 部署 Java OTel demo
#       → 卸载 Java OTel demo → 卸载分布式调用链。
#
# 标签带 opensearch、且**不带 smoke**：存储后端走 OpenSearch 链——安装测试的步骤 0 会按需
# 自动安装 TopoLVM + OpenSearch（幂等），存储落在被测业务集群自身，不再依赖 Global 集群的
# ACP 日志存储 Elasticsearch（天翼云 openSUSE MicroOS 根文件系统不可变只读，装不了 hostPath
# 方式的本地 ES 存储）。代价是 TopoLVM 要求业务集群至少 3 个节点、每个节点有空闲裸盘
# （默认 /dev/vdb），dailybuild 的 asm-1 未挂数据盘，故暂不带 smoke；环境支持后补上 smoke
# 即可，release-config 里 CASE_TYPE 的表达式不用改。
# ------------------------------------------------------------------
if case_begin_if "3" "Java 自动注入示例服务 + 分布式调用链 (Java Instrumentation Demo)" install java opensearch; then
    if (
        set -e
        ./run.sh --project tracing --file installing-distributed-tracing-opensearch --skip-telemetrygen --force-init
        ./run.sh --project otel --file java-instrumentation --no-cleanup
        # 清理
        ./run.sh --project otel --file java-instrumentation --cleanup-only
        ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds --skip-cluster-plugin
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

log_header "otel 项目所有测试任务执行完成！"

# 注意：report_finalize 已通过 trap 注册，脚本退出时自动汇总三层报告，此处无需再次调用
