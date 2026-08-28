#!/usr/bin/env bash
# tracing 项目全量测试编排脚本
# 执行 Alauda Distributed Tracing 文档的所有测试任务
#
# 要求:
#   - 环境初始化（Case 1）: 只做 kubeconfig 拉取、OTel Operator 插件包上架与
#     mesh-v2-test-suite 集群插件安装，不碰任何存储后端。带 smoke 标签——两条存储链
#     （Elasticsearch / OpenSearch）目前都不带 smoke，本 Case 是 dailybuild 的
#     docs-tracing 测试项唯一会选中的 Case，没有它该测试项就一个用例都不跑。
#   - Elasticsearch 链（Case 2）: 默认通过 TRACING_ACP_ES_CLUSTER（默认 global）自动读取 ACP ES 配置；
#     若 TRACING_ACP_ES_CLUSTER 为空，则使用 TRACING_ES_ENDPOINT / TRACING_ES_USER / TRACING_ES_PASS。
#     TRACING_INSTALL_ES=true 且 PKG_LOG_CENTER_URL 非空时，安装测试的步骤 0 会先把 logcenter
#     集群插件（ACP 日志存储 Elasticsearch，Single Node 模式）自动安装到 TRACING_ACP_ES_CLUSTER
#     指定集群——对应集群已安装过则跳过（幂等，见 projects/tracing/elasticsearch.sh）。
#     **不带 smoke 标签**：天翼云 openSUSE MicroOS 的根文件系统只读，装不了 hostPath 方式的
#     本地 ES 存储，dailybuild 环境没有 ES 可用（详见下方「存储后端与 dailybuild」）。
#   - OpenSearch 链（Case 3）: 默认自动安装 OpenSearch（TRACING_INSTALL_OPENSEARCH=true 且
#     PKG_ACP_STORAGE_OPERATOR_URL / PKG_TOPOLVM_OPERATOR_URL 齐全时，安装测试的步骤 0 自动
#     安装 TopoLVM + OpenSearch 并覆盖 TRACING_OPENSEARCH_*，幂等；opensearch-operator 插件包
#     目前需手动 violet 上架，见 projects/tracing/opensearch.sh 的 TODO）。自动安装条件不满足时
#     降级用手动 TRACING_OPENSEARCH_ENDPOINT / USER / PASS；两者皆缺则 Case 3 自动 SKIPPED。
#     前提：ACP 离线环境、业务集群至少 3 个节点、各节点有空闲磁盘（默认 /dev/vdb）。
#   - SPM 多副本（高可用）验证（Case 4/5）: 各自复用安装链装好 SPM 后，将 otel/jaeger 扩容到
#     多副本并校验单写入者（每个 service 只被一个 Jaeger 副本聚合）；OpenSearch 存储后端
#     不可用时 Case 5 自动 SKIPPED。可选环境变量：SPM_HA_REPLICAS（默认 2）、SPM_HA_SVC_COUNT（默认 6）。
#   - v2.0 → v2.1 升级（Case 6/7）: 要求环境上**已存在一套 v2.0 部署**（Jaeger 2.16.0 +
#     Alauda Build of OpenTelemetry v2 Operator 0.147.0）。测试脚本按存储后端与配置里的
#     v2.0 特征字段做门槛，检测不到就 SKIPPED，不会误伤 Case 2-5 装出来的 v2.1 环境。
#     一套环境只能有一种存储后端，故 Case 6/7 至多命中其一。
#
# 存储后端与 dailybuild:
#   Case 2/4（Elasticsearch）与 Case 3/5（OpenSearch）都不带 smoke 标签，dailybuild 的
#   docs-tracing 测试项（CASE_TYPE="smoke and not egress and not elasticsearch"）一个都选不中。
#   - Elasticsearch: 天翼云 MicroOS 根文件系统不可变只读，不支持 hostPath 方式部署本地 ES 存储，
#     dailybuild 环境的 asm-1 集群已去掉 log_storage 声明；环境支持后把 smoke 标签加回
#     Case 2/4，并去掉 CASE_TYPE 里的 `and not elasticsearch` 即可。
#   - OpenSearch: 需要业务集群各节点有空闲裸盘（TopoLVM），dailybuild 的 asm-1 未挂数据盘；
#     环境支持后给 Case 3/5 补 smoke 标签即可，表达式不用改。

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
# Case 1: 环境初始化（默认使用 SINGLE_CLUSTER_NAME）
# 拉取 kubeconfig、上架 OTel Operator 插件包（verify-only 时跳过）、安装
# mesh-v2-test-suite 集群插件；不依赖任何存储后端，因此环境不支持 ES / OpenSearch
# 时它仍然跑得通。
# 标签取 smoke 而非 mesh 那样的 always：tracing 的其余 Case 各自带 --force-init，
# 本 Case 的作用是让 dailybuild 的 docs-tracing 测试项有实际内容可跑。
# 初始化失败后面全都白跑，故用 case_end_fatal 立即中止并汇总报告。
# ------------------------------------------------------------------
if case_begin_if "1" "环境初始化（默认 SINGLE_CLUSTER_NAME）" smoke install; then
    if (
        set -e
        ./run.sh --project tracing --init-only
    ); then
        case_end 0
    else
        case_end_fatal 1
    fi
fi

# ------------------------------------------------------------------
# Case 2: 分布式调用链安装与卸载测试 (Elasticsearch)
# install --force-init 会自动上传 OTel Operator 插件包（安装的前置依赖）；
# 安装测试步骤 1 按文档 CLI 章节安装 Jaeger v2 集群插件（PKG_JAEGER_CLUSTER_PLUGIN_URL，
# 未上架时自动下载上架，幂等），步骤 2 负责安装 OTel Operator 本身。
# TRACING_INSTALL_ES=true 时步骤 0 自动安装 logcenter 集群插件（幂等，已安装跳过）。
# ------------------------------------------------------------------
if case_begin_if "2" "分布式调用链安装与卸载测试 (Elasticsearch)" install elasticsearch; then
    if (
        set -e
        ./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --force-init
        # 清理
        ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds --skip-cluster-plugin
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 3: 分布式调用链安装与卸载测试 (OpenSearch)
# 环境已由 Case 2 --force-init 初始化（OTel Operator 插件包、kubeconfig），此处无需重复。
# 安装测试步骤 0 负责准备 OpenSearch 存储后端（默认自动安装：TopoLVM 插件包下载上架
# 也在步骤 0 内按需执行，TopoLVM + OpenSearch 安装幂等），步骤 1 安装 Jaeger v2 集群插件
# （Case 2 已装则幂等复用），步骤 2 负责安装 OTel Operator 本身。
# 自动安装与手动 TRACING_OPENSEARCH_* 均不可用时安装测试 SKIPPED、
# 卸载按命名空间存在性 SKIPPED，不阻断编排。
# ------------------------------------------------------------------
if case_begin_if "3" "分布式调用链安装与卸载测试 (OpenSearch)" install opensearch; then
    if (
        set -e
        ./run.sh --project tracing --file installing-distributed-tracing-opensearch
        # 清理
        ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds --skip-cluster-plugin
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 4: SPM 多副本（高可用）验证 (Elasticsearch)
# 复用安装链装好组件并启用 SPM（--skip-telemetrygen 仅跳过安装自带的 telemetrygen，
# 不影响 SPM 新方案配置的应用）；再由 spm-ha 测试把 otel/jaeger 扩容到多副本，
# 校验每个 service 只被一个 Jaeger 副本聚合 spanmetrics（单写入者），最后缩容并卸载。
# 不修改任何 mdx 文档，多副本验证完全在测试脚本内通过 kubectl 完成。
# ------------------------------------------------------------------
if case_begin_if "4" "SPM 多副本（高可用）验证 (Elasticsearch)" ha elasticsearch; then
    if (
        set -e
        ./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --skip-telemetrygen
        ./run.sh --project tracing --file spm-ha-elasticsearch --no-cleanup
        ./run.sh --project tracing --file spm-ha-elasticsearch --cleanup-only
        # 清理
        ./run.sh --project tracing --file uninstalling-distributed-tracing --skip-operator-and-crds --skip-cluster-plugin
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 5: SPM 多副本（高可用）验证 (OpenSearch)
# 同 Case 4，但走 OpenSearch 安装链（步骤 0 的 OpenSearch 自动安装幂等，Case 3 已装好
# 时直接复用）。OpenSearch 存储后端不可用时安装 SKIPPED，随后 spm-ha-opensearch 因
# 检测不到已安装的 otel 实例而自动 SKIPPED，不阻断编排。
# ------------------------------------------------------------------
if case_begin_if "5" "SPM 多副本（高可用）验证 (OpenSearch)" ha opensearch; then
    if (
        set -e
        ./run.sh --project tracing --file installing-distributed-tracing-opensearch --skip-telemetrygen
        ./run.sh --project tracing --file spm-ha-opensearch --no-cleanup
        ./run.sh --project tracing --file spm-ha-opensearch --cleanup-only
        # 清理
        ./run.sh --project tracing --file uninstalling-distributed-tracing
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 6: 分布式调用链 v2.0 → v2.1 升级测试 (Elasticsearch)
# 前置：环境上已有一套 Elasticsearch 后端的 v2.0 部署（本编排不负责搭建）。
# 升级文档没有清理步骤代码块，故无 cleanup 函数，直接执行、不拆两步。
# 升级后环境即为 v2.1，重复执行会因门槛检测（找不到 use_aliases/use_ilm）而 SKIPPED。
# ------------------------------------------------------------------
if case_begin_if "6" "分布式调用链 v2.0→v2.1 升级测试 (Elasticsearch)" upgrade elasticsearch; then
    if (
        set -e
        ./run.sh --project tracing --file upgrading-distributed-tracing-elasticsearch
        # 清理
        ./run.sh --project tracing --file uninstalling-distributed-tracing
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

# ------------------------------------------------------------------
# Case 7: 分布式调用链 v2.0 → v2.1 升级测试 (OpenSearch)
# 同 Case 6，但走 OpenSearch 链：额外覆盖「按天日期索引 → ISM + 别名轮转」的迁移。
# 前置同样是一套 v2.0 部署；不满足时门槛检测 SKIPPED，不阻断编排。
# ------------------------------------------------------------------
if case_begin_if "7" "分布式调用链 v2.0→v2.1 升级测试 (OpenSearch)" upgrade opensearch; then
    if (
        set -e
        ./run.sh --project tracing --file upgrading-distributed-tracing-opensearch
        # 清理
        ./run.sh --project tracing --file uninstalling-distributed-tracing
    ); then
        case_end 0
    else
        case_end 1
    fi
fi

log_header "tracing 项目所有测试任务执行完成！"

# 注意：report_finalize 已通过 trap 注册，脚本退出时自动汇总三层报告，此处无需再次调用
