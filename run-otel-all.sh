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
# Case 2: Java 自动注入示例服务（mesh-v2-test-suite 插件）+ 分布式调用链
# 前置：USE_MESH_V2_TEST_SUITE_PLUGIN=true（已装 mesh-v2-test-suite 集群插件，提供
#       cpaas-system/mesh-v2-test-suite-java-otel-demo ConfigMap 与配套镜像）；未设置时
#       java-instrumentation 测试以 SKIPPED 退出，不阻断编排。
# 顺序：先装分布式调用链（提供 jaeger-system 的 OTel Collector 作为 javaagent 导出端点）
#       → 部署 Java OTel demo → 卸载 Java OTel demo → 卸载分布式调用链。
# ------------------------------------------------------------------
if case_begin_if "2" "Java 自动注入示例服务 + 分布式调用链 (Java Instrumentation Demo)" smoke install java; then
    if (
        set -e
        ./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --skip-telemetrygen --force-init
        ./run.sh --project otel --file java-instrumentation --no-cleanup
        # 清理
        ./run.sh --project otel --file java-instrumentation --cleanup-only
        ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

log_header "otel 项目所有测试任务执行完成！"

# 注意：report_finalize 已通过 trap 注册，脚本退出时自动汇总三层报告，此处无需再次调用
