# 文档测试接入 dailybuild / lynx 设计

- 状态：待评审
- 日期：2026-08-20
- 涉及仓库：`docs-runme-tests`（主）、`servicemesh2-docs`、`opentelemetry-docs`、`distributed-tracing-docs`、`apt-test/release-config`

## 1. 背景与目标

`docs-runme-tests` 目前是一套手工执行的 Bash + runme 文档测试框架：开发者在本机 `export` 一批环境变量后跑 `./run-mesh-all.sh` 等编排脚本，结果打印在终端并落到 `tmp/runs/<run-id>/`。

现在要让同一套测试同时具备两种运行形态：

1. **本地手工运行**（现状，不能退化）；
2. **在 dailybuild 中由 lynx 调度运行**——以容器镜像形态交付，提供镜像地址、环境变量、执行参数，产出 lynx 可解析的 allure 报告。

目标是：**一套代码、一套编排、两种入口**，不产生并行维护的第二份实现。

## 2. 非目标

- 不重写测试脚本，不改变 `runme-test_*.sh` 的编写方式与 `{name=}` 代码块约定。
- 不引入 pytest / ares，不把 Bash 框架迁到 Python。
- 不在本期支持 OpenSearch 存储后端进 dailybuild（保留扩展位，见 §5.2.3）。
- 不做 UI 测试（`category` 固定为 `api`）。

## 3. 既定决策

来自与需求方的确认，作为设计前提：

| 编号 | 决策 |
| --- | --- |
| D1 | lynx 中按项目拆 **3 个测试项**：`docs-mesh` / `docs-otel` / `docs-tracing`，用 `order` 串行 |
| D2 | 镜像由 **Tekton PaC** 构建并推到 **build-harbor.alauda.cn 的 ASM 命名空间** |
| D3 | 三个文档仓库在**构建时按 ref clone** 进镜像 |
| D4 | tag 规则：`main` → `latest`，`release-mesh-2.x` → `<branch>-<短 commit>` |
| D5 | 首批范围：otel 全部 + tracing Elasticsearch 链 + mesh Case 1/3/5；升级类与多集群类稳定后再放开 |
| D6 | Elasticsearch 由 **EnvironmentTemplate 的 `log_storage`** 部署在业务集群 1，框架只读 `Feature` CR |
| D7 | 插件包全部由 **dailybuild 预上架**，框架侧改为「只校验不下载不上架」 |
| D8 | mesh 文档引用的外部 sample YAML **构建时预置进镜像** |
| D9 | allure 用例粒度 = **DocTest**（一篇文档的一次 `./run.sh --file`） |
| D10 | `case_id` 用**仓库内自定义编号**，清单文件维护 + CI 查重 |
| D11 | release-config 的模板改动由本项目产出完整 MR |
| D12 | 双栈判断靠模板里写死 `IS_DUAL_STACK`，MicroOS 基准场景为 `false` |
| D13 | 业务集群 1：3 节点、`master_as_node`、16C/32G/300G；业务集群 2：3 节点、`master_as_node`、8C/16G/100G |
| D14 | `other_vips` 若在天翼云 MicroOS 上不可用，接受降级（关闭 MetalLB 相关测试） |

## 4. 总体架构

```
                      ┌──────────────────────────────────────────┐
   lynx TestTemplate  │ initials: asm-init-c1 → asm-init-c2       │
                      │ tests:    docs-mesh → docs-otel →        │
                      │           docs-tracing                    │
                      └───────────────┬──────────────────────────┘
                                      │ 每项一个独立容器
                                      ▼
        ┌───────────────────────────────────────────────────────────┐
        │  build-harbor.alauda.cn/asm/docs-runme-tests:<tag>         │
        │                                                            │
        │  lynx/entrypoint.sh   ← 唯一 ENTRYPOINT (command: docs-test)│
        │      ├─ env-adapter.sh   lynx 变量 → 框架变量               │
        │      ├─ case-filter.sh   CASE_TYPE → Case/DocTest 过滤      │
        │      └─ 调用 run-<project>-all.sh 或 run.sh --init-only     │
        │                            │                               │
        │  framework/report.sh ──────┴──► results.jsonl              │
        │      ├─ summary.json / junit.xml   （现状，保留）           │
        │      └─ allure 后端（新增）→ $TEST_RESULT_DIR/allure-*      │
        └───────────────────────────────────────────────────────────┘
```

框架内核（`run.sh` / `framework/` / `projects/` / `runme-test_*.sh`）**不感知 lynx**。所有 lynx 相关知识集中在 `lynx/` 目录与 `report.sh` 的一个新输出后端里。

## 5. 组件设计

### 5.1 镜像

#### 5.1.1 目录结构

```
/app
├── docs-runme-tests/            本仓库（构建上下文）
│   ├── run.sh  run-*-all.sh  framework/  projects/  charts/
│   ├── lynx/
│   │   ├── entrypoint.sh        镜像入口
│   │   ├── env-adapter.sh       lynx 内置变量 → 框架变量
│   │   ├── case-filter.sh       CASE_TYPE 表达式求值
│   │   ├── allure.sh            results.jsonl → allure-result（被 report.sh 调用）
│   │   ├── case-ids.tsv         case_id 清单（project / doc / case_id）
│   │   ├── assets-manifest.tsv  离线资产清单（url / 本地相对路径）
│   │   └── check-manifest.sh    CI 校验：文档里的 URL 是否都在清单中
│   └── assets/                  构建期下载的 sample YAML（.gitignore）
├── servicemesh2-docs/           构建时 git clone --depth 1 --branch $MESH_DOCS_REF
├── opentelemetry-docs/          同上，$OTEL_DOCS_REF
└── distributed-tracing-docs/    同上，$TRACING_DOCS_REF
```

`repos.conf` 的相对路径（`../servicemesh2-docs`）在此布局下天然成立，无需改动。

#### 5.1.2 基础镜像与内置工具

基础镜像 `ubuntu:22.04`。不复用 `automation/ares:base-api-latest`——那是 python/pytest 栈，我们一行 Python 都不跑，却会把镜像撑到 1G 以上。

构建期安装：`kubectl`、`curl`、`jq`、`openssl`、`git`、`ca-certificates`、`tzdata`、`default-jre-headless`、allure CLI 2.24.1（与 ares 基础镜像同版本）。

构建期预置到 `/app/docs-runme-tests/bin/`：`runme`（版本 = `RUNME_VERSION` 构建参数）、`violet`、`istioctl`。三者的 `_install_tool` 已有「已存在且版本匹配就跳过」逻辑，运行时会直接命中，**无需改代码**。

构建参数与 label：

| ARG | 默认 | 写入 label |
| --- | --- | --- |
| `MESH_DOCS_REF` | `master` | `io.alauda.docs.mesh-ref` |
| `OTEL_DOCS_REF` | `main` | `io.alauda.docs.otel-ref` |
| `TRACING_DOCS_REF` | `main` | `io.alauda.docs.tracing-ref` |
| `RUNME_VERSION` | `3.16.11` | `io.alauda.runme-version` |

`ENTRYPOINT ["/app/docs-runme-tests/lynx/entrypoint.sh"]`，并在 `/usr/local/bin/docs-test` 放一个指向它的软链，使 lynx 的 `command: docs-test` 可用。

#### 5.1.3 构建流水线

新增 `.tekton/image-build.yaml`（PaC），触发条件对齐文档仓库现有写法：push 到 `main` 或 `release-*` 分支。镜像仓库 `build-harbor.alauda.cn/asm/docs-runme-tests`（ASM 自有命名空间；若实际命名空间不是 `asm`，只需改流水线的 `IMAGE_REPO` 参数与 TestTemplate 里的 `image` 字段）。tag 规则：

| 分支 | tag |
| --- | --- |
| `main` | `latest` + `main-<短 commit>` |
| `release-mesh-2.x` | `<branch>-<短 commit>` |

mesh 版本与 ACP 版本的对应关系维护在 `UPDATE-README.md` 的发版版本矩阵中；该表用于发版配置与插件上架，不参与镜像 tag 计算。

### 5.2 lynx 适配层

#### 5.2.1 入口契约

```
command: docs-test
args:   [ init | mesh | otel | tracing ]
```

- `init` → `./run.sh --project mesh --init-only --cluster $REGION_NAME`，并额外建 MetalLB 地址池（§5.6）。用于 lynx `initials`，每个业务集群一次。

  这里固定用 `--project mesh` 是因为 mesh 的 `project_init` 覆盖面最大：拉 kubeconfig（含 Global）、装集群插件（multus / metallb / mesh-v2-test-suite）、装 `servicemesh-operator2`。otel 与 tracing 所需的 `opentelemetry-operator2`、Jaeger v2 集群插件由各自编排脚本内的 `--force-init` 与安装测试步骤负责，不放进 `init`——它们在每个 Case 里会被卸载重装，放前置没有意义。
- `mesh` / `otel` / `tracing` → 对应的 `./run-<project>-all.sh`。

#### 5.2.2 环境变量映射

`env-adapter.sh` 在调用编排脚本前完成映射。**lynx 自动替换的内置变量**：

| lynx 变量 | 框架变量 | 说明 |
| --- | --- | --- |
| `$API_URL` | `PLATFORM_ADDRESS` | |
| `$USERNAME` | `PLATFORM_USERNAME` | |
| `$PASSWORD` | `PLATFORM_PASSWORD` | |
| `$REGION_NAME` | `SINGLE_CLUSTER_NAME` | 被测集群 |
| `$GLOBAL_EXTERNAL_IPPOOL` | → `METALLB_EXTERNAL_ADDRESSES_JSON` | 逗号分隔 IP 列表，按当前 region 取值；适配层补 `/32` 并包成 `[{"cluster":"$REGION_NAME","ipv4Addresses":[...]}]` |
| `TEST_RESULT_DIR` | 报告根目录 | lynx 注入；未注入时默认 `/app/report` |
| `CASE_TYPE` | Case / DocTest 过滤表达式 | |
| `RESOURCE_PREFIX` | 记录进 allure `environment.properties` | 实际无法生效，见 §8.1 |
| `$TOKEN` | **忽略** | lynx 不做替换（virt-readiness 实测记录），走账号密码经 dex 换 token，即现有 `framework/acp-auth.sh` |

**在 TestTemplate 里写死的自定义变量**：

| 变量 | 值 | 说明 |
| --- | --- | --- |
| `DOC_PROJECT` | `mesh` / `otel` / `tracing` | 与 `args` 冗余，供日志与报告标注 |
| `GLOBAL_CLUSTER_NAME` | `global` | |
| `EAST_CLUSTER_NAME` | 业务集群 1 名 | mesh 多集群用 |
| `WEST_CLUSTER_NAME` | 业务集群 2 名 | mesh 多集群用 |
| `ENABLE_METALLB` | `true`（降级时 `false`） | |
| `USE_MESH_V2_TEST_SUITE_PLUGIN` | `true` | 离线环境必需 |
| `IS_DUAL_STACK` | `false` | D12 |
| `TRACING_ACP_ES_CLUSTER` | 业务集群 1 名 | D6 |
| `ACP_KUBECONFIG_MODE` | `direct` | 多集群网格必须 |
| `AUTO_GEN_BOOKINFO_TRAFFIC` | `true` | |
| `ENABLE_GW_LINUX_KERNEL_COMPAT` | `false` | MicroOS 内核 ≥ 4.11 |
| `EXIT_ON_TEST_FAILURE` | `false` | 见 §7.3 |

`RUNME_VERSION` 由镜像 label 反填，不需要模板提供。

所有 `PKG_*_URL` **不设置**——触发 §5.4 的 verify-only 模式。

#### 5.2.3 CASE_TYPE 与标签

`case_begin` 增加第三个参数 `tags`（空格分隔）：

```bash
case_begin "3" "单网格安装与应用测试" "smoke install sidecar"
```

`case-filter.sh` 提供两个判定函数：

- `case_selected <tags...>` —— 供编排脚本决定是否执行某 Case；不执行时调用 `case_skip` 并把 skip 原因标为「预期不测试」。
- `doctest_selected <tags...>` —— 供编排脚本在 Case 内部跳过个别 DocTest（目前只用于 egress 三篇）。

**表达式语法**：只支持 `and` 连接的合取式与 `not` 取反，例如 `smoke and not egress`、`update and not multicluster`。不支持 `or` 与括号——需要并集时多开一个 lynx 测试项。这是 ares `-m` 语义的子集，足以覆盖既有用法（`prepare and not l5`、`not disturb`）。`CASE_TYPE` 未设置时全部选中，保证本地手工跑行为不变。

**保留标签 `always`**：带该标签的 Case 恒被选中，不参与表达式求值。用于环境初始化这类「任何子集都必须先跑」的前置 Case，使 §11 中「把 mesh 拆成两个测试项」的降级预案不会把初始化 Case 漏掉。

**标签分配**：

| 项目 | Case | 标签 |
| --- | --- | --- |
| mesh | 1 环境初始化 | `always install` |
| mesh | 2 双栈网格安装 | `dualstack install` |
| mesh | 3 单网格安装与应用（含调用链） | `smoke install sidecar` |
| mesh | 4 Istio HA 配置 | `ha install` |
| mesh | 5 Ambient Mode 安装 | `smoke install ambient` |
| mesh | 6 多集群-多主多网络 | `multicluster` |
| mesh | 7 多集群-主远多网络 | `multicluster` |
| mesh | 8 InPlace 更新 | `update` |
| mesh | 9 RevisionBased 更新 | `update` |
| mesh | 10 RevisionBased + Tag 更新 | `update` |
| mesh | 11 Ambient 更新 | `update ambient` |
| otel | 1 OpenTelemetry 安装与卸载 | `smoke install` |
| otel | 2 Java 自动注入示例 | `smoke install java` |
| tracing | 1 调用链安装与卸载（ES） | `smoke install elasticsearch` |
| tracing | 2 调用链安装与卸载（OpenSearch） | `install opensearch` |
| tracing | 3 SPM 多副本（ES） | `smoke ha elasticsearch` |
| tracing | 4 SPM 多副本（OpenSearch） | `ha opensearch` |

DocTest 级标签只有一个：mesh Case 3 / Case 5 中的三篇 `routing-egress-traffic-*` 标 `egress`。

**首批 CASE_TYPE**：三个测试项统一用 `smoke and not egress`。

**扩展位**：OpenSearch 就绪后，给 tracing Case 2/4 补 `smoke` 标签即可纳入，`CASE_TYPE` 不用动；升级类放开时改成 `smoke and not egress` → 增加一个 `update` 测试项或改为 `not egress and not dualstack and not multicluster`。

### 5.3 报告：allure 后端

数据源仍是唯一的 `results.jsonl`，不新增采集路径。`report_finalize` 在写完 `summary.json` / `junit.xml` 后，**当且仅当 `TEST_RESULT_DIR` 非空**时额外产出 allure。该变量只由 `lynx/entrypoint.sh` 设置（lynx 未注入时默认 `/app/report`），因此本地直接跑 `./run.sh` / `./run-*-all.sh` 不会触发 allure 生成，也就不需要本机装 allure CLI 与 JRE——现状完全不变。

```
$TEST_RESULT_DIR/
├── allure-result/
│   ├── <uuid>-result.json         每个 DocTest 一条
│   ├── environment.properties
│   └── categories.json
└── allure-report/                 allure generate --clean 产出
```

**用例字段映射**（`type=doctest` 的每一行 → 一个 allure result）：

| allure 字段 | 来源 |
| --- | --- |
| `uuid` | `cat /proc/sys/kernel/random/uuid` |
| `name` | `file`（文档名） |
| `fullName` | `<project>/<file>` |
| `status` | `passed` / `failed` / `skipped` |
| `statusDetails.message` | `fail_reason` 或 `skip_reason` |
| `start` / `stop` | `start_ts * 1000` / `end_ts * 1000` |
| `labels[suite]` | `Case <case_id>: <case_name>` |
| `labels[feature]` | `project` |
| `labels[tag]` | Case 标签（逐个） |
| `labels[case_id]` | 查 `lynx/case-ids.tsv` |
| `labels[severity]` | 固定 `normal` |

`environment.properties` 写入：平台地址、被测集群、镜像 tag、三个文档仓库的 ref、`CASE_TYPE`、`RESOURCE_PREFIX`。**不写入密码 / token**（规范第 9 条）。

`categories.json` 定义两类，用于把「环境不支持」的跳过与真实缺陷区分开：

- `预期不测试` —— matchedStatuses `skipped`，messageRegex 匹配 `^\[expected\]`；
- `环境不支持` —— matchedStatuses `skipped`，messageRegex 匹配 `^\[env\]`；
- 其余 failed 归入默认的 `Product defects`。

实现放在 `lynx/allure.sh`，由 `framework/report.sh` 在存在该文件时 source 并调用；文件不存在（例如有人只 clone 了框架）时静默跳过，保证 `report.sh` 单测不依赖 lynx 层。

### 5.4 插件包 verify-only 模式

引入按包判定的模式：某个 `PKG_*_URL` 为空即该包走 verify-only。

| 函数 | `auto`（有 URL，现状） | `verify-only`（无 URL，新增） |
| --- | --- | --- |
| `install_operator` | `parse_csv_name_from_package $url` 推 CSV 名 → download → violet push → 建 Subscription | CSV 名改从 PackageManifest 反查——复用已有的 `<runme_prefix>:check-packagemanifest-versions` 块，取该 operator 最新可用版本；跳过 download / push |
| `install_cluster_plugin` | 按 URL 解析版本 → download → push → 等 ModuleConfig → 建 ModuleInfo | 版本改取该插件已上架 ModuleConfig 的最新版本；跳过 download / push |
| `install_operator_cli` | 同 `install_operator` | 同上 |

签名改动：`install_operator` 与 `install_cluster_plugin` 的 `package_url` 参数允许为空字符串，函数内部据此分流。调用方（`projects/*/project.sh`）不需要改结构，只是传进去的变量可能为空。

`project_check_env` 中所有 `PKG_*_URL` 从「必需」降为「可选」。缺包时的报错必须指向正确的处置动作，例如：

```
插件 servicemesh-operator2 未上架到集群 dailybuild-mircos-g1-asm-1，
且未提供 PKG_SERVICEMESH_OPERATOR2_URL。
- dailybuild：确认 release-config 的 Release YAML 已在 l5_plugin_packages 声明该包并指定该集群
- 本地：export PKG_SERVICEMESH_OPERATOR2_URL=<包地址>
```

好处：本地跑（给 URL）与 dailybuild（不给 URL）共用同一份代码路径，没有 `if IN_LYNX` 之类的分支。

### 5.5 离线资产

`lynx/assets-manifest.tsv` 两列：`url` 与镜像内相对路径。当前需要预置 **17 个去重后的 URL**（bookinfo / bookinfo-versions / bookinfo-gateway ×2 / sleep ×2 / curl / httpbin / helloworld / tcp-echo ×3 / east-west-gateway ×2 / expose-istiod / expose-services / ingress-gateway），对应 `servicemesh2-docs` 中 **42 处调用点**。

已核实：`opentelemetry-docs` 与 `distributed-tracing-docs` 的代码块**没有任何拉取外部文件的命令**（仅有指向集群内 `localhost` / Service 的 `curl`），因此这两个仓库不需要改造。

- **构建期**：Dockerfile 按清单 `curl` 落盘到 `/app/docs-runme-tests/assets/`。任一 URL 下载失败即构建失败——不允许产出「缺资产的镜像」。
- **运行期**：新增 `framework/assets.sh`，提供 `fetch_url_content <url>`：命中清单则 `cat` 本地文件，否则回退 `curl`（保留本地开发的联网路径）。
- **改造点 1**：`projects/mesh/project.sh` 的 `kubectl_apply_with_mirror` 内部 `curl -fsSL "$url"` → `fetch_url_content "$url"`。
- **改造点 2**：新增 `runme_run_with_assets <block>`，用于那些直接 `runme run` 执行 `kubectl apply -f <url>` 的块（`dual-stack:*` 等）：`runme print` 取内容 → 把命中清单的 URL 替换成本地路径 → `eval`。逐个替换现有调用点。
- **改造点 3**：`lynx/check-manifest.sh` 扫描三个文档仓库所有 `{name=}` 代码块中的 `http(s)://` URL，与清单比对，缺失即失败。挂到镜像构建流水线，防止文档改了 URL 而镜像没跟上。

### 5.6 MetalLB 地址池所有权模型

现状：`setup_external_ip_pools` / `teardown_external_ip_pools` 由**单篇测试脚本**调用（`exposing-*` 三篇与 `deploying-the-bookinfo-application`），地址来自 `METALLB_EXTERNAL_ADDRESSES_JSON`。而 lynx 的 `$GLOBAL_EXTERNAL_IPPOOL` 只给当前 `region_name` 的 IP，一个 mesh 测试项拿不到第二个集群的 IP。

引入所有权标签解决：

- `_render_external_ip_pool` 增加 label `runme-test/owner`，取值 `init` 或 `doctest`。
- `init` 入口（lynx `initials`，每集群一次）用该集群自己的 `$GLOBAL_EXTERNAL_IPPOOL` 创建池，打 `owner=init`。
- `setup_external_ip_pools` 增加前置分支：若目标集群已存在同名 `IPAddressPool` 且状态可用，**直接复用并返回**，不再要求 `METALLB_EXTERNAL_ADDRESSES_JSON`。只有池不存在时才走「读 JSON → 创建」的现有路径。
- `teardown_external_ip_pools` 跳过 `owner=init` 的池，只清理自己创建的 `owner=doctest` 池。

结果：本地手工跑（无 init 建池 → 读 JSON 创建 → 用完删除）行为完全不变；dailybuild 里两个集群的池由各自的 `initials` 建好并长期存在，三个测试项复用。

### 5.7 skip 二分类

规范第 8 条要求区分「环境不支持」与「预期不测试」，且前者按成功处理。

- 新增 `skip_test_env "原因"` —— 环境 / 版本 / 依赖不具备。写入 `results.jsonl` 时 `skip_reason` 前缀 `[env]`。
- 新增 `skip_test_expected "原因"` —— 测试选择明确不执行（`CASE_TYPE` 未选中、`IS_DUAL_STACK=false`、egress 排除等）。前缀 `[expected]`。
- 现有 `skip_test` 保留为 `skip_test_expected` 的别名，逐篇迁移到语义正确的那个。
- `case_skip` 增加可选的分类参数，默认 `[expected]`。

两类都不计失败；分类只体现在 allure 的 categories 与终端摘要里。

## 6. lynx 侧配置（release-config）

基准文件：`enviroments/4.5.0/dailybuild/dailybuild_mircos_g1.yaml` 与 `tests/4.5.0/dailybuild/dailybuild_mircos_g1.yaml`（`db-mos-g1`）。按 Confluence 的同步规则，只改 MicroOS 场景，其他场景按需同步。

### 6.1 EnvironmentTemplate 增量

新增两个 region，OS / provider / 网络 / 网卡 / VLAN / SSH / LB / registry / 监控实现**深复制自同文件已有业务集群**（Confluence 的「基准 2：目标场景基础设施基准」），只覆盖下列允许项：

| region | 节点 | 规格 | 覆盖项 |
| --- | --- | --- | --- |
| `dailybuild-mircos-g1-asm-1` | 3 × master | 16C / 32G / **300G** | `master_as_node: true`、`log_storage: {component: es, scale: single}`、`other_vips: {ip_type: ipv4, number: 1}`、`monitor_scale: Small` |
| `dailybuild-mircos-g1-asm-2` | 3 × master | 8C / 16G / 100G | `master_as_node: true`、`other_vips: {ip_type: ipv4, number: 1}`、`monitor_scale: Small` |

说明：

- asm-1 的 300G 系统盘是 `log_storage` 的硬要求（lynx 基线：业务集群部署 log_storage 时系统盘扩到 300G）。
- asm-2 用 8C/16G 而非 `master_as_node` 基线的 16C/32G，是有意为之：它只承载 istiod、东西向网关与 helloworld/sleep，负载很轻。若实测吃紧再上调，属于单字段改动。
- 两个 region 在同一 VLAN，`other_vips` 各申请 1 个 IPv4 地址，分别作为该集群 MetalLB 的地址池。

### 6.2 TestTemplate 增量

```yaml
initials:
  - name: asm-init-c1
    image: build-harbor.alauda.cn/asm/docs-runme-tests:<tag>
    region_name: dailybuild-mircos-g1-asm-1
    command: docs-test
    args: [init]
    continue_on_error: false
    timeout: 1
    envs: [ API_URL, USERNAME, PASSWORD, REGION_NAME,
            GLOBAL_EXTERNAL_IPPOOL, GLOBAL_CLUSTER_NAME,
            ENABLE_METALLB, USE_MESH_V2_TEST_SUITE_PLUGIN ]
  - name: asm-init-c2
    region_name: dailybuild-mircos-g1-asm-2
    run_after: [asm-init-c1]
    # 其余同上

tests:
  - name: docs-mesh
    order: 0   priority: 190   timeout: 6
    region_name: dailybuild-mircos-g1-asm-1
  - name: docs-otel
    order: 1   priority: 190   timeout: 2
    region_name: dailybuild-mircos-g1-asm-1
  - name: docs-tracing
    order: 2   priority: 190   timeout: 2
    region_name: dailybuild-mircos-g1-asm-1
```

- 三项 `category: api`、`team: containerplatform`、`order` 递增串行——共享 asm-1，并行会争抢 OTel Operator 与 `jaeger-system` 命名空间。
- 每项的 `envs` 必须完整重复声明（lynx 只传该步骤自己声明过的变量）。
- `initials` 用 `run_after` 显式串联；不写 `run_after` 的 initials 是并发执行的。
- `timeout` 单位是小时。mesh 首批只跑 Case 1/3/5，6 小时留足余量；放开升级与多集群后需要重估。

### 6.3 Release YAML 增量

`releases/4.5.0/4-5-0-s9.yaml` 的 `db-mos-g1` scene 追加 `release.initial.l5_plugin_packages`，`clusters` 指向两个 ASM 集群：

`servicemesh-operator2`、`kiali-operator`、`opentelemetry-operator2`、`jaeger`（Alauda Build of Jaeger v2 集群插件）、`mesh-v2-test-suite`。

`multus`、`metallb`、`metallb-operator` 按其插件层级走 `plugin_packages` 或环境自带。

所有包必须能在 `https://package-minio-ctyun.alauda.cn:9002/` 下载。当前 rc/beta 包尚未同步到天翼云，需求方将提供**正式版本**的包（见 §10）。

## 7. 数据流与错误处理

### 7.1 一次 dailybuild 运行

```
lynx 部署环境（含 asm-1 的 ES）
  → 上架 L5 插件包到 asm-1 / asm-2
  → initials: asm-init-c1  建地址池 + 装 multus/metallb/mesh-v2-test-suite + 装 operator
  → initials: asm-init-c2  同上（第二集群）
  → tests: docs-mesh     → results.jsonl → allure-result → allure-report
  → tests: docs-otel     → 同上（独立容器、独立 TEST_RESULT_DIR）
  → tests: docs-tracing  → 同上
  → lynx 解析 allure 汇总，ReleaseTestPlan → TestFinished
```

### 7.2 失败语义

| 层级 | 失败行为 |
| --- | --- |
| lynx `initials`（`continue_on_error: false`） | 中止后续步骤——环境没准备好，跑测试只会得到一堆指向错误方向的红 |
| 编排 Case 1（致命前置） | `case_end_fatal` → finalize 并退出，本测试项其余 Case 不跑 |
| 普通 Case | `case_end` 记录失败，继续下一个 Case（规范第 7 条） |
| Case 内单个 DocTest | 子 shell `set -e` 中断该 Case 剩余步骤；其他 Case 不受影响 |

### 7.3 退出码

对齐 ares 的做法（普通 case 失败不改变进程退出码）：引入 `EXIT_ON_TEST_FAILURE`，由 `report_finalize` 在决定返回码时读取，`lynx/entrypoint.sh` 再据此决定容器退出码。

- 本地默认 `true` —— 保持现状，失败即非 0，方便 shell 与 CI 判断。
- lynx 模板里设为 `false` —— 用例失败不让容器非 0 退出，结果完全由 allure 报告承载，避免 lynx 把「测试有失败」误判成「测试任务 Error」。
- 无论开关如何，**框架级失败**（环境变量缺失、kubeconfig 拉取失败、allure 生成失败）一律非 0 退出。

### 7.4 报告缺失的防御

lynx 的已知故障模式是「测试任务被杀 → 留下空的 allure 报告 → summaryResult 变 NUL」。因此 `entrypoint.sh` 用 `trap ... EXIT` 保证：即使编排脚本异常中断，也会用已有的 `results.jsonl` 生成一份 allure 报告；`results.jsonl` 本身为空时，写一条 `broken` 状态的占位用例说明中断原因，而不是留下空目录。

## 8. 规范符合性与偏离

### 8.1 明确的偏离（需同步给发版团队）

| 规范条目 | 偏离 | 理由 |
| --- | --- | --- |
| 第 4 条：资源使用唯一前缀 `e2e-<4 位随机>` | **`RESOURCE_PREFIX` 无法生效** | 文档测试用的是文档里写死的命名空间与资源名（`bookinfo` / `istio-system` / `curl` / `jaeger-system`…）。加前缀就不是在测文档了。隔离改由「ASM 专用集群 + 每个 Case 自带 cleanup」保证 |
| 第 5 条：`WORKER_NUM` | **恒为 1** | 编排是有状态串行链（装网格 → 部署应用 → 验证 → 卸载），无法并行 |

`RESOURCE_PREFIX` 仍会被接收并写进 `environment.properties`，便于排查时对应回 lynx 的测试项。

### 8.2 符合项

| 规范条目 | 落地 |
| --- | --- |
| 第 1 条 标签与 `case_id` | Case 标签（§5.2.3）+ `lynx/case-ids.tsv`（§9） |
| 第 3 条 资源必须清理 | 现有 `cleanup_*` 机制；编排以 `--no-cleanup` / `--cleanup-only` 成对使用 |
| 第 5 条 环境变量一致 | §5.2.2 映射表 |
| 第 7 条 单 case 失败不中断 | §7.2 |
| 第 8 条 skip reason 分类 | §5.7 |
| 第 9 条 报告输出到 `TEST_RESULT_DIR` | §5.3，且不输出密码 / token |
| 第 10 条 镜像与 tag | §5.1.3 |

## 9. case_id 编号规则

`lynx/case-ids.tsv`，三列：`project` / `doc`（即 `runme-test_<doc>.sh` 的 `<doc>`）/ `case_id`。

编号格式：

- mesh → `ASM-DOC-001` 起
- otel → `OTEL-DOC-001` 起
- tracing → `TRACE-DOC-001` 起

规则：编号一经分配**永不复用**；文档改名时保留原编号并更新 `doc` 列；新增文档追加最大编号 +1。CI 校验：编号唯一、格式合法、每个 `runme-test_*.sh` 都有对应条目。

## 10. 交付阶段

| 阶段 | 内容 | 可验证点 |
| --- | --- | --- |
| 1 | 框架侧：allure 后端、`lynx/` 适配层、CASE_TYPE 过滤与 Case 标签、离线资产、verify-only 插件模式、地址池所有权、skip 二分类、`case-ids.tsv` | `framework/tests/*.sh` 全绿（含新增的 allure / case-filter / verify-only 单测）；本地不设任何 `PKG_*_URL` 跑通一条完整链 |
| 2 | `Dockerfile` + `.tekton/image-build.yaml` | 镜像可拉；开发机 `docker run` 执行 `docs-test tracing` 跑通并产出可打开的 allure 报告 |
| 3 | 独立 `EnvironmentTemplate` + `ReleaseTestPlan` 天翼云自测 | idp 上一次绿色 run，allure 报告可打开，三个测试项各自出报告 |
| 4 | 合入 `release-config` 的 dailybuild MicroOS 基准（§6） | 次日 dailybuild 出报告 |
| 5 | 观察 2 周后逐步放开 `update` / `multicluster` / `ha` | 只改 `CASE_TYPE` 与 `timeout`，不改代码 |

## 11. 风险与降级预案

| 风险 | 影响 | 预案 |
| --- | --- | --- |
| 天翼云 MicroOS provider 不支持 `other_vips` | 拿不到 LoadBalancer IP | D14：`ENABLE_METALLB=false`，`exposing-*` 的 LB 断言与多集群东西向网关降级或跳过（标 `[env]`），其余照常 |
| 插件包只有 rc/beta、未同步到天翼云 minio | 装不上 operator | 需求方提供正式版本包；在此之前阶段 3 的自测用 IDC 环境 + `PKG_*_URL` 显式给包 |
| mesh 首批单轮超 6 小时 | 测试项超时被杀 | 提高 `timeout`；或把 mesh 拆成 `docs-mesh-sidecar` / `docs-mesh-ambient` 两个测试项（CASE_TYPE 分别为 `smoke and sidecar and not egress` / `smoke and ambient and not egress`），环境初始化 Case 因带 `always` 标签在两者中都会执行，架构已支持 |
| 文档改动引入新的外部 URL | 离线环境跑挂 | `check-manifest.sh` 在镜像构建时拦截；文档仓库 PR 阶段也可挂同一脚本 |
| asm-1 上 ES + 网格 + Ambient 同时跑资源不足 | 抖动 | 16C/32G × 3 已按基线上调；仍不足则把 ES 移回 global（改 `TRACING_ACP_ES_CLUSTER` 一个变量） |
| dailybuild 预上架的插件版本与文档不匹配 | 安装步骤断言失败 | verify-only 模式的报错必须打印实际找到的版本与期望版本，便于当天定位 |

## 12. 附录：受影响文件清单

**docs-runme-tests**

- 新增：`Dockerfile`、`.tekton/image-build.yaml`、`lynx/{entrypoint,env-adapter,case-filter,allure,check-manifest}.sh`、`lynx/{case-ids,assets-manifest}.tsv`、`framework/assets.sh`
- 修改：`framework/report.sh`（allure 后端）、`framework/common.sh`（`install_operator` / `install_cluster_plugin` 的 verify-only、地址池所有权、`skip_test_env` / `skip_test_expected`、`case_begin` 标签参数）、`framework/tools.sh`（verify-only 分流）、`projects/*/project.sh`（`PKG_*_URL` 可选、`fetch_url_content`）、`run-*-all.sh`（Case 标签 + `case_selected` / `doctest_selected`）、`README.md`
- 新增单测：`framework/tests/{allure_test,case_filter_test,verify_only_test}.sh`

**servicemesh2-docs**

- 修改：使用 `runme_run_with_assets` 替换直接 `runme run` 执行外部 URL 的调用点（`dual-stack` 等）。`opentelemetry-docs` 与 `distributed-tracing-docs` 无外网文件依赖，无需改动。

**apt-test/release-config**

- 修改：`enviroments/4.5.0/dailybuild/dailybuild_mircos_g1.yaml`、`tests/4.5.0/dailybuild/dailybuild_mircos_g1.yaml`、`releases/4.5.0/4-5-0-s9.yaml`
