# 使用方法

## 基本命令

```bash
cd docs-runme-tests

./run.sh --help

# 初始化某项目环境（--init-only 必须带 --project）
./run.sh --project mesh --init-only

# 多集群初始化（mesh 的 multi-cluster 文档；tracing 在多集群网格里也要两个集群都初始化）
./run.sh --project mesh --init-only --cluster "$EAST_CLUSTER_NAME" --cluster "$WEST_CLUSTER_NAME"

# 多集群环境里指定某篇单集群文档的执行目标（切换 kubeconfig 默认 context，不做初始化）
./run.sh --project mesh --file metrics-and-mesh --cluster "$WEST_CLUSTER_NAME"
./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --cluster "$WEST_CLUSTER_NAME"

# 测试指定文档（自动查找所属项目，默认不初始化）
./run.sh --file install-mesh

# 显式指定项目（消歧义 / 加速 / 强制初始化）
./run.sh --project mesh --file install-mesh --force-init

# 不执行 cleanup / 只执行 cleanup
./run.sh --file install-mesh --no-cleanup
./run.sh --file install-mesh --cleanup-only

# 轻量卸载（保留 operator 和 CRDs）
./run.sh --file uninstalling-alauda-service-mesh --skip-operator-and-crds
```

## `--project` 与自动查找

- **带 `--project`**：搜索范围限定为该项目仓库，明确、无歧义、最快。
- **不带 `--project`**：引擎遍历 `repos.conf` 所有仓库查找 `runme-test_<file>.sh`；命中唯一则使用并反推所属项目，多项目重名则报错要求显式指定。
- `--init-only` 必须带 `--project`。

## 全量编排

```bash
./run-mesh-all.sh      # mesh 全部测试（自动初始化，按预定义顺序）
./run-otel-all.sh      # otel：OpenTelemetry v2 Operator 安装测试
./run-tracing-all.sh   # tracing：分布式调用链安装 + 卸载测试
```

三个编排脚本相互独立、可单独运行，适合 CI/CD 或全量回归。完整文档清单见 [test-catalog.md](test-catalog.md)。

## Operator 安装重入（幂等）

所有经 `install_operator` 安装的 OLM Operator（`servicemesh-operator2` / `kiali-operator` / `opentelemetry-operator2`）都支持在**已安装**的环境上重复执行安装测试，无需先手工清理集群。安装前先做重入探测（`framework/common.sh:_operator_reentry_probe`）：

| 集群现状 | 行为 |
| --- | --- |
| 目标 CSV 为 `Succeeded` | 跳过安装，直接进入后续测试步骤 |
| 目标 CSV 处于中间态（Installing/Pending 等） | 等待其收敛为 `Succeeded`（默认 12 × 10s）后再判定 |
| 目标 CSV 不存在 | 走完整安装流程（Subscription → 批准 InstallPlan → 等待 CSV） |
| 目标 CSV 停在 `Failed` 或长期未收敛 | 报错退出，交由人工处理 |

卸载 Operator 时平台会把 CSV 连同 Subscription 一并清理，因此重入时不存在需要框架清理的 CSV 残留；框架只做「已安装则跳过」的判定，**不会删除集群里的既有资源**。

用 `OPERATOR_REENTRY_WAIT_RETRIES` / `OPERATOR_REENTRY_WAIT_INTERVAL` 调整中间态的等待轮次与间隔。

## 故障排除

| 问题 | 排查 |
| --- | --- |
| 找不到 runme / violet | 执行 `./run.sh --project <项目> --init-only` 重新安装工具 |
| kubeconfig 获取失败 / 401 | 检查 `PLATFORM_ADDRESS` 是否可达、集群名是否正确；token 过期会自动重新获取，可 `rm -rf .acp-auth` 强制刷新 |
| 自动获取 ACP API Token 失败 | 核对账号密码；账号触发验证码、二次验证或需改密码时改为手工配置 `ACP_API_TOKEN` |
| 未找到测试脚本 | 确认 `repos.conf` 中对应仓库存在；脚本名为 `runme-test_<file>.sh` |
| 测试脚本在多个项目重名 | 用 `--project` 显式指定 |
| 测试执行失败 | `cd` 到对应文档仓库手动执行失败的 `runme run <block>` 调试 |
| 某个 Case 在 dailybuild 上没跑 | 多半是 `CASE_TYPE` 没选中，见 [dailybuild.md](dailybuild.md#case-标签与-case_type) |
