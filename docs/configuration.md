# 环境准备与配置

## 1. 系统要求

执行测试的机器（不是 k8s 集群）必须能访问 GitHub。

预装：`kubectl`、`curl`、`jq`、`openssl`。框架自动安装 `runme` / `violet`（mesh 另装 `istioctl`）。

## 2. repos.conf 仓库注册表

登记每个项目对应的文档仓库路径：

```
mesh:../servicemesh2-docs
otel:../opentelemetry-docs
tracing:../distributed-tracing-docs
```

- 路径相对本仓库根，或写绝对路径；目录不存在的条目静默跳过。
- 可用 `<PROJECT>_REPO_ROOT` 覆盖（如 `MESH_REPO_ROOT=/abs/path`）。
- 引擎据此 export `FRAMEWORK_ROOT`、`DOC_REPO_ROOT`、`<PROJECT>_REPO_ROOT` 给测试脚本。

## 3. 通用环境变量

```bash
# ── 集群名称 ────────────────────────────────────────────────
export SINGLE_CLUSTER_NAME=my-cluster
# 仅 mesh 的 multi-cluster 文档使用
export EAST_CLUSTER_NAME=east-cluster
export WEST_CLUSTER_NAME=west-cluster

# ── 平台信息（必需）─────────────────────────────────────────
export PLATFORM_ADDRESS=https://xxx
export PLATFORM_USERNAME='your-username'
export PLATFORM_PASSWORD='your-password'
# ACP_API_TOKEN 可选：留空时引擎用上面三项自动换取（见第 5 节），
# 仅在需要固定 token（如 UI 生成的长期 token）时才配置
# export ACP_API_TOKEN='your-acp-api-token'

# 集群连接模式（可选，默认 direct；多集群网格必须 direct）
export ACP_KUBECONFIG_MODE=direct
# 平台 CA（可选，留空则 mesh 测试自动从 Global 集群拉取）
# export PLATFORM_CA='base64-encoded-ca-certificate'
export GLOBAL_CLUSTER_NAME=global

# ── 工具与镜像 ──────────────────────────────────────────────
export RUNME_VERSION=3.16.11
export USE_MESH_V2_TEST_SUITE_PLUGIN=true
export REGISTRY_MIRROR_ADDRESS=docker-mirrors.alauda.cn
```

**必需变量**（引擎 `check_env` 校验）：`RUNME_VERSION`、`PLATFORM_ADDRESS`、`PLATFORM_USERNAME`、`PLATFORM_PASSWORD`。

三个项目的 `project_check_env` 均无强制变量——所有 `PKG_*_URL` 都可选，留空即 verify-only（见第 6 节）。

## 4. mesh 测试行为开关

```bash
export IS_DUAL_STACK=false
export AUTO_GEN_BOOKINFO_TRAFFIC=true
export KIALI_VERIFY_MONITORING=false
export ENABLE_GW_LINUX_KERNEL_COMPAT=false
export ENABLE_METALLB=false
# 仅 ENABLE_METALLB=true 时需要，JSON 数组（ipv6Addresses 为将来预留）
export METALLB_EXTERNAL_ADDRESSES_JSON='[{"cluster":"business-1","ipv4Addresses":["192.168.139.13/32"]}]'
```

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `IS_DUAL_STACK` | `false` | 集群是否双栈，决定 Case 2 是否可跑 |
| `AUTO_GEN_BOOKINFO_TRAFFIC` | `true` | 部署 bookinfo 后自动打流量 |
| `AUTO_GEN_SAMPLE_TRAFFIC` | 继承 `AUTO_GEN_BOOKINFO_TRAFFIC` | 多集群 `sample` 命名空间部署完成后，在两个集群的 `sleep` pod 里各起一个后台循环访问 `helloworld`，供 Kiali 多集群用例观测跨集群流量 |
| `KIALI_VERIFY_MONITORING` | `false` | 装完 Kiali 后额外验证监控可用：断言 `istiod` / `prometheus`（已对接调用链时含 `tracing`）为 Healthy，且 bookinfo 命名空间能算出速率大于 0 的边。sidecar 看 http 边、ambient 看 ztunnel tcp 边。依赖 bookinfo 已部署；命名空间用 `KIALI_VERIFY_NAMESPACE` 覆盖 |
| `KIALI_VERIFY_NAMESPACE` | `bookinfo` | 流量图断言使用的命名空间。打流量的客户端按该命名空间里实际部署的示例应用选：`bookinfo` 用 `ratings` → `productpage`，多集群的 `sample` 用 `sleep` → `helloworld`（Case 6/7 即以 `sample` 运行 `--file kiali`） |
| `ENABLE_GW_LINUX_KERNEL_COMPAT` | `false` | 仅内核 < 4.11（CentOS 7）需要。开启后高端口网关走 Scenario 1（去 sysctls），特权端口网关走 Scenario 2（+ NET_BIND_SERVICE + root），详见 [architecture.md](architecture.md#5-mesh-网关与内核兼容公共函数) |
| `ENABLE_METALLB` | `false` | 是否安装 MetalLB 集群插件。多集群网格与入口网关 LoadBalancer 场景需要 |

`ENABLE_METALLB=false` 时，编排脚本主动跳过两组必失败的测试：

- mesh Case 3/5 的三篇 `exposing-*` 入口网关文档（日志 `log_warn`，不产用例记录）
- mesh Case 6/7 多集群网格（按 `env` 分类 `case_skip`，报告里可见）

`METALLB_EXTERNAL_ADDRESSES_JSON` 由 `setup_external_ip_pools` 在建池时校验（不在 `project_check_env`）：多集群需含 `cluster=$EAST_CLUSTER_NAME` / `$WEST_CLUSTER_NAME` 条目，单集群入口网关需含 `cluster=$SINGLE_CLUSTER_NAME` 条目。

> 地址池所有权：`docs-test init` 创建的池带 `runme-test/owner=init` 标签，长期存在不清理；单篇测试自建的池带 `owner=doctest`，用完即删。池已存在时直接复用，不再要求该变量。

## 5. ACP API Token 自动获取

调用 ACP 平台 API（拉 kubeconfig 等）需要 `ACP_API_TOKEN`，**不必手工去 UI 生成**：配置了 `PLATFORM_ADDRESS` / `PLATFORM_USERNAME` / `PLATFORM_PASSWORD` 后，`run.sh` 的 `ensure_acp_api_token` 会自动登录换取。

取值优先级：

1. 已配置且校验通过的 `ACP_API_TOKEN`（校验：`GET /auth/v1/clusters` 返回 200）
2. `.acp-auth/token.json` 中未过期的缓存（按「平台地址 + 用户名」指纹匹配）
3. 用账号密码登录获取，成功后写入缓存

已配置的 token 校验失败（过期 / 换环境）且账号密码齐全时，会告警并自动改用登录获取。

登录流程与 ACP 登录页一致（OIDC implicit，不需要 dex client secret），实现见 `framework/acp-auth.sh`。token 由 dex 签发，有效期通常 24 小时。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `ACP_AUTH_CACHE_DIR` | `<仓库根>/.acp-auth` | token 缓存目录（600 权限，已 gitignore） |
| `ACP_AUTH_NO_CACHE` | `false` | `true` 时每次重新登录 |
| `ACP_AUTH_EXPIRY_MARGIN` | `1800` | 缓存剩余有效期低于该秒数视为过期 |
| `ACP_AUTH_DEX_CLIENT_ID` | `alauda-auth` | dex client id |
| `ACP_AUTH_DEX_CONNECTOR` | 自动探测（通常 `local`） | 对接外部 IdP 时可显式指定 |

账号触发验证码 / 二次验证 / 首次登录改密码时无法自动登录，改为手工配置 `ACP_API_TOKEN`。

## 6. 插件包地址与 verify-only

> **所有 `PKG_*_URL` 均为可选。** 留空时框架不下载、不上架，改为直接校验该包是否已在集群上架（Operator 查 PackageManifest，集群插件查 ModuleConfig）并反查目标版本。这正是 dailybuild 的用法——包由 lynx 依据 Release YAML 预上架，测试 Pod 不需要访问 package-minio。本地手工跑则提供地址，由框架自行下载上架。

```bash
# Operator 包
export PKG_SERVICEMESH_OPERATOR2_URL=xxx      # mesh
export PKG_KIALI_OPERATOR_URL=xxx             # mesh
export PKG_OPENTELEMETRY_OPERATOR2_URL=xxx    # mesh / otel / tracing 均需
# 集群插件包
export PKG_MULTUS_URL=xxx                     # mesh 前提，始终需要
export PKG_METALLB_URL=xxx                    # 仅 ENABLE_METALLB=true
export PKG_METALLB_OPERATOR_URL=xxx           # 仅 ENABLE_METALLB=true（metallb 前置）
export PKG_MESH_V2_TEST_SUITE_URL=xxx         # 仅 USE_MESH_V2_TEST_SUITE_PLUGIN=true
export PKG_JAEGER_CLUSTER_PLUGIN_URL=xxx      # tracing：Alauda Build of Jaeger v2
```

## 7. 分布式调用链（tracing）专用

```bash
# ── Elasticsearch ───────────────────────────────────────────
# ACP ES 所在集群（默认 global；设为空则用下方手动配置）
export TRACING_ACP_ES_CLUSTER=global
export TRACING_ES_ENDPOINT='https://es.xx:9200'
export TRACING_ES_USER='your-es-username'
export TRACING_ES_PASS='your-es-password'
export TRACING_INSTALL_ES=false
export PKG_LOG_CENTER_URL=xxx
# export TRACING_ES_K8S_NODE=xxx    # Log/Kafka 节点，默认取目标集群首个 Ready 节点

# ── OpenSearch ──────────────────────────────────────────────
export TRACING_INSTALL_OPENSEARCH=true
export PKG_ACP_STORAGE_OPERATOR_URL=xxx   # ACP Storage Essentials
export PKG_TOPOLVM_OPERATOR_URL=xxx       # Alauda Build of TopoLVM
export PKG_OPENSEARCH_OPERATOR_URL=xxx    # Alauda support for OpenSearch
export TRACING_TOPOLVM_DEVICE=/dev/vdb    # 节点空闲磁盘设备
# 手动配置（自动安装条件不满足时使用）
export TRACING_OPENSEARCH_ENDPOINT='https://opensearch.xx:9200'
export TRACING_OPENSEARCH_USER='your-opensearch-username'
export TRACING_OPENSEARCH_PASS='your-opensearch-password'

# ── 测试行为 ────────────────────────────────────────────────
export TRACING_TELEMETRYGEN_TEST_DURATION_1=30s    # 覆盖文档默认 150s，加快测试
export TRACING_TELEMETRYGEN_TEST_DURATION_2=130s
export TRACING_TEST_SPM=true                       # 测 SPM 章节，需 ACP monitoring
export TRACING_VERIFY_TRACE_QUERY=false            # 调用链查询验证
# 覆盖两篇安装测试的调用链索引前缀（留空/不设 = 文档默认的 acp-<集群名>）
export TRACING_JAEGER_ES_INDEX_PREFIX=acp-mesh
```

**Elasticsearch 自动安装**：`TRACING_INSTALL_ES=true` 且 `PKG_LOG_CENTER_URL` 非空时，安装测试步骤 0 把 logcenter 集群插件（Single Node 模式）装到 `TRACING_ACP_ES_CLUSTER` 指定集群；已装过则跳过（幂等）。安装逻辑见 `projects/tracing/elasticsearch.sh`。

**OpenSearch 自动安装**（默认开启）：前提是业务集群至少 3 个节点、各节点有空闲裸盘。开启且 TopoLVM 两个包地址齐全时，步骤 0 自动安装 TopoLVM + OpenSearch 并用实际结果覆盖 `TRACING_OPENSEARCH_*`，无需手动配置；条件不满足时降级用手动配置。三个包都按需下载上架，已上架的跳过（`opensearch-operator` 的包 3GB 级别，重复下载代价高）。安装逻辑见 `projects/tracing/opensearch.sh`。

可选覆盖项（一般不用改）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TRACING_OPENSEARCH_VERSION` | `3.7.0` | 需与 opensearch-operator 包内置镜像 tag 对应 |
| `TRACING_OPENSEARCH_DASHBOARDS_VERSION` | `3.7.0` | 同上 |
| `TRACING_OPENSEARCH_OPERATOR_NS` | `opensearch-operator` | 集群上已有该 operator 时自动沿用其命名空间 |
| `TRACING_OPENSEARCH_OPERATOR_CHANNEL` | 包的 `defaultChannel` | |
| `TRACING_OPENSEARCH_BASEPATH` | `/clusters/<集群名>/opensearch` | HTTP API Ingress 路径；自动安装时 endpoint = 平台地址 + 该路径 |
| `TRACING_OPENSEARCH_DASHBOARDS_BASEPATH` | `/clusters/<集群名>/opensearch-dashboards` | Dashboards Ingress 路径 |

**多集群网格的调用链**：两篇安装测试都支持 `--cluster <name>`，多集群网格的每个集群都要装一套调用链（Jaeger 与 OTel Collector 都是集群内组件）；`--cluster` 除切换 kubeconfig 默认 context 外，还决定 Jaeger v2 集群插件落到哪个集群（引擎导出 `TEST_TARGET_CLUSTER`，见 [architecture.md](architecture.md)）。调用链索引反过来要共用一套，否则同一条跨集群链路会被拆进各集群自己的索引：

```bash
export TRACING_JAEGER_ES_INDEX_PREFIX=acp-mesh    # 两个集群共用
./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --cluster "$EAST_CLUSTER_NAME"
./run.sh --project tracing --file installing-distributed-tracing-elasticsearch --cluster "$WEST_CLUSTER_NAME"
```

第二个集群的安装对已有索引是空操作：`jaeger-es-rollover init` 建索引/别名前先查存在性，模板 PUT 本身幂等。Elasticsearch 篇默认就共用 Global 的 ACP ES（`TRACING_ACP_ES_CLUSTER=global`），前缀一改即生效；OpenSearch 篇的自动安装是**每个集群各建一套实例**，要共用索引须改为 `TRACING_INSTALL_OPENSEARCH=false` + 手动 `TRACING_OPENSEARCH_*` 指向同一实例（第二个集群会重建同名 ISM policy，内容相同，幂等）。

**调用链查询验证**（`TRACING_VERIFY_TRACE_QUERY=true`）：两篇安装测试在 telemetrygen 之后，走 ACP 的 Service 代理（不经 Jaeger Ingress 与 oauth2-proxy）依次查 Jaeger v3 Query API 的 `/services`、`/operations`、`/trace-summaries`，断言窗口内至少有 `TRACING_VERIFY_TRACE_MIN_COUNT`（默认 2）条调用链，不够就整轮重试。用 `TRACING_VERIFY_TRACE_SERVICE` 覆盖默认服务名；重试与窗口见 `projects/tracing/trace-query.sh`。

## 8. kubeconfig 自动管理

执行 `--init-only` / `--force-init` 时，框架通过 ACP 平台 API 自动获取集群 kubeconfig 并缓存于 `.kubeconfig/`。配置指纹（`PLATFORM_ADDRESS` / `ACP_KUBECONFIG_MODE` / `ACP_API_TOKEN` / 集群列表）变更时自动重拉。

mesh 项目会在集群列表末尾自动追加 Global 集群（用于自动获取 `PLATFORM_CA`）。
