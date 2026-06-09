#!/usr/bin/env bash
# otel 项目全量测试编排脚本
# 执行 Alauda Build of OpenTelemetry v2 文档的所有测试任务

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载公共函数
source "$SCRIPT_DIR/framework/common.sh"

# 确保在框架仓库根目录执行
cd "$SCRIPT_DIR"

# 注册退出时的回调函数，无论成功还是因错误退出，都会打印测试总结
trap print_test_summary EXIT

log_header "开始执行 otel 项目所有测试任务"

# ------------------------------------------------------------------
# Case 1: OpenTelemetry v2 安装与卸载测试
# 安装覆盖 install-opentelemetry.mdx 全部 CLI 章节（Operator + Collector）
# 卸载覆盖 uninstalling-opentelemetry.mdx 全部 CLI 章节（Instrumentation/Collector/Subscription/CRDs）
# 注：跨 suite 复用 OTel Operator 的场景，调用方可加 --skip-operator-and-crds 保留 Operator 与 CRDs。
# ------------------------------------------------------------------
log_header "Case 1: OpenTelemetry v2 安装与卸载测试"

if (
    set -e
    ./run.sh --project otel --file install-opentelemetry --force-init
    # 清理
    ./run.sh --project otel --file uninstalling-opentelemetry
); then
    record_test_result 0
else
    record_test_result 1
    exit 1
fi

# ------------------------------------------------------------------
# Case 2: Java 自动注入示例服务（mesh-v2-test-suite 插件）+ 分布式调用链
# 前置：USE_MESH_V2_TEST_SUITE_PLUGIN=true（已装 mesh-v2-test-suite 集群插件，提供
#       cpaas-system/mesh-v2-test-suite-java-otel-demo ConfigMap 与配套镜像）；未设置时
#       java-instrumentation 测试以 SKIPPED 退出，不阻断编排。
# 顺序：先装分布式调用链（提供 jaeger-system 的 OTel Collector 作为 javaagent 导出端点）
#       → 部署 Java OTel demo → 卸载 Java OTel demo → 卸载分布式调用链。
# ------------------------------------------------------------------
log_header "Case 2: Java 自动注入示例服务 + 分布式调用链 (Java Instrumentation Demo)"

if (
    set -e
    ./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --skip-telemetrygen --force-init
    ./run.sh --project otel --file java-instrumentation --no-cleanup
    # 清理
    ./run.sh --project otel --file java-instrumentation --cleanup-only
    ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds
); then
    record_test_result 0
else
    record_test_result 1
    exit 1
fi

log_header "otel 项目所有测试任务执行完成！"

# 注意：print_test_summary 已通过 trap 注册，脚本退出时会自动执行，此处无需再次调用
