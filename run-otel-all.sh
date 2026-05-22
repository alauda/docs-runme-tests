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
    ./run.sh --project otel --file uninstalling-opentelemetry
); then
    record_test_result 0
else
    record_test_result 1
    exit 1
fi

log_header "otel 项目所有测试任务执行完成！"

# 注意：print_test_summary 已通过 trap 注册，脚本退出时会自动执行，此处无需再次调用
