# 文档自动化测试框架（docs-runme-tests）

基于 [runme](https://runme.dev) 的 MDX 文档自动化测试框架，用于验证多个文档项目中的命令和步骤可执行、输出正确。

本仓库是**独立的测试框架仓库**，与各文档仓库（`servicemesh2-docs` / `opentelemetry-docs` / `distributed-tracing-docs`）平级，作为兄弟目录存在：

```bash
/your/workspace/
├── docs-runme-tests/          # 本仓库：测试引擎 + 编排 + 各项目钩子
├── servicemesh2-docs/         # 文档仓库（mesh）
├── opentelemetry-docs/        # 文档仓库（otel）
└── distributed-tracing-docs/  # 文档仓库（tracing）
```

测试脚本 `runme-test_*.sh` 仍与被测 `.mdx` 同仓同目录（runme 按 CWD 所在 git 仓库扫描代码块；文档与测试同 PR 演进）。本仓库提供引擎、通用函数库、各项目初始化逻辑与全量编排。

## 目录结构

```bash
docs-runme-tests/
├── run.sh                  # 单测执行引擎（项目感知）
├── run-mesh-all.sh         # mesh 项目全量编排
├── run-otel-all.sh         # otel 项目全量编排
├── run-tracing-all.sh      # tracing 项目全量编排
├── repos.conf              # 文档仓库注册表
├── framework/              # 通用引擎函数库（零项目耦合）
│   ├── common.sh           # 日志 / 结果统计 / install_operator / _wait_* / kubectl_apply_runme_block
│   ├── verify.sh           # __cmp_* 输出比对
│   ├── kubeconfig.sh       # ACP kubeconfig 拉取 / 合并 / 复用
│   └── tools.sh            # 必备工具检查 / runme·violet 安装 / 插件包下载上传
├── projects/               # 各文档项目专属逻辑
│   ├── mesh/project.sh     # mesh 钩子 + istioctl / 插件包 / operator 安装 / PLATFORM_CA
│   ├── otel/project.sh     # otel 钩子
│   └── tracing/project.sh  # tracing 钩子
├── bin/                    # 工具缓存：runme / violet / istioctl（gitignore）
├── package/                # 插件包缓存（gitignore）
└── .kubeconfig/            # kubeconfig 缓存（gitignore）

<文档仓库>/docs/en/<path>/
├── <doc>.mdx               # 文档（含 {name=...} 代码块）
└── runme-test_<doc>.sh     # 测试脚本，与文档同目录
```

## 支持的文档项目

| 项目    | 文档仓库                   | 全量编排             | 说明                             |
| ------- | -------------------------- | -------------------- | -------------------------------- |
| mesh    | `servicemesh2-docs`        | `run-mesh-all.sh`    | Alauda Service Mesh v2           |
| otel    | `opentelemetry-docs`       | `run-otel-all.sh`    | Alauda Build of OpenTelemetry v2 |
| tracing | `distributed-tracing-docs` | `run-tracing-all.sh` | Alauda Distributed Tracing       |

新增文档项目：在 `repos.conf` 加一行 + 新增 `projects/<name>/project.sh` + 新增 `run-<name>-all.sh`。

## 环境准备

### 1. 系统要求

**注**：执行测试脚本的机器（不是 k8s 集群）必须能访问 GitHub。

以下工具需预先安装：`kubectl`、`curl`、`jq`。框架会自动安装 `runme` / `violet`（mesh 还会装 `istioctl`）。

### 2. repos.conf 仓库注册表

`repos.conf` 登记每个项目对应的文档仓库路径：

```
mesh:../servicemesh2-docs
otel:../opentelemetry-docs
tracing:../distributed-tracing-docs
```

- 路径相对本仓库根，或写绝对路径；目录不存在的条目静默跳过。
- 可用环境变量 `<PROJECT>_REPO_ROOT` 覆盖（如 `MESH_REPO_ROOT=/abs/path`）。
- 引擎据此 export `FRAMEWORK_ROOT`、`DOC_REPO_ROOT`、`<PROJECT>_REPO_ROOT` 给测试脚本使用。

### 3. 环境变量

```bash
# ── 集群名称（按文档归属选择）─────────────────────────────────
export SINGLE_CLUSTER_NAME=my-cluster
# 仅 mesh 的 multi-cluster 文档使用
export EAST_CLUSTER_NAME=east-cluster
export WEST_CLUSTER_NAME=west-cluster

# ── 平台信息（通用必需）──────────────────────────────────────
export PLATFORM_ADDRESS=https://xxx
export PLATFORM_USERNAME='your-username'
export PLATFORM_PASSWORD='your-password'
export ACP_API_TOKEN='your-acp-api-token'   # ACP UI Profile 页面生成

# 集群连接模式（可选，默认 direct；多集群网格必须 direct）
export ACP_KUBECONFIG_MODE=direct
# 平台 CA（可选，留空则 mesh 测试自动从 Global 集群拉取）
# export PLATFORM_CA='base64-encoded-ca-certificate'
# Global 集群名（可选，默认 'global'）
export GLOBAL_CLUSTER_NAME=global

# ── 工具与镜像（通用）───────────────────────────────────────
export RUNME_VERSION=3.16.11
# mesh 镜像加速（可选）
export USE_MESH_V2_TEST_SUITE_PLUGIN=true
export REGISTRY_MIRROR_ADDRESS=docker-mirrors.alauda.cn

# ── 测试行为开关（mesh，可选）────────────────────────────────
export IS_DUAL_STACK=false
export AUTO_GEN_BOOKINFO_TRAFFIC=true

# ── 插件包地址 ──────────────────────────────────────────────
# mesh 项目需要：
export PKG_SERVICEMESH_OPERATOR2_URL=xxx
export PKG_KIALI_OPERATOR_URL=xxx
export PKG_METALLB_OPERATOR_URL=xxx
# mesh / otel / tracing 均需要：
export PKG_OPENTELEMETRY_OPERATOR2_URL=xxx

# ── 分布式调用链测试专用 ────────────────────────────────────
# ACP ES 所在集群（可选，默认 global；设为空则使用下方 TRACING_ES_* 手动配置）
export TRACING_ACP_ES_CLUSTER=global
# 手动 Elasticsearch 配置（仅 TRACING_ACP_ES_CLUSTER 为空时使用）
export TRACING_ES_ENDPOINT='https://es.xx:9200'
export TRACING_ES_USER='your-es-username'
export TRACING_ES_PASS='your-es-password'
# telemetrygen 测试时长（可选，覆盖文档默认的 150s，加快测试）
export TRACING_TELEMETRYGEN_TEST_DURATION_1=30s
export TRACING_TELEMETRYGEN_TEST_DURATION_2=130s
# 是否测试 SPM (Service Performance Monitoring) 章节（可选，需 ACP monitoring）
export TRACING_TEST_SPM=true
```

**通用必需变量**（引擎 `check_env` 校验）：`RUNME_VERSION` `PLATFORM_ADDRESS` `ACP_API_TOKEN` `PLATFORM_USERNAME` `PLATFORM_PASSWORD`。

**项目专属变量**（各项目 `project_check_env` 校验）：

| 项目    | 必需                                                                                                                  | 软依赖（缺失则 SKIPPED）                                    |
| ------- | --------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| mesh    | `PKG_SERVICEMESH_OPERATOR2_URL` `PKG_KIALI_OPERATOR_URL` `PKG_OPENTELEMETRY_OPERATOR2_URL` `PKG_METALLB_OPERATOR_URL` | -                                                           |
| otel    | `PKG_OPENTELEMETRY_OPERATOR2_URL`                                                                                     | -                                                           |
| tracing | `PKG_OPENTELEMETRY_OPERATOR2_URL`                                                                                     | `TRACING_ACP_ES_CLUSTER` 或 `TRACING_ES_ENDPOINT/USER/PASS` |

### 4. kubeconfig 自动管理

执行 `--init-only` / `--force-init` 时，框架通过 ACP 平台 API 自动获取集群 kubeconfig，缓存于 `.kubeconfig/`，无需手动下载。配置指纹（PLATFORM_ADDRESS / ACP_KUBECONFIG_MODE / ACP_API_TOKEN / 集群列表）变更时自动重拉。

mesh 项目会在集群列表末尾自动追加 Global 集群（用于自动获取 `PLATFORM_CA`）。

## 使用方法

### 基本命令

```bash
cd docs-runme-tests

# 查看帮助
./run.sh --help

# 初始化某项目环境（--init-only 必须带 --project）
./run.sh --project mesh --init-only
./run.sh --project tracing --init-only

# 多集群初始化（仅 mesh 的 multi-cluster 文档）
./run.sh --project mesh --init-only --cluster "$EAST_CLUSTER_NAME" --cluster "$WEST_CLUSTER_NAME"

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

### `--project` 与自动查找

- **带 `--project`**：搜索范围限定为该项目仓库，明确、无歧义、最快。
- **不带 `--project`**：引擎遍历 `repos.conf` 所有仓库自动查找 `runme-test_<file>.sh`；命中唯一则使用并反推所属项目，多项目重名则报错要求显式 `--project`。
- `--init-only` 必须带 `--project`。

### 全量编排

```bash
./run-mesh-all.sh      # mesh 全部测试（自动初始化，按预定义顺序）
./run-otel-all.sh      # otel：OpenTelemetry v2 Operator 安装测试
./run-tracing-all.sh   # tracing：分布式调用链安装 + 卸载测试
```

三个编排脚本相互独立、可单独运行，适合 CI/CD 或全量回归。

## 各项目测试清单

### mesh（servicemesh2-docs）

| 文档名称                     | 执行命令                                                                                    |
| ---------------------------- | ------------------------------------------------------------------------------------------- |
| 双栈网格安装                 | `./run.sh --project mesh --file install-mesh-in-dual-stack-mode`                            |
| 网格安装                     | `./run.sh --project mesh --file install-mesh`                                               |
| Istio HA - 自动伸缩          | `./run.sh --project mesh --file configuring-istio-ha-by-using-autoscaling`                  |
| Istio HA - 固定副本数        | `./run.sh --project mesh --file configuring-istio-ha-by-using-replica-count`                |
| 指标与服务网格集成           | `./run.sh --project mesh --file metrics-and-mesh`                                           |
| Kiali 安装与配置             | `./run.sh --project mesh --file kiali`                                                      |
| Bookinfo 应用部署            | `./run.sh --project mesh --file deploying-the-bookinfo-application`                         |
| Kiali 卸载                   | `./run.sh --project mesh --file uninstalling-alauda-build-of-kiali`                         |
| 网格卸载                     | `./run.sh --project mesh --file uninstalling-alauda-service-mesh`                           |
| InPlace 更新策略             | `./run.sh --project mesh --file update-inplace`                                             |
| Ambient Mode 安装            | `./run.sh --project mesh --file installing-ambient-mode`                                    |
| Ambient Bookinfo 部署        | `./run.sh --project mesh --file deploying-ambient-bookinfo`                                 |
| Waypoint 代理部署            | `./run.sh --project mesh --file waypoint-proxies`                                           |
| Ambient L7 特性              | `./run.sh --project mesh --file ambient-l7-features`                                        |
| Ambient Gateway API          | `./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-ambient-mode`     |
| Ambient Egress Gateway       | `./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode` |
| Ambient 模式网格卸载         | `./run.sh --project mesh --file uninstalling-alauda-service-mesh-in-ambient-mode`           |
| 多集群 - 配置概述（CA 证书） | `./run.sh --project mesh --file configuration-overview`                                     |
| 多集群 - 多主多网络          | `./run.sh --project mesh --file install-multi-primary-multi-network`                        |
| 多集群 - 主-远多网络         | `./run.sh --project mesh --file install-primary-remote-multi-network`                       |

> 多集群测试需 `EAST_CLUSTER_NAME` / `WEST_CLUSTER_NAME` 双集群环境，并需先用双集群 `--init-only` 与 `configuration-overview` 完成 cacerts 下发。

### otel（opentelemetry-docs）

| 文档名称                       | 执行命令                                               |
| ------------------------------ | ------------------------------------------------------ |
| OpenTelemetry v2 Operator 安装 | `./run.sh --project otel --file install-opentelemetry` |

> 覆盖 `install-opentelemetry.mdx` 的「Installing the Alauda Build of OpenTelemetry v2 Operator」章节。

### tracing（distributed-tracing-docs）

| 文档名称         | 执行命令                                                             |
| ---------------- | -------------------------------------------------------------------- |
| 分布式调用链安装 | `./run.sh --project tracing --file installing-distributed-tracing`   |
| 分布式调用链卸载 | `./run.sh --project tracing --file uninstalling-distributed-tracing` |

> 默认从 `TRACING_ACP_ES_CLUSTER` 指定的 ACP 集群（默认 `global`）读取 log-center Elasticsearch 配置；将其设为空时改用 `TRACING_ES_*` 手动配置。安装测试会自动安装前置依赖 OpenTelemetry v2 Operator（其代码块位于 `opentelemetry-docs`）。

## 工作原理

### 1. runme 工具

测试使用 [runme](https://runme.dev) 执行 MDX 文档中的代码块：解析带 `{name=xxx}` 属性的代码块，`runme run <block>` 执行、`runme print <block>` 取内容。引擎在执行测试前会 `cd` 到该文档仓库根，使 runme 能定位其代码块。

### 2. 项目钩子

每个 `projects/<name>/project.sh` 实现三个标准钩子，由引擎调用：

| 钩子                      | 调用时机                          | 职责                                          |
| ------------------------- | --------------------------------- | --------------------------------------------- |
| `project_check_env`       | 每次运行开头                      | 校验项目专属环境变量                          |
| `project_init <clusters>` | 仅 `--init-only` / `--force-init` | kubeconfig + 插件包 + operator 等重量级初始化 |
| `project_prepare`         | 每次运行                          | kubeconfig 加载等轻量级准备                   |

### 3. 测试脚本结构

每个 `runme-test_*.sh` 含 `test_<name>()`（执行步骤与验证），卸载/清理类文档还含 `cleanup_<name>()`。脚本头部固定为：

```bash
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
```

### 4. 验证工具

`framework/verify.sh` 提供输出比对函数：`__cmp_same`（精确）、`__cmp_contains`（包含）、`__cmp_not_contains`、`__cmp_regex`、`__cmp_lines`（逐行 +/- 断言）等。`__cmp_like` 暂有问题，勿用。

## 编写新测试

推荐使用 Claude Code 的 `/auto-test-creator` skill 自动生成测试脚本，定义见 `.claude/skills/auto-test-creator/SKILL.md`。它会分析 MDX、添加 `{name=}` 属性、生成测试脚本、更新本文档与编排脚本。

## 故障排除

| 问题                      | 排查                                                                       |
| ------------------------- | -------------------------------------------------------------------------- |
| 找不到 runme / violet     | 执行 `./run.sh --project <项目> --init-only` 重新安装工具                  |
| kubeconfig 获取失败 / 401 | 检查 `ACP_API_TOKEN` 是否过期、`PLATFORM_ADDRESS` 是否可达、集群名是否正确 |
| 未找到测试脚本            | 确认 `repos.conf` 中对应仓库存在；脚本名为 `runme-test_<file>.sh`          |
| 测试脚本在多个项目重名    | 用 `--project` 显式指定                                                    |
| 测试执行失败              | `cd` 到对应文档仓库手动执行失败的 `runme run <block>` 调试                 |

## TODO

- [ ] Multus / MetalLB 集群插件自动安装
- [ ] tracing 测试的 Elasticsearch 依赖在 CI 中维护共享实例
- [ ] 分布式调用链 SPM (Service Performance Monitoring) 扩展测试
- [ ] 优化测试 case 结果统计

## 参考资料

- [runme 官方文档](https://runme.dev)
- [Istio 文档测试](https://github.com/istio/istio.io/blob/master/tests/README.md)
