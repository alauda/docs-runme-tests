#!/usr/bin/env bash
# tracing 项目全量测试编排脚本
# 执行 Alauda Distributed Tracing 文档的所有测试任务
#
# 要求:
#   - Elasticsearch 链（Case 1）: 默认通过 TRACING_ACP_ES_CLUSTER（默认 global）自动读取 ACP ES 配置；
#     若 TRACING_ACP_ES_CLUSTER 为空，则使用 TRACING_ES_ENDPOINT / TRACING_ES_USER / TRACING_ES_PASS。
#   - OpenSearch 链（Case 2）: 仅支持手动配置 TRACING_OPENSEARCH_ENDPOINT / TRACING_OPENSEARCH_USER /
#     TRACING_OPENSEARCH_PASS；未设置时 Case 2 自动 SKIPPED。

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
report_init tracing
trap report_finalize EXIT

log_header "开始执行 tracing 项目所有测试任务"

# ------------------------------------------------------------------
# Case 1: 分布式调用链安装与卸载测试 (Elasticsearch)
# install --force-init 会自动上传 OTel Operator 插件包（安装的前置依赖）；
# 安装测试步骤 1 负责安装 OTel Operator 本身。
# ------------------------------------------------------------------
case_begin "1" "分布式调用链安装与卸载测试 (Elasticsearch)"

if (
    set -e
    ./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --force-init
    # 清理
    ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds
); then
    case_end 0
else
    case_end 1
fi

# ------------------------------------------------------------------
# Case 2: 分布式调用链安装与卸载测试 (OpenSearch)
# 环境已由 Case 1 --force-init 初始化（OTel Operator 插件包、kubeconfig），此处无需重复。
# 安装测试步骤 1 负责安装 OTel Operator 本身。
# 仅在设置了手动 TRACING_OPENSEARCH_* 时实际执行；否则安装测试 SKIPPED、
# 卸载按命名空间存在性 SKIPPED，不阻断编排。
# ------------------------------------------------------------------
case_begin "2" "分布式调用链安装与卸载测试 (OpenSearch)"

if (
    set -e
    ./run.sh --project tracing --file installing-distributed-tracing-opensearch
    # 清理
    ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds
); then
    case_end 0
else
    case_end 1
fi

log_header "tracing 项目所有测试任务执行完成！"

# 注意：report_finalize 已通过 trap 注册，脚本退出时自动汇总三层报告，此处无需再次调用
