#!/usr/bin/env bash
# tracing 项目全量测试编排脚本
# 执行 Alauda Distributed Tracing 文档的所有测试任务
#
# 要求: TRACING_ES_ENDPOINT / TRACING_ES_USER / TRACING_ES_PASS 已设置，
#       否则安装与卸载测试均以 SKIPPED 退出（不阻塞 CI）。

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载公共函数
source "$SCRIPT_DIR/framework/common.sh"

# 确保在框架仓库根目录执行
cd "$SCRIPT_DIR"

# 注册退出时的回调函数，无论成功还是因错误退出，都会打印测试总结
trap print_test_summary EXIT

log_header "开始执行 tracing 项目所有测试任务"

# ------------------------------------------------------------------
# Case 1: 分布式调用链安装与卸载测试
# install --force-init 会自动上传 OTel Operator 插件包（安装的前置依赖）；
# 安装测试步骤 1 负责安装 OTel Operator 本身。
# ------------------------------------------------------------------
log_header "Case 1: 分布式调用链安装与卸载测试 (Distributed Tracing)"

if (
    set -e
    ./run.sh --project tracing --file installing-distributed-tracing --force-init
    ./run.sh --project tracing --file uninstalling-distributed-tracing
); then
    record_test_result 0
else
    record_test_result 1
    exit 1
fi

log_header "tracing 项目所有测试任务执行完成！"

# 注意：print_test_summary 已通过 trap 注册，脚本退出时会自动执行，此处无需再次调用
