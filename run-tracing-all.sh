#!/usr/bin/env bash
# tracing 项目全量测试编排脚本
# 执行 Alauda Distributed Tracing 文档的所有测试任务
#
# 要求:
#   - Elasticsearch 链（Case 1）: 默认通过 TRACING_ACP_ES_CLUSTER（默认 global）自动读取 ACP ES 配置；
#     若 TRACING_ACP_ES_CLUSTER 为空，则使用 TRACING_ES_ENDPOINT / TRACING_ES_USER / TRACING_ES_PASS。
#     TRACING_INSTALL_ES=true 且 PKG_LOG_CENTER_URL 非空时，安装测试的步骤 0 会先把 logcenter
#     集群插件（ACP 日志存储 Elasticsearch，Single Node 模式）自动安装到 TRACING_ACP_ES_CLUSTER
#     指定集群——对应集群已安装过则跳过（幂等，见 projects/tracing/elasticsearch.sh）。
#   - OpenSearch 链（Case 2）: 默认自动安装 OpenSearch（TRACING_INSTALL_OPENSEARCH=true 且
#     PKG_ACP_STORAGE_OPERATOR_URL / PKG_TOPOLVM_OPERATOR_URL 齐全时，安装测试的步骤 0 自动
#     安装 TopoLVM + OpenSearch 并覆盖 TRACING_OPENSEARCH_*，幂等；opensearch-operator 插件包
#     目前需手动 violet 上架，见 projects/tracing/opensearch.sh 的 TODO）。自动安装条件不满足时
#     降级用手动 TRACING_OPENSEARCH_ENDPOINT / USER / PASS；两者皆缺则 Case 2 自动 SKIPPED。
#     前提：ACP 离线环境、业务集群至少 3 个节点、各节点有空闲磁盘（默认 /dev/vdb）。
#   - SPM 多副本（高可用）验证（Case 3/4）: 各自复用安装链装好 SPM 后，将 otel/jaeger 扩容到
#     多副本并校验单写入者（每个 service 只被一个 Jaeger 副本聚合）；OpenSearch 存储后端
#     不可用时 Case 4 自动 SKIPPED。可选环境变量：SPM_HA_REPLICAS（默认 2）、SPM_HA_SVC_COUNT（默认 6）。

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
# 安装测试步骤 1 按文档 CLI 章节安装 Jaeger v2 集群插件（PKG_JAEGER_CLUSTER_PLUGIN_URL，
# 未上架时自动下载上架，幂等），步骤 2 负责安装 OTel Operator 本身。
# TRACING_INSTALL_ES=true 时步骤 0 自动安装 logcenter 集群插件（幂等，已安装跳过）。
# ------------------------------------------------------------------
if case_begin_if "1" "分布式调用链安装与卸载测试 (Elasticsearch)" smoke install elasticsearch; then
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
fi

# ------------------------------------------------------------------
# Case 2: 分布式调用链安装与卸载测试 (OpenSearch)
# 环境已由 Case 1 --force-init 初始化（OTel Operator 插件包、kubeconfig），此处无需重复。
# 安装测试步骤 0 负责准备 OpenSearch 存储后端（默认自动安装：TopoLVM 插件包下载上架
# 也在步骤 0 内按需执行，TopoLVM + OpenSearch 安装幂等），步骤 1 安装 Jaeger v2 集群插件
# （Case 1 已装则幂等复用），步骤 2 负责安装 OTel Operator 本身。
# 自动安装与手动 TRACING_OPENSEARCH_* 均不可用时安装测试 SKIPPED、
# 卸载按命名空间存在性 SKIPPED，不阻断编排。
# ------------------------------------------------------------------
if case_begin_if "2" "分布式调用链安装与卸载测试 (OpenSearch)" install opensearch; then
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
fi

# ------------------------------------------------------------------
# Case 3: SPM 多副本（高可用）验证 (Elasticsearch)
# 复用安装链装好组件并启用 SPM（--skip-telemetrygen 仅跳过安装自带的 telemetrygen，
# 不影响 SPM 新方案配置的应用）；再由 spm-ha 测试把 otel/jaeger 扩容到多副本，
# 校验每个 service 只被一个 Jaeger 副本聚合 spanmetrics（单写入者），最后缩容并卸载。
# 不修改任何 mdx 文档，多副本验证完全在测试脚本内通过 kubectl 完成。
# ------------------------------------------------------------------
if case_begin_if "3" "SPM 多副本（高可用）验证 (Elasticsearch)" smoke ha elasticsearch; then
    if (
        set -e
        ./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --skip-telemetrygen
        ./run.sh --project tracing --file spm-ha-elasticsearch --no-cleanup
        ./run.sh --project tracing --file spm-ha-elasticsearch --cleanup-only
        # 清理
        ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 4: SPM 多副本（高可用）验证 (OpenSearch)
# 同 Case 3，但走 OpenSearch 安装链（步骤 0 的 OpenSearch 自动安装幂等，Case 2 已装好
# 时直接复用）。OpenSearch 存储后端不可用时安装 SKIPPED，随后 spm-ha-opensearch 因
# 检测不到已安装的 otel 实例而自动 SKIPPED，不阻断编排。
# ------------------------------------------------------------------
if case_begin_if "4" "SPM 多副本（高可用）验证 (OpenSearch)" ha opensearch; then
    if (
        set -e
        ./run.sh --project tracing --file installing-distributed-tracing-opensearch --skip-telemetrygen
        ./run.sh --project tracing --file spm-ha-opensearch --no-cleanup
        ./run.sh --project tracing --file spm-ha-opensearch --cleanup-only
        # 清理
        ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

log_header "tracing 项目所有测试任务执行完成！"

# 注意：report_finalize 已通过 trap 注册，脚本退出时自动汇总三层报告，此处无需再次调用
