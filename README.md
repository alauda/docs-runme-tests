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

## 变更操作手册

本文档讲**怎么用**；改了东西之后还要同步改哪儿（新增 Case、文档外部链接变更、
工具版本升级、插件包地址、四仓联合改动、发新版本），统一见
**[UPDATE-README.md](UPDATE-README.md)**。

镜像构建、Edge 流水线和 tag 规则已单独整理到
**[IMAGE-BUILD-README.md](IMAGE-BUILD-README.md)**。

发版分支规则与发版版本矩阵已迁至该文档的
[「发新版本」](UPDATE-README.md#6-发新版本)一节。

## 目录结构

```bash
docs-runme-tests/
├── README.md               # 怎么用（本文）
├── UPDATE-README.md        # 怎么改：新增 Case / 离线资源 / 版本升级 / 发版
├── IMAGE-BUILD-README.md   # 镜像构建与 Edge 流水线操作手册
├── run.sh                  # 单测执行引擎（项目感知）
├── run-mesh-all.sh         # mesh 项目全量编排
├── run-otel-all.sh         # otel 项目全量编排
├── run-tracing-all.sh      # tracing 项目全量编排
├── repos.conf              # 文档仓库注册表
├── framework/              # 通用引擎函数库（零项目耦合）
│   ├── common.sh           # 日志 / 结果统计 / install_operator（含重入探测）/ install_operator_cli / install_cluster_plugin / setup_external_ip_pools / _wait_* / kubectl_apply_runme_block
│   ├── verify.sh           # __cmp_* 输出比对
│   ├── acp-auth.sh         # ACP API Token 自动获取（平台账号密码 → dex）/ 校验 / 缓存
│   ├── kubeconfig.sh       # ACP kubeconfig 拉取 / 合并 / 复用
│   └── tools.sh            # 必备工具检查 / runme·violet 安装 / 插件包下载上传
├── projects/               # 各文档项目专属逻辑
│   ├── mesh/project.sh     # mesh 钩子 + istioctl / 插件包 / operator 安装 / PLATFORM_CA
│   ├── otel/project.sh     # otel 钩子
│   └── tracing/            # tracing 钩子（project.sh）+ OpenSearch / Elasticsearch 自动安装与 ISM 共享辅助（opensearch.sh / elasticsearch.sh）+ Jaeger v2 集群插件共享安装（jaeger-plugin.sh）
├── lynx/                   # lynx / dailybuild 适配层
│   ├── entrypoint.sh       # 镜像入口 docs-test <init|mesh|otel|tracing>
│   ├── env-adapter.sh      # lynx 内置变量 → 框架变量
│   ├── case-filter.sh      # CASE_TYPE 表达式求值（and / not 合取式）
│   ├── allure.sh           # allure 结果与报告生成
│   ├── compute-tags.sh     # 分支 + commit → 镜像 tag 列表
│   ├── assets-manifest.tsv # 离线资产清单（外部 URL → 镜像内路径）
│   ├── case-ids.tsv        # case_id 清单（文档 → 稳定编号）
│   ├── docs-refs.tsv       # 三个文档仓库在镜像里使用的 ref
│   └── check-*.sh          # 五条清单/兼容性自检（构建期强制）
├── .tekton/                # 镜像构建流水线（Pipelines-as-Code）
├── charts/
│   └── mesh-v2-test-suite/ # Mesh v2 测试套件 ACP 集群插件
├── bin/                    # 工具缓存：runme / violet / istioctl（gitignore）
├── assets/                 # 离线资产（构建期落盘，gitignore）
├── package/                # 插件包缓存（gitignore）
└── .kubeconfig/            # kubeconfig 缓存（gitignore）

<文档仓库>/docs/en/<path>/
├── <doc>.mdx               # 文档（含 {name=...} 代码块）
└── runme-test_<doc>.sh     # 测试脚本，与文档同目录
```

`charts/mesh-v2-test-suite` 用于将 Mesh v2 / OpenTelemetry 测试镜像预置到 ACP 内置镜像仓库，并提供 Java OTel 示例资源。打包、上架及版本维护方式见 [Chart 说明](charts/mesh-v2-test-suite/README.md)。

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

以下工具需预先安装：`kubectl`、`curl`、`jq`、`openssl`（`openssl` 用于自动获取 ACP API Token）。框架会自动安装 `runme` / `violet`（mesh 还会装 `istioctl`）。

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
# ACP API Token（可选）：不配置时，引擎用上面的地址 + 用户名 + 密码自动获取，
# 详见「ACP API Token 自动获取」。仅在需要固定 token（如 UI 生成的长期 token）时才配置。
# export ACP_API_TOKEN='your-acp-api-token'

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
# 网关内核兼容（仅内核 < 4.11/CentOS7 需要，默认 false）：开启后网关按 Linux 内核兼容处理——
# 高端口网关（东西向 / waypoint）走 Scenario 1（去 sysctls），特权端口网关（监听 80 的 ingress/egress）走 Scenario 2（+ NET_BIND_SERVICE + root）
export ENABLE_GW_LINUX_KERNEL_COMPAT=false
# 是否安装 MetalLB 集群插件（多集群网格 / 入口网关 LoadBalancer 场景需要，默认 false）
# 置 false 时下列测试会被编排脚本主动跳过（没有 LoadBalancer 地址跑必失败）：
# - mesh Case 3/5 的三篇 exposing-* 入口网关文档（日志里 log_warn，不产用例记录）
# - mesh Case 6/7 多集群网格（按 env 分类 case_skip，报告里可见）
export ENABLE_METALLB=false
# 外部 IP 地址池地址（仅 ENABLE_METALLB=true 时需要）：JSON 数组，ipv6Addresses 为将来预留
# - 多集群 Case 6/7：cluster 需与 EAST_CLUSTER_NAME / WEST_CLUSTER_NAME 对应
# - 单集群入口网关 LoadBalancer 测试（Case 3/5 的 exposing-* 文档）：需含 cluster=$SINGLE_CLUSTER_NAME 条目
export METALLB_EXTERNAL_ADDRESSES_JSON='[{"cluster":"business-1","ipv4Addresses":["192.168.139.13/32"]},{"cluster":"business-2","ipv4Addresses":["192.168.137.150/32"]}]'
```

> **verify-only 模式**：所有 `PKG_*_URL` 均为**可选**。留空时框架不下载、不上架该插件包，
> 改为直接校验它是否已在集群上架（Operator 查 PackageManifest，集群插件查 ModuleConfig），
> 并从中反查目标版本。这正是 dailybuild 的用法——插件包由 lynx 依据 Release YAML 预上架，
> 测试 Pod 不需要访问 package-minio。本地手工跑则照旧提供地址，由框架自行下载上架。

```bash
# ── 插件包地址 ──────────────────────────────────────────────
# Operator 包：mesh 项目需要
export PKG_SERVICEMESH_OPERATOR2_URL=xxx
export PKG_KIALI_OPERATOR_URL=xxx
# Operator 包：mesh / otel / tracing 均需要
export PKG_OPENTELEMETRY_OPERATOR2_URL=xxx
# 集群插件包：mesh 始终需要 Multus（Service Mesh 前提）
export PKG_MULTUS_URL=xxx
# 集群插件包：仅 ENABLE_METALLB=true 时需要（metallb 插件 + 其前置 metallb-operator）
export PKG_METALLB_URL=xxx
export PKG_METALLB_OPERATOR_URL=xxx
# 集群插件包：仅 USE_MESH_V2_TEST_SUITE_PLUGIN=true 时需要（mesh / otel / tracing 共用）
export PKG_MESH_V2_TEST_SUITE_URL=xxx
# 集群插件包：tracing 需要（Alauda Build of Jaeger v2，两篇安装文档的前置依赖；
# 安装测试步骤 1 经文档 CLI 代码块安装，未上架时自动下载并 violet push 到 Global）
export PKG_JAEGER_CLUSTER_PLUGIN_URL=xxx

# ── 分布式调用链测试专用 ────────────────────────────────────
# ACP ES 所在集群（可选，默认 global；设为空则使用下方 TRACING_ES_* 手动配置）
export TRACING_ACP_ES_CLUSTER=global
# 手动 Elasticsearch 配置（仅 TRACING_ACP_ES_CLUSTER 为空时使用）
export TRACING_ES_ENDPOINT='https://es.xx:9200'
export TRACING_ES_USER='your-es-username'
export TRACING_ES_PASS='your-es-password'
# Elasticsearch 自动安装（默认关闭）：开启且 PKG_LOG_CENTER_URL 非空时，Elasticsearch 安装测试的
# ACP 日志存储 Elasticsearch（"Alauda Container Platform Log Storage for Elasticsearch"，
# logcenter 集群插件）安装到 TRACING_ACP_ES_CLUSTER 指定集群；对应集群已安装过则跳过（幂等）。
export TRACING_INSTALL_ES=false
export PKG_LOG_CENTER_URL=xxx             # log-center 集群插件包（自动下载上架）
# Log/Kafka 节点（可选，默认自动取目标集群第一个 Ready 节点）
# export TRACING_ES_K8S_NODE=xxx.xxx.xxx.xxx

# OpenSearch 自动安装（默认开启；前提：ACP 离线环境、业务集群至少 3 个节点、各节点有空闲磁盘）
# 开启且下方两个插件包地址齐全时，OpenSearch 安装测试的步骤 0 会自动安装 TopoLVM + OpenSearch，
# 并用实际安装结果覆盖 TRACING_OPENSEARCH_*（无需手动配置）；条件不满足时降级用手动配置。
# 注意：opensearch-operator 插件包目前需手动 violet 上架到业务集群（
# 待支持在线环境后改为自动下载上架，见 projects/tracing/opensearch.sh 的 TODO）。
export TRACING_INSTALL_OPENSEARCH=true
export PKG_ACP_STORAGE_OPERATOR_URL=xxx   # Alauda Container Platform Storage Essentials 包（自动下载上架）
export PKG_TOPOLVM_OPERATOR_URL=xxx       # Alauda Build of TopoLVM 包（自动下载上架）
# TopolvmCluster 使用的节点空闲磁盘设备（可选，默认 /dev/vdb）
export TRACING_TOPOLVM_DEVICE=/dev/vdb
# Dashboards Ingress 的访问路径（可选，默认自动派生 /clusters/<集群名>/opensearch-dashboards）
# export TRACING_OPENSEARCH_DASHBOARDS_BASEPATH=/clusters/business-1/opensearch-dashboards
# OpenSearch HTTP API (9200) Ingress 的访问路径（可选，默认自动派生 /clusters/<集群名>/opensearch）
# 自动安装时 TRACING_OPENSEARCH_ENDPOINT = 平台地址 + 该路径（集群内外都可访问）
# export TRACING_OPENSEARCH_BASEPATH=/clusters/business-1/opensearch
# 手动 OpenSearch 配置（自动安装条件不满足时使用）
export TRACING_OPENSEARCH_ENDPOINT='https://opensearch.xx:9200'
export TRACING_OPENSEARCH_USER='your-opensearch-username'
export TRACING_OPENSEARCH_PASS='your-opensearch-password'
# telemetrygen 测试时长（可选，覆盖文档默认的 150s，加快测试）
export TRACING_TELEMETRYGEN_TEST_DURATION_1=30s
export TRACING_TELEMETRYGEN_TEST_DURATION_2=130s
# 是否测试 SPM (Service Performance Monitoring) 章节（可选，需 ACP monitoring）
export TRACING_TEST_SPM=true
```

**通用必需变量**（引擎 `check_env` 校验）：`RUNME_VERSION` `PLATFORM_ADDRESS` `PLATFORM_USERNAME` `PLATFORM_PASSWORD`。`ACP_API_TOKEN` 为可选（见下节）。

**项目专属变量**（各项目 `project_check_env` 校验）：

| 项目 | 必需 | 条件必需 / 软依赖 |
| --- | --- | --- |
| mesh | 无（`PKG_*_URL` 全部可选，留空即 verify-only） | 提供地址时按原逻辑下载上架；`ENABLE_METALLB=true` 时若也未预上架 metallb / metallb-operator，安装会报错 |
| otel | 无（同上） | `USE_MESH_V2_TEST_SUITE_PLUGIN=true` 时需 `PKG_MESH_V2_TEST_SUITE_URL` 或平台已预上架 |
| tracing | 无（同上） | ES / OpenSearch 存储后端配置同原表；Jaeger v2 集群插件需 `PKG_JAEGER_CLUSTER_PLUGIN_URL` 或平台已预上架 |

> 注：`METALLB_EXTERNAL_ADDRESSES_JSON`（外部 IP 地址池地址，JSON 数组）在 `ENABLE_METALLB=true` 时由 `setup_external_ip_pools` 创建地址池时校验（不在 `project_check_env`）：多集群 Case 6/7 需含 `cluster=$EAST_CLUSTER_NAME`/`$WEST_CLUSTER_NAME` 条目；单集群入口网关 LoadBalancer 测试（Case 3/5 的 exposing-\* 文档）需含 `cluster=$SINGLE_CLUSTER_NAME` 条目。`ENABLE_METALLB != true` 时这两组测试由 `run-mesh-all.sh` 直接跳过，不会走到这里。
>
> 地址池所有权：`init` 入口（`lynx/entrypoint.sh` 的 `docs-test init`）创建的池带
> `runme-test/owner=init` 标签，长期存在、测试结束不清理；单篇测试脚本自建的池带
> `owner=doctest`，用完即删。池已存在时 `setup_external_ip_pools` 直接复用，
> 不再要求 `METALLB_EXTERNAL_ADDRESSES_JSON`。

### 4. ACP API Token 自动获取

框架调用 ACP 平台 API（拉取集群 kubeconfig 等）需要 `ACP_API_TOKEN`。**不必手工去 UI 个人信息页生成**：只要配置了 `PLATFORM_ADDRESS` / `PLATFORM_USERNAME` / `PLATFORM_PASSWORD`，引擎启动时（`run.sh` 的 `ensure_acp_api_token`）会自动登录换取 token。

取值优先级：

1. 已配置且校验通过的 `ACP_API_TOKEN`（校验方式：`GET /auth/v1/clusters` 返回 200）——配置了就原样使用；
2. `.acp-auth/token.json` 中未过期的缓存 token（按「平台地址 + 用户名」指纹匹配，剩余有效期不足 30 分钟视为过期）；
3. 用平台账号密码登录获取，成功后写入缓存。

已配置的 `ACP_API_TOKEN` 校验失败（过期 / 换环境）且账号密码齐全时，会告警并自动改用登录获取，无需手工换 token。

登录流程与 ACP 登录页前端行为一致（OIDC implicit，不需要 dex client secret）：`GET /dex/api/v1/authorize` 取登录请求 ID → `GET /dex/pubkey` 取 RSA 公钥 → RSA(PKCS#1 v1.5) 加密 `{"ts":..,"password":..}` → `POST /dex/api/v1/authorize/<connector>` → 从回调 URL fragment 取 `id_token`。token 由 dex 签发，有效期通常 24 小时，够单轮测试使用；实现见 `framework/acp-auth.sh`，额外依赖 `openssl`。

可选环境变量：

| 变量                     | 默认                | 说明                                             |
| ------------------------ | ------------------- | ------------------------------------------------ |
| `ACP_AUTH_CACHE_DIR`     | `<仓库根>/.acp-auth` | token 缓存目录（600 权限，已 gitignore）         |
| `ACP_AUTH_NO_CACHE`      | `false`             | `true` 时不读写缓存，每次重新登录                 |
| `ACP_AUTH_EXPIRY_MARGIN` | `1800`              | 缓存剩余有效期低于该秒数时视为过期                |
| `ACP_AUTH_DEX_CLIENT_ID` | `alauda-auth`       | dex client id                                    |
| `ACP_AUTH_DEX_CONNECTOR` | 自动探测（通常 `local`） | dex connector，接对接外部 IdP 的环境时可显式指定 |

账号触发验证码 / 二次验证 / 首次登录改密码时无法自动登录，此时改为手工配置 `ACP_API_TOKEN`。

### 5. kubeconfig 自动管理

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

### Operator 安装重入（幂等）

所有经 `install_operator` 安装的 OLM Operator（`servicemesh-operator2` / `kiali-operator` / `opentelemetry-operator2`）都支持在**已安装**的环境上重复执行安装测试，无需先手工清理集群。安装前会先做重入探测（`framework/common.sh:_operator_reentry_probe`）：

| 集群现状                                     | 行为                                                              |
| -------------------------------------------- | ----------------------------------------------------------------- |
| 目标 CSV 为 `Succeeded`                      | 跳过安装，直接进入后续测试步骤                                    |
| 目标 CSV 处于中间态（Installing/Pending 等） | 等待其收敛为 `Succeeded`（默认 12 × 10s）后再判定                 |
| 目标 CSV 不存在                              | 走完整安装流程（创建 Subscription → 批准 InstallPlan → 等待 CSV） |
| 目标 CSV 停在 `Failed` 或长期未收敛          | 报错退出，交由人工处理（框架不会自行删除集群资源）                |

> 卸载 Operator 时平台会把 CSV 连同 Subscription 一并清理，因此重入时不存在需要框架清理的 CSV 残留；框架只做「已安装则跳过」的判定，不会删除集群里的既有资源。
>
> 可选环境变量：`OPERATOR_REENTRY_WAIT_RETRIES` / `OPERATOR_REENTRY_WAIT_INTERVAL` 调整中间态的等待轮次与间隔。逻辑单测见 `framework/tests/install_operator_test.sh`（伪造 kubectl/runme，不依赖集群）。

## 构建测试镜像

```bash
docker build --build-arg IMAGE_TAG=local-dev -t docs-runme-tests:local-dev .
```

镜像自包含：三个文档仓库按 ref 浅克隆进 `/app/`，`runme` / `violet` / `istioctl` 预置到
`bin/`（`istioctl` 版本从 mesh 文档的 runme 块推导，与 `install_istioctl` 的校验一致），
文档引用的 17 个外部 sample YAML 按 `lynx/assets-manifest.tsv` 落到 `assets/`。
构建期会跑 `lynx/check-{manifest,case-ids,docs-refs,shell-compat,runtime-shell}.sh`，任一不通过即构建失败。

想知道某个镜像里装的是哪一组四仓组合：入口日志第一行会打印 tag 与三个文档仓库的 commit SHA，
镜像内也可以 `cat /app/docs-runme-tests/.image-info`。

**构建参数、tag 规则、流水线触发方式、四仓联合改动的构建流程**详见
[IMAGE-BUILD-README.md](IMAGE-BUILD-README.md)与
[UPDATE-README.md 第 5 节](UPDATE-README.md#5-四仓联合改动文档仓库与本仓库要一起改)。

## 在 lynx / dailybuild 中运行

镜像 `build-harbor.alauda.cn/asm/docs-runme-tests:<tag>`，入口 `command: docs-test`，
参数 `args: [init|mesh|otel|tracing]`。

| lynx 内置变量 | 映射到框架变量 | 备注 |
| --- | --- | --- |
| `$API_URL` | `PLATFORM_ADDRESS` | |
| `$USERNAME` / `$PASSWORD` | `PLATFORM_USERNAME` / `PLATFORM_PASSWORD` | |
| `$REGION_NAME` | `SINGLE_CLUSTER_NAME` | 被测集群 |
| `$GLOBAL_EXTERNAL_IPPOOL` | `METALLB_EXTERNAL_ADDRESSES_JSON` | 按 region 取值，`init` 用它建地址池 |
| `TEST_RESULT_DIR` | 报告根目录 | 未注入时缺省 `/app/report` |
| `CASE_TYPE` | Case / DocTest 过滤表达式 | 仅支持 `and` / `not` 合取式 |
| `$TOKEN` | **忽略** | lynx 不替换它，框架用账号密码经 dex 换 token |

模板里需要写死的变量：`EAST_CLUSTER_NAME`、`WEST_CLUSTER_NAME`、`GLOBAL_CLUSTER_NAME=global`、
`ENABLE_METALLB`、`USE_MESH_V2_TEST_SUITE_PLUGIN=true`、`IS_DUAL_STACK`、`TRACING_ACP_ES_CLUSTER`、
`ACP_KUBECONFIG_MODE=direct`、`AUTO_GEN_BOOKINFO_TRAFFIC=true`、`ENABLE_GW_LINUX_KERNEL_COMPAT=false`、
`RESOURCE_PREFIX`。所有 `PKG_*_URL` **不设置**（verify-only，见上文）。

报告产物：`$TEST_RESULT_DIR/allure-result/` 与 `$TEST_RESULT_DIR/allure-report/`。
用例粒度为一篇文档的一次执行（DocTest），Case 作为 allure suite 分组。

### Case 标签与 CASE_TYPE

`CASE_TYPE` 只支持 `and` 连接的合取式与 `not` 取反（`or` 与括号会报错退出）。
保留标签 `always` 恒被选中，用于环境初始化这类必须先跑的前置 Case。
`CASE_TYPE` 未设置时全部选中——本地手工跑行为不变。

| 项目 | Case | 标签 |
| --- | --- | --- |
| mesh | 1 环境初始化 | `always install` |
| mesh | 2 双栈网格安装 | `dualstack install` |
| mesh | 3 单网格安装与应用（含调用链） | `smoke install sidecar` |
| mesh | 4 Istio HA 配置 | `ha install` |
| mesh | 5 Ambient Mode 安装 | `smoke install ambient` |
| mesh | 6 / 7 多集群 | `multicluster` |
| mesh | 8 / 9 / 10 更新策略 | `update` |
| mesh | 11 Ambient 更新 | `update ambient` |
| otel | 1 安装与卸载 | `smoke install` |
| otel | 2 Java 自动注入示例 | `install java elasticsearch` |
| tracing | 1 环境初始化 | `smoke install` |
| tracing | 2 安装与卸载（ES） | `install elasticsearch` |
| tracing | 3 安装与卸载（OpenSearch） | `install opensearch` |
| tracing | 4 SPM 多副本（ES） | `ha elasticsearch` |
| tracing | 5 SPM 多副本（OpenSearch） | `ha opensearch` |
| tracing | 6 v2.0→v2.1 升级（ES） | `upgrade elasticsearch` |
| tracing | 7 v2.0→v2.1 升级（OpenSearch） | `upgrade opensearch` |

DocTest 级标签有两个：

- `egress`（mesh Case 3 / 5 中的三篇 `routing-egress-traffic-*`）
- `elasticsearch`（mesh Case 3 中的调用链平台装 / 卸两步）

dailybuild 目前开了四个测试项：`docs-mesh` / `docs-otel` / `docs-tracing` 用
`CASE_TYPE="smoke and not egress and not elasticsearch"`，`docs-mesh-multicluster` 单独用
`CASE_TYPE="multicluster and not egress"`。多集群必须单开一项，因为表达式不支持 `or`，
`smoke` 那三项选不到只带 `multicluster` 标签的 Case 6/7。

**存储后端两条链目前都不在 dailybuild 的选择范围内**，原因不同：

- Elasticsearch（otel Case 2、tracing Case 2/4/6）：天翼云 openSUSE MicroOS 的根文件系统
  不可变只读，装不了 hostPath 方式的本地 ES 存储，dailybuild 环境的 `asm-1` 集群已去掉
  `log_storage` 声明。这些 Case 都不带 `smoke`、都带 `elasticsearch`，且 `CASE_TYPE` 里
  额外写了 `and not elasticsearch` 双保险。环境支持后：把 `smoke` 加回 otel Case 2 与
  tracing Case 2/4，并去掉 `CASE_TYPE` 里的 `and not elasticsearch`。
- OpenSearch（tracing Case 3/5/7）：需要业务集群各节点有空闲裸盘（TopoLVM），dailybuild 的
  `asm-1` 未挂数据盘。环境支持后给 tracing Case 3/5 补 `smoke` 标签即可，表达式不用改。

因此 `docs-tracing` 测试项当前只会选中 tracing Case 1（环境初始化）——它不碰任何存储后端，
是这个测试项唯一跑得起来的 Case；没有它该测试项一个用例都不会跑。

tracing Case 6/7（升级）只带 `upgrade`，四个现有测试项都选不中它们——这是有意的：升级测试
要求环境上先有一套 v2.0 部署，dailybuild 的环境是全新安装出来的 v2.1，跑了也只会 SKIPPED。
将来要纳入，得按多集群那样单开一个 `CASE_TYPE="upgrade"` 的 lynx 测试项，并让该测试项的
环境停在 v2.0。

`ENABLE_METALLB=false` 时另有两处按环境跳过（与 `CASE_TYPE` 无关，见上文该变量说明）：
mesh Case 3/5 的三篇 `exposing-*` 入口网关文档、mesh Case 6/7 多集群网格。天翼云 MicroOS
暂不支持 `other_vips` 机制、给 MetalLB 自动配 VIP，dailybuild 四个测试项已全部置 false，
`docs-mesh-multicluster` 因此暂时只会跑环境初始化、两个多集群 Case 均按 `[env]` 跳过。

新增或修改标签时要同步 release-config 的 `CASE_TYPE`，
详见 [UPDATE-README.md 第 1.4 节](UPDATE-README.md#14-需要新标签时同步-release-config)。

## 各项目测试清单

### mesh（servicemesh2-docs）

| 文档名称                           | 执行命令                                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------------------------- |
| 双栈网格安装                       | `./run.sh --project mesh --file install-mesh-in-dual-stack-mode`                            |
| 网格安装                           | `./run.sh --project mesh --file install-mesh`                                               |
| Pod Security Admission（网关类）   | `./run.sh --project mesh --file pod-security-admission`                                     |
| Istio HA - 自动伸缩                | `./run.sh --project mesh --file configuring-istio-ha-by-using-autoscaling`                  |
| Istio HA - 固定副本数              | `./run.sh --project mesh --file configuring-istio-ha-by-using-replica-count`                |
| 指标与服务网格集成                 | `./run.sh --project mesh --file metrics-and-mesh`                                           |
| 网格调用链集成配置                 | `./run.sh --project mesh --file config-with-service-mesh`                                   |
| Kiali 安装与配置                   | `./run.sh --project mesh --file kiali`                                                      |
| Bookinfo 应用部署（含网关）        | `./run.sh --project mesh --file deploying-the-bookinfo-application`                         |
| 严格 mTLS（命名空间级）            | `./run.sh --project mesh --file mtls`                                                       |
| Sidecar 网关 - Istio Gateway       | `./run.sh --project mesh --file exposing-a-service-via-istio-gateway`                       |
| Sidecar 网关 - K8s Gateway API     | `./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-sidecar-mode`     |
| Sidecar 出口网关 - Istio APIs      | `./run.sh --project mesh --file routing-egress-traffic-via-istio-apis`                      |
| Sidecar 出口网关 - K8s Gateway API | `./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-sidecar-mode` |
| Kiali 卸载                         | `./run.sh --project mesh --file uninstalling-alauda-build-of-kiali`                         |
| 网格卸载                           | `./run.sh --project mesh --file uninstalling-alauda-service-mesh`                           |
| InPlace 更新策略                   | `./run.sh --project mesh --file update-inplace`                                             |
| Istio CNI 升级                     | `./run.sh --project mesh --file istio-cni`                                                  |
| RevisionBased 更新策略             | `./run.sh --project mesh --file update-revisionbased`                                       |
| RevisionBased + 版本标签           | `./run.sh --project mesh --file update-revisionbased-and-istiorevisiontag`                  |
| Ambient Mode 安装                  | `./run.sh --project mesh --file installing-ambient-mode`                                    |
| Ambient Bookinfo 部署              | `./run.sh --project mesh --file deploying-ambient-bookinfo`                                 |
| Waypoint 代理部署                  | `./run.sh --project mesh --file waypoint-proxies`                                           |
| Ambient L7 特性                    | `./run.sh --project mesh --file ambient-l7-features`                                        |
| Ambient Gateway API                | `./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-ambient-mode`     |
| Ambient Egress Gateway             | `./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode` |
| Ambient 模式网格卸载               | `./run.sh --project mesh --file uninstalling-alauda-service-mesh-in-ambient-mode`           |
| Ambient 模式组件升级               | `./run.sh --project mesh --file updating-ambient-components`                                |
| Ambient Waypoint 升级验证          | `./run.sh --project mesh --file updating-waypoint-proxies`                                  |
| 多集群 - 配置概述（CA 证书）       | `./run.sh --project mesh --file configuration-overview`                                     |
| 多集群 - 多主多网络                | `./run.sh --project mesh --file install-multi-primary-multi-network`                        |
| 多集群 - 主-远多网络               | `./run.sh --project mesh --file install-primary-remote-multi-network`                       |

> 多集群测试需 `EAST_CLUSTER_NAME` / `WEST_CLUSTER_NAME` 双集群环境，并需先用双集群 `--init-only` 与 `configuration-overview` 完成 cacerts 下发。

### otel（opentelemetry-docs）

| 文档名称                 | 执行命令                                                                               |
| ------------------------ | -------------------------------------------------------------------------------------- |
| 自动创建 RBAC 资源       | `./run.sh --project otel --file rbac-resources`                                        |
| OpenTelemetry v2 安装    | `./run.sh --project otel --file install-opentelemetry`                                 |
| 无 Sidecar 发送遥测数据  | `./run.sh --project otel --file without-sidecar`                                       |
| OpenTelemetry v2 卸载    | `./run.sh --project otel --file uninstalling-opentelemetry [--skip-operator-and-crds]` |
| Java 自动注入示例        | `./run.sh --project otel --file java-instrumentation`                                  |

> 安装覆盖 `install-opentelemetry.mdx` 的「Installing the Operator」与「Deploying the OpenTelemetry Collector」CLI 章节；卸载覆盖 `uninstalling-opentelemetry.mdx` 的「Uninstalling via the CLI」与「Deleting custom resource definitions」章节。`--skip-operator-and-crds` 保留 Operator subscription 与 CRDs，便于跨 suite 场景复用。
>
> 自动创建 RBAC 资源（`rbac-resources`）覆盖 `installing/rbac-resources.mdx` 的「Procedure」与「Removing the RBAC resources」章节，给 Operator 授予管理集群级 `ClusterRole` / `ClusterRoleBinding` 的权限。须在安装 Operator **之前**执行（Operator 启动即可探测到该能力，文档中重启 Operator 为可选步骤，Operator 未安装时该步骤为空操作）。含 cleanup，编排中以 `--no-cleanup` 授权、`--cleanup-only` 回收。
>
> 无 Sidecar 发送遥测数据（`without-sidecar`）只覆盖 `configuration/send-telemetry-data/without-sidecar.mdx`「Procedure」步骤 1：以 `deployment` 模式部署带 `k8s_attributes` 处理器的 Collector（namespace `observability`），部署成功后观察日志 30s，断言无 `error` 关键词（不区分大小写）且容器未重启，用于验证 Operator 自动创建集群级 RBAC 在 `k8s_attributes` 场景下生效。因此该测试依赖先执行 `rbac-resources`。文档步骤 2 的示例应用使用占位镜像不可运行，未加 `{name=}` 标注；exporter endpoint 的 `<jaeger-instance-name>` 占位值不影响部署，保持原样。该代码块的语言标记是 `yaml`，而 `runme run` 对 `yaml` 块只回显不执行（且返回 0），故测试脚本用 `runme print` 取内容后 `eval` 执行。`observability` 命名空间的创建与清理由测试脚本负责（创建时打 `runme-test/created-by=without-sidecar` 标签，cleanup 只删带该标签的命名空间）。含 cleanup，编排中以 `--no-cleanup` 部署、`--cleanup-only` 清理，且必须在卸载 Operator 与回收 `rbac-resources` 授权之前清理（Collector 的 finalizer 依赖两者回收自动生成的集群级 RBAC）。
>
> Java 自动注入示例（`java-instrumentation`）需 `USE_MESH_V2_TEST_SUITE_PLUGIN=true`：部署 / 卸载 `mesh-v2-test-suite` 集群插件预置的 Java OTel demo（namespace `otelv2-java-demo`，含 consumer/provider/curl-client 工作负载与 Instrumentation），并校验 Operator 已自动注入 Java agent。该脚本含 cleanup，编排中以 `--no-cleanup` 安装、`--cleanup-only` 卸载。原文档 `java-instrumentation.mdx` 示例不可运行，故不加 `{name=}` 标注。

### tracing（distributed-tracing-docs）

| 文档名称                          | 执行命令                                                                         |
| --------------------------------- | -------------------------------------------------------------------------------- |
| 分布式调用链安装（Elasticsearch） | `./run.sh --project tracing --file installing-distributed-tracing-elasticsearch` |
| 分布式调用链安装（OpenSearch）    | `./run.sh --project tracing --file installing-distributed-tracing-opensearch`    |
| 分布式调用链卸载                  | `./run.sh --project tracing --file uninstalling-distributed-tracing [--skip-operator-and-crds] [--skip-cluster-plugin]` |
| 分布式调用链 v2.0→v2.1 升级（Elasticsearch） | `./run.sh --project tracing --file upgrading-distributed-tracing-elasticsearch` |
| 分布式调用链 v2.0→v2.1 升级（OpenSearch）    | `./run.sh --project tracing --file upgrading-distributed-tracing-opensearch`    |

> Elasticsearch 安装测试默认从 `TRACING_ACP_ES_CLUSTER` 指定的 ACP 集群（默认 `global`）读取 log-center Elasticsearch 配置；将其设为空时改用 `TRACING_ES_*` 手动配置（该加载逻辑位于 Elasticsearch 安装测试脚本，不再由 `project_prepare` 全局执行）。`TRACING_INSTALL_ES=true` 且 `PKG_LOG_CENTER_URL` 非空时，步骤 0 会先把 logcenter 集群插件（Single Node 模式）自动安装到该集群——对应集群已安装过则跳过（安装逻辑见 `projects/tracing/elasticsearch.sh`）。OpenSearch 安装测试默认自动安装存储后端：`TRACING_INSTALL_OPENSEARCH=true`（默认）且 `PKG_ACP_STORAGE_OPERATOR_URL` / `PKG_TOPOLVM_OPERATOR_URL` 齐全时，步骤 0 自动安装 TopoLVM + OpenSearch（幂等，opensearch-operator 插件包目前需手动上架）并用实际结果覆盖 `TRACING_OPENSEARCH_*`——OpenSearch 的 HTTP API 与 Dashboards 各由一条 Ingress 以 `/clusters/<集群名>/opensearch[-dashboards]` 子路径暴露，`TRACING_OPENSEARCH_ENDPOINT` 取前者（平台地址 + 子路径，集群内外都可访问，不再是集群内 svc 域名）；条件不满足时降级用手动 `TRACING_OPENSEARCH_ENDPOINT/USER/PASS`，两者皆缺则该测试 SKIPPED（安装逻辑见 `projects/tracing/opensearch.sh`）。卸载测试存储无关，按 Jaeger 命名空间是否存在判定是否执行；OpenSearch/TopoLVM 作为环境级存储后端不随卸载清理。卸载测试覆盖 `uninstalling-distributed-tracing.mdx` 的「Uninstalling via the CLI」全部章节，最后一步按「(Optional) Uninstall the Alauda Build of Jaeger v2 Cluster Plugin」在 Global 集群按 label 删除该插件的 `ModuleInfo`（平台会把它重命名为 `<cluster>-<hash>`，只能按 label 定位），再回目标集群确认镜像清单 ConfigMap 已回收；`--skip-cluster-plugin` 保留该插件，`--skip-operator-and-crds` 保留 OTel Operator subscription 与 CRDs——编排脚本里的调用两个都带，供后续 case 复用。两个安装测试的步骤 1 会先按文档「Installing the Alauda Build of Jaeger v2 Cluster Plugin」CLI 章节安装 Jaeger v2 集群插件：`PKG_JAEGER_CLUSTER_PLUGIN_URL` 非空时若未上架会自动下载并 violet push 到 Global；留空则进入 verify-only 模式，要求该插件已在 Global 集群预上架，否则报错退出并提示确认 release-config 是否已声明该包；已安装则两种模式都幂等复用（两篇文档该章节内容一致，安装逻辑抽象为按 runme 前缀参数化的共享函数，见 `projects/tracing/jaeger-plugin.sh`），步骤 2 自动安装前置依赖 OpenTelemetry v2 Operator（其代码块位于 `opentelemetry-docs`）。两篇升级测试（v2.0 → v2.1）要求环境上**先有一套 v2.0 部署**（Jaeger 2.16.0 + Alauda Build of OpenTelemetry v2 Operator 0.147.0），本框架不负责搭建：脚本开头按「Jaeger 命名空间与实例存在 / 存储后端与本篇匹配 / 配置里带 v2.0 特征字段（ES 看 `use_aliases`、`use_ilm`，OpenSearch 看 `indices.spans.date_layout`）」三条做门槛，任一不满足即 `skip_test_env` 退出，不会误伤 Case 2-5 装出来的 v2.1 环境；升级完成后重复执行同样会因门槛而 SKIPPED。两篇文档 23 / 29 个代码块中有 16 个逐字节相同（集群插件安装、Operator 升级、otel Collector 配置迁移、两段 SPM patch、收尾验证），已按 runme 前缀参数化抽到 `distributed-tracing-docs/docs/en/upgrading/_upgrade-common.sh`（落点与同仓 `_spm-ha-common.sh` 一致）；差异只剩存储侧中段与两次 patch 的先后顺序——**Elasticsearch 篇先换 oauth2-proxy 镜像再打配置 patch，OpenSearch 篇必须反过来**，否则那次重启会让 v2.16 用默认的 `create_mappings=true` 覆盖掉 `jaeger-es-rollover init` 刚写的索引模板。ISM policy 的两个辅助函数（清理遗留 policy、等待 ISM 接管写索引）由 OpenSearch 安装测试与升级测试共用，位于 `projects/tracing/opensearch.sh`。两段 (Optional) SPM 章节按当前部署是否配了 spanmetrics connector 自动决定跑不跑，`TRACING_TEST_SPM=false` 可强制跳过。

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

### 5. mesh 网关安装 / Linux 内核兼容公共函数

`projects/mesh/project.sh` 提供以下网关相关公共函数（封装自 `gateways/gateway-installation/` 两篇文档），供 `directing-traffic-into-the-mesh` / `directing-outbound-traffic` / `install-*-multi-network` 等测试复用：

| 函数                                                                              | 用途                                                                                                                              |
| --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `install_gateway_via_injection <gw_name> <gw_ns> [context]`                       | 通过 gateway injection 安装网关（含可选 HPA/PDB；去 infra 调度；`ENABLE_GW_LINUX_KERNEL_COMPAT=true` 时 Deployment 以 root 运行） |
| `apply_kernel_compat_istio_gateway [run_as_root=true] [context]`                  | Istio Gateway（注入）路径内核兼容：修补 mesh 级注入模板并等待 Istio Ready；关时 no-op                                             |
| `apply_kernel_compat_k8s_gateway_api <ns> <gw_name> [run_as_root=true] [context]` | K8s Gateway API 路径内核兼容：建 `asm-kube-gateway-options` ConfigMap 并给 Gateway 挂 `parametersRef`；关时 no-op                 |
| `relax_psa_for_root_gateway <ns> [run_as_root=true] [context]`                    | 内核兼容且网关以 root 运行时，把该命名空间的 PSA `enforce` 从 `restricted` 放宽为 `baseline`；关时 no-op                          |

> 两个 `apply_kernel_compat_*` 受 `ENABLE_GW_LINUX_KERNEL_COMPAT` 门控（默认 false 时直接返回）。`run_as_root=false` → Scenario 1（仅去 sysctls，高端口网关）；`true` → Scenario 2（+ NET_BIND_SERVICE + root，特权端口网关）。多集群东西向网关与 ambient waypoint 传 `false`；监听 80 的 ambient ingress 网关用默认 `true`。

> **与 Restricted PSA 的关系**：文档已把 bookinfo / httpbin / curl / egress-gateway 等测试应用命名空间设为 `pod-security.kubernetes.io/enforce=restricted`。Restricted profile 禁止 root 容器，与 Scenario 2 的 `runAsUser: 0` 互斥，故 `apply_kernel_compat_k8s_gateway_api` 与 `reconcile_injected_gateway_runasroot` 在 `run_as_root=true` 时会先调 `relax_psa_for_root_gateway` 把命名空间放宽为 `baseline`（与 `linux-kernel-compatibility-notice.mdx` 的结论一致）。默认 `ENABLE_GW_LINUX_KERNEL_COMPAT=false` 时不触发，命名空间保持 Restricted。
>
> Gateway API 网关与 waypoint 的 seccomp 配置走另一条通道：`Istio` 资源的 `spec.values.gatewayClasses.<class>.deployment` overlay，由各文档自己的 `*:patch-gatewayclass*` 代码块下发（详见 `installing/pod-security-admission.mdx`），必须在创建 `Gateway` 之前执行。

## 测试结果统计（三层：Run → Case → DocTest）

测试统计由 `framework/report.sh` 提供，数据源为每次运行的 `results.jsonl`（JSON Lines）。

- **Run**：一次 `run-<project>-all.sh` 或一次独立 `./run.sh --file`。
- **Case**：编排脚本中的一个用例组（`case_begin`/`case_end`），内含一到多个 `./run.sh`。
- **DocTest**：一次 `./run.sh --file <doc>`，对应一篇文档的 `runme-test_<doc>.sh`。

**失败策略**：跑完全部再汇总——致命前置（环境初始化）失败立即中止；普通 Case 失败记录后继续。

**状态三态**：passed / failed / **skipped**。文档脚本按语义主动声明：环境/版本/依赖不具备用 `skip_test_env "原因"`，产品版本、架构或测试范围明确不测用 `skip_test_expected "原因"`；两者分别打 `[env]` / `[expected]` 前缀，供 allure 报告的「环境不支持」「预期不测试」分类识别。`skip_test` 是 `skip_test_expected` 的历史别名（等同 `[expected]`），新脚本请直接用语义正确的那个，不要再用 `skip_test`。编排层条件跳过用 `case_skip <case_id> <case_name> <reason> [category]`，`category` 同样是 `env` / `expected`（默认 `expected`）。

**产物**（位于 `tmp/runs/<run-id>/`，`latest` 软链指向最近一次）：

| 文件            | 说明                                      |
| --------------- | ----------------------------------------- |
| `results.jsonl` | 唯一数据源，每行一条记录                  |
| `summary.json`  | 三层结构化汇总（两套计数 + 每 Case 明细） |
| `junit.xml`     | 标准 JUnit，对接 CI                       |

终端结束时打印美化摘要（总耗时、Case/DocTest 两套计数、每 Case 一行、失败/跳过明细）。退出码：有 failed→非 0。

**运行报告层单元测试**（不依赖集群）：

```bash
bash framework/tests/report_test.sh
# 其余框架单测（同样不依赖集群与平台，伪造 kubectl/runme/allure）
bash framework/tests/acp_auth_test.sh
bash framework/tests/allure_test.sh
bash framework/tests/assets_test.sh
bash framework/tests/case_filter_test.sh
bash framework/tests/create_namespace_test.sh
bash framework/tests/entrypoint_test.sh
bash framework/tests/env_adapter_test.sh
bash framework/tests/install_cluster_plugin_test.sh
bash framework/tests/install_operator_test.sh
bash framework/tests/ip_pool_test.sh
bash framework/tests/mesh_project_test.sh
bash framework/tests/verify_only_test.sh
```

## 编写新测试

推荐使用 Claude Code 的 `/auto-test-creator` skill 自动生成测试脚本，定义见 `.claude/skills/auto-test-creator/SKILL.md`。它会分析 MDX、添加 `{name=}` 属性、生成测试脚本、更新本文档与编排脚本。

## 故障排除

| 问题                      | 排查                                                                       |
| ------------------------- | -------------------------------------------------------------------------- |
| 找不到 runme / violet     | 执行 `./run.sh --project <项目> --init-only` 重新安装工具                  |
| kubeconfig 获取失败 / 401 | 检查 `PLATFORM_ADDRESS` 是否可达、集群名是否正确；token 过期会自动重新获取，可 `rm -rf .acp-auth` 强制刷新 |
| 自动获取 ACP API Token 失败 | 核对 `PLATFORM_USERNAME` / `PLATFORM_PASSWORD`；账号触发验证码、二次验证或需改密码时改为手工配置 `ACP_API_TOKEN` |
| 未找到测试脚本            | 确认 `repos.conf` 中对应仓库存在；脚本名为 `runme-test_<file>.sh`          |
| 测试脚本在多个项目重名    | 用 `--project` 显式指定                                                    |
| 测试执行失败              | `cd` 到对应文档仓库手动执行失败的 `runme run <block>` 调试                 |

## 参考资料

- [runme 官方文档](https://runme.dev)
- [Istio 文档测试](https://github.com/istio/istio.io/blob/master/tests/README.md)
