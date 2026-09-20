# 各项目测试清单

## mesh（servicemesh2-docs）

| 文档名称 | 执行命令 |
| --- | --- |
| 双栈网格安装 | `./run.sh --project mesh --file install-mesh-in-dual-stack-mode` |
| 网格安装 | `./run.sh --project mesh --file install-mesh` |
| Pod Security Admission（网关类） | `./run.sh --project mesh --file pod-security-admission` |
| Istio HA - 自动伸缩 | `./run.sh --project mesh --file configuring-istio-ha-by-using-autoscaling` |
| Istio HA - 固定副本数 | `./run.sh --project mesh --file configuring-istio-ha-by-using-replica-count` |
| 指标与服务网格集成 | `./run.sh --project mesh --file metrics-and-mesh [--cluster <name>]` |
| 网格调用链集成配置 | `./run.sh --project mesh --file config-tracing-with-service-mesh [--cluster <name>]` |
| Kiali 安装与配置 | `./run.sh --project mesh --file kiali` |
| Bookinfo 应用部署（含网关） | `./run.sh --project mesh --file deploying-the-bookinfo-application` |
| 严格 mTLS（命名空间级） | `./run.sh --project mesh --file mtls` |
| Sidecar 网关 - Istio Gateway | `./run.sh --project mesh --file exposing-a-service-via-istio-gateway` |
| Sidecar 网关 - K8s Gateway API | `./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-sidecar-mode` |
| Sidecar 出口网关 - Istio APIs | `./run.sh --project mesh --file routing-egress-traffic-via-istio-apis` |
| Sidecar 出口网关 - K8s Gateway API | `./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-sidecar-mode` |
| Kiali 卸载 | `./run.sh --project mesh --file uninstalling-alauda-build-of-kiali` |
| 网格卸载 | `./run.sh --project mesh --file uninstalling-alauda-service-mesh` |
| InPlace 更新策略 | `./run.sh --project mesh --file update-inplace` |
| Istio CNI 升级 | `./run.sh --project mesh --file istio-cni` |
| RevisionBased 更新策略 | `./run.sh --project mesh --file update-revisionbased` |
| RevisionBased + 版本标签 | `./run.sh --project mesh --file update-revisionbased-and-istiorevisiontag` |
| Ambient Mode 安装 | `./run.sh --project mesh --file installing-ambient-mode` |
| Ambient Bookinfo 部署 | `./run.sh --project mesh --file deploying-ambient-bookinfo` |
| Waypoint 代理部署 | `./run.sh --project mesh --file waypoint-proxies` |
| Ambient L7 特性 | `./run.sh --project mesh --file ambient-l7-features` |
| Ambient Gateway API | `./run.sh --project mesh --file exposing-a-service-via-k8s-gateway-api-in-ambient-mode` |
| Ambient Egress Gateway | `./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode` |
| Ambient 模式网格卸载 | `./run.sh --project mesh --file uninstalling-alauda-service-mesh-in-ambient-mode` |
| Ambient 模式组件升级 | `./run.sh --project mesh --file updating-ambient-components` |
| Ambient Waypoint 升级验证 | `./run.sh --project mesh --file updating-waypoint-proxies` |
| 多集群 - 配置概述（CA 证书） | `./run.sh --project mesh --file configuration-overview` |
| 多集群 - 多主多网络 | `./run.sh --project mesh --file install-multi-primary-multi-network` |
| 多集群 - 主-远多网络 | `./run.sh --project mesh --file install-primary-remote-multi-network` |
| 多集群 - Kiali 接入 | `./run.sh --project mesh --file install-kiali-in-multi-cluster-mesh` |

> 多集群测试需 `EAST_CLUSTER_NAME` / `WEST_CLUSTER_NAME` 双集群环境，并需先用双集群 `--init-only` 与 `configuration-overview` 完成 cacerts 下发。

**多集群 - Kiali 接入**：跑在任一多集群拓扑的 `--no-cleanup` 之上，要求两个集群都做过监控对接、East 已装好 Kiali server：

```bash
./run.sh --project mesh --file metrics-and-mesh --cluster "$EAST_CLUSTER_NAME" --no-cleanup
./run.sh --project mesh --file metrics-and-mesh --cluster "$WEST_CLUSTER_NAME" --no-cleanup
KIALI_VERIFY_NAMESPACE=sample ./run.sh --project mesh --file kiali --cluster "$EAST_CLUSTER_NAME"
./run.sh --project mesh --file install-kiali-in-multi-cluster-mesh --no-cleanup
./run.sh --project mesh --file install-kiali-in-multi-cluster-mesh --cleanup-only
```

- `--cluster` 在 `--file` 模式下指定测试执行的目标集群（切换 kubeconfig 的默认 context）。监控是按集群分别抓取的，`metrics-and-mesh` 必须在两个集群各跑一遍；主-远拓扑的远端集群没有控制面，该用例会自行跳过 `Telemetry`（apply 会被 `validation.istio.io` webhook 拒）。
- West 集群的 `kiali-operator` 由本用例自行补齐（文档前提要求每个集群都装 Operator，而 `--file kiali` 只作用于 East）。
- 流量图断言用 `sample` 命名空间：多集群的示例应用是 `sleep` + `helloworld`，没有 bookinfo。两个集群的 `sleep` 后台流量由 `maybe_gen_sample_traffic` 在多集群安装用例里启动。
- `--cleanup-only` 覆盖文档的「Removing a cluster from Kiali」与「Cleaning up Kiali」两节，会删掉 East 的 `Kiali` CR；随后的 `uninstalling-alauda-build-of-kiali` 只卸 Operator 与 CRDs。

**网格调用链集成配置（多集群）**：`--cluster <name>` 指定执行目标集群，网格侧配置（`Istio` + `Telemetry`）按控制面走——多主拓扑两个集群各配一遍；主-远拓扑只配主集群，远端集群没有本地 istiod（sidecar 的 tracing 配置由主集群 istiod 下发，`Telemetry asm-default` 也不存在），该用例在远端集群只做 `jaeger-system` 服务发现标签，其余步骤自行跳过。调用链平台本身要在每个集群各装一套并共用索引前缀（见下方 tracing 章节）。多集群编排（Case 6/7）尚未接入这两个用例，需要时按上面的命令手动执行。

## otel（opentelemetry-docs）

| 文档名称 | 执行命令 |
| --- | --- |
| 自动创建 RBAC 资源 | `./run.sh --project otel --file rbac-resources` |
| OpenTelemetry v2 安装 | `./run.sh --project otel --file install-opentelemetry` |
| 无 Sidecar 发送遥测数据 | `./run.sh --project otel --file without-sidecar` |
| OpenTelemetry v2 卸载 | `./run.sh --project otel --file uninstalling-opentelemetry [--skip-operator-and-crds]` |
| Java 自动注入示例 | `./run.sh --project otel --file java-instrumentation` |

**安装 / 卸载**：覆盖两篇文档的 CLI 章节。`--skip-operator-and-crds` 保留 Operator subscription 与 CRDs，便于跨 suite 复用。

**rbac-resources**：给 Operator 授予管理集群级 `ClusterRole` / `ClusterRoleBinding` 的权限，须在安装 Operator **之前**执行（Operator 启动即探测该能力；文档中重启 Operator 为可选步骤，Operator 未安装时为空操作）。含 cleanup，编排中以 `--no-cleanup` 授权、`--cleanup-only` 回收。

**without-sidecar**：只覆盖「Procedure」步骤 1——以 `deployment` 模式部署带 `k8s_attributes` 处理器的 Collector（namespace `observability`），部署成功后观察日志 30s，断言无 `error` 关键词且容器未重启，用于验证自动创建的集群级 RBAC 在该场景下生效，因此**依赖先执行 `rbac-resources`**。清理必须在卸载 Operator 与回收 `rbac-resources` 授权**之前**（Collector 的 finalizer 依赖两者）。

> 文档步骤 2 的示例应用用占位镜像不可运行，未加 `{name=}` 标注。该代码块语言标记是 `yaml`，测试脚本用 `runme print` + `eval` 执行（见 [architecture.md](architecture.md#1-runme-工具)）。

**java-instrumentation**：需 `USE_MESH_V2_TEST_SUITE_PLUGIN=true`。部署 / 卸载 `mesh-v2-test-suite` 插件预置的 Java OTel demo（namespace `otelv2-java-demo`），校验 Operator 已自动注入 Java agent。原文档示例不可运行，故不加 `{name=}` 标注。

## tracing（distributed-tracing-docs）

| 文档名称 | 执行命令 |
| --- | --- |
| 分布式调用链安装（Elasticsearch） | `./run.sh --project tracing --file installing-distributed-tracing-elasticsearch [--cluster <name>]` |
| 分布式调用链安装（OpenSearch） | `./run.sh --project tracing --file installing-distributed-tracing-opensearch [--cluster <name>]` |
| 分布式调用链卸载 | `./run.sh --project tracing --file uninstalling-distributed-tracing [--skip-operator-and-crds] [--skip-cluster-plugin]` |
| 分布式调用链 v2.0→v2.1 升级（Elasticsearch） | `./run.sh --project tracing --file upgrading-distributed-tracing-elasticsearch` |
| 分布式调用链 v2.0→v2.1 升级（OpenSearch） | `./run.sh --project tracing --file upgrading-distributed-tracing-opensearch` |

### 两篇安装测试

- **步骤 1** 按文档 CLI 章节安装 Jaeger v2 集群插件：`PKG_JAEGER_CLUSTER_PLUGIN_URL` 非空时未上架就自动下载并 violet push 到 Global；留空则 verify-only，要求已预上架否则报错退出（提示确认 release-config 是否声明该包）。已安装则两种模式都幂等复用。两篇文档该章节内容一致，安装逻辑抽象为按 runme 前缀参数化的共享函数（`projects/tracing/jaeger-plugin.sh`）。
- **步骤 2** 自动安装前置依赖 OpenTelemetry v2 Operator（其代码块位于 `opentelemetry-docs`）。
- **存储后端**：ES 篇与 OpenSearch 篇的自动安装 / 手动降级规则见 [configuration.md 第 7 节](configuration.md#7-分布式调用链tracing专用)。两者皆缺时该测试 SKIPPED。
- 两段 (Optional) SPM 章节按当前部署是否配了 spanmetrics connector 自动决定跑不跑，`TRACING_TEST_SPM=false` 可强制跳过。
- **多集群网格**：`--cluster <name>` 指定安装目标集群，多集群网格的每个集群都要装一套调用链（Jaeger + OTel Collector 都是集群内组件）。调用链索引则要共用一套，否则同一条跨集群链路会被拆进各集群自己的索引里——用 `TRACING_JAEGER_ES_INDEX_PREFIX` 覆盖文档默认的 `acp-<集群名>`，详见 [configuration.md 第 7 节](configuration.md#7-分布式调用链tracing专用)。
- `TRACING_VERIFY_TRACE_QUERY=true` 时会在 telemetrygen 之后、SPM 章节之前插入调用链查询验证，SPM 章节重新部署 telemetrygen 之后还会再验一次（那段 patch 重启过 Jaeger 又改了 Collector 路由，两处都可能弄坏 span 写入通路，而 spanmetrics 指标走 monitoring 存储，指标正常并不能说明调用链还查得出来）。

### 卸载测试

存储无关，按 Jaeger 命名空间是否存在判定是否执行；OpenSearch / TopoLVM 作为环境级存储后端不随卸载清理。

覆盖「Uninstalling via the CLI」全部章节，最后一步在 Global 集群**按 label** 删除 Jaeger v2 插件的 `ModuleInfo`——平台会把它重命名为 `<cluster>-<hash>`，只能按 label 定位——再回目标集群确认镜像清单 ConfigMap 已回收。编排脚本的调用同时带 `--skip-cluster-plugin` 与 `--skip-operator-and-crds`，供后续 Case 复用。

### 两篇升级测试（v2.0 → v2.1）

要求环境上**先有一套 v2.0 部署**（Jaeger 2.16.0 + OpenTelemetry v2 Operator 0.147.0），本框架不负责搭建。脚本开头按三条门槛判定，任一不满足即 `skip_test_env` 退出：

1. Jaeger 命名空间与实例存在
2. 存储后端与本篇匹配
3. 配置里带 v2.0 特征字段（ES 看 `use_aliases` / `use_ilm`，OpenSearch 看 `indices.spans.date_layout`）

这样既不会误伤 Case 2-5 装出来的 v2.1 环境，升级完成后重复执行也会因门槛而 SKIPPED。

两篇的公共代码块已按 runme 前缀参数化抽到 `distributed-tracing-docs/docs/en/upgrading/_upgrade-common.sh`。剩余差异是存储侧中段与两次 patch 的先后顺序：

> **Elasticsearch 篇先换 oauth2-proxy 镜像再打配置 patch，OpenSearch 篇必须反过来。** 否则那次重启会让 v2.16 用默认的 `create_mappings=true` 覆盖掉 `jaeger-es-rollover init` 刚写的索引模板。

## registry（acp-docs）

被测文档位于 `acp-docs` 的 `docs/en/configure/registry/` 与 `docs/en/developer/registry/`。
测试脚本与对应 `.mdx` 同仓同目录（`runme-test_<doc>.sh`）。

| 文档名称 | 执行命令 |
| --- | --- |
| Registry Operator 安装与状态 | `./run.sh --project registry --file image-registry-operator` |
| 存储配置与启用 | `./run.sh --project registry --file setting-up-and-configuring-the-registry` |
| 访问 Registry | `./run.sh --project registry --file accessing-the-registry` |
| 镜像管理（ac 命令） | `./run.sh --project registry --file managing-images-with-ac` |
| 权限、用量与清理 | `./run.sh --project registry --file managing-access-and-cleanup` |
| 暴露 Registry | `./run.sh --project registry --file exposing-the-registry` |
| Operator 升级 | `./run.sh --project registry --file image-registry-operator-upgrade` |

全量编排：`./run-registry-all.sh`

### 前置条件

1. **ACP 4.4 环境**。二选一：
   - 已有环境：导出 `PLATFORM_ADDRESS` / `PLATFORM_USERNAME` / `PLATFORM_PASSWORD`
   - 现场造：`./provision.sh --project registry`（天翼云路径，见 [registry-project.md](registry-project.md#环境供给)）
2. **Operator 包上架**。全新 ACP 4.4 环境的 OperatorHub 里**没有** `cluster-image-registry-operator`，
   需通过 `PKG_REGISTRY_OPERATOR_URL` 提供包地址由 `project_init` 上架。
   地址为空即 verify-only（要求平台已预上架）。
3. **Registry pull 凭据**。`REGISTRY_PULL_SECRET_NAME`（默认 `global-registry-auth`）。

### 为什么这些文档值得自动化

Registry 是**平台内置能力**且**长期演进**，文档里的命令、CR 字段、期望结果会随版本变。
手工验证一次的成本是「申请环境 + 逐条执行 + 核对期望」，而最容易出问题的地方恰好是
**不会报错、只会给出错误结果**的那类：

- `managementState` 无默认值 → 未设置时 `Config/cluster` 报 `Available=True (Removed)`，
  文档 § Check Operator and Registry Status 期望的组件根本不存在
- 权限检查用 `kubectl auth can-i` 对 `registry/metrics` 恒返回 `no`
  （该资源不在 API discovery 里），即使 RBAC 正确
- `ac get images` 在 legacy / modern 两种模式下输出列不同，
  文档里的 awk 按列位置取值，模式没切对会**静默产出垃圾**

### 环境能力开关

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `ENABLE_REGISTRY_EXPOSING` | `true` | 置 `false` 则 Case 5 以 `[env]` 跳过（无 LoadBalancer / Ingress 能力的环境） |
| `REGISTRY_UPGRADE_PACKAGE_URL` | 空 | 空则 Case 6 以 `[env]` 跳过（目录源中无更新版本） |
| `REGISTRY_PULL_SECRET_NAME` | `global-registry-auth` | 组件工作负载用的平台 registry pull Secret |
| `PKG_REGISTRY_OPERATOR_URL` | 空 | 空即 verify-only，要求平台已预上架 Operator 包 |

### 暂不纳入

- **S3 / Swift / GCS / IBM COS / Azure 存储后端**：需要对应云存储与凭据，
  dailybuild 环境不具备。环境支持后可加为带存储标签的独立 Case。
- **`ImageSignature` 签名与校验**：需要签名工具链。
- **从 OperatorHub Web UI 安装**：需要 console，且属人工路径。
