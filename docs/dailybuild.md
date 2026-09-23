# 在 lynx / dailybuild 中运行

镜像 `build-harbor.alauda.cn/asm/docs-runme-tests:<tag>`，入口 `command: docs-test`，参数 `args: [init|mesh|otel|tracing]`。

## 变量映射

| lynx 内置变量 | 映射到框架变量 | 备注 |
| --- | --- | --- |
| `$API_URL` | `PLATFORM_ADDRESS` | |
| `$USERNAME` / `$PASSWORD` | `PLATFORM_USERNAME` / `PLATFORM_PASSWORD` | |
| `$REGION_NAME` | `SINGLE_CLUSTER_NAME` | 被测集群 |
| `$GLOBAL_EXTERNAL_IPPOOL` | `METALLB_EXTERNAL_ADDRESSES_JSON` | 按 region 取值，`init` 用它建地址池 |
| `TEST_RESULT_DIR` | 报告根目录 | 未注入时缺省 `/app/report` |
| `CASE_TYPE` | Case / DocTest 过滤表达式 | 仅支持 `and` / `not` 合取式 |
| `$TOKEN` | **忽略** | lynx 不替换它，框架用账号密码经 dex 换 token |

模板里需写死：`EAST_CLUSTER_NAME`、`WEST_CLUSTER_NAME`、`GLOBAL_CLUSTER_NAME=global`、`ENABLE_METALLB`、`USE_MESH_V2_TEST_SUITE_PLUGIN=true`、`IS_DUAL_STACK`、`TRACING_ACP_ES_CLUSTER`、`ACP_KUBECONFIG_MODE=direct`、`AUTO_GEN_BOOKINFO_TRAFFIC=true`、`ENABLE_GW_LINUX_KERNEL_COMPAT=false`、`RESOURCE_PREFIX`。

所有 `PKG_*_URL` **不设置**——插件包由 lynx 依据 Release YAML 预上架，框架走 verify-only。

两个可选开关默认 `false`，置 `true` 不需要模板再配任何东西（它们用的账号密码本就是框架必需项）：`KIALI_VERIFY_MONITORING`（mesh Case 3/5/6/7 额外验证 Kiali 监控可用；Case 6/7 走 `sample` 命名空间的 `sleep` → `helloworld` 流量）、`TRACING_VERIFY_TRACE_QUERY`（tracing 安装测试额外验证调用链可查）。

报告产物：`$TEST_RESULT_DIR/allure-result/` 与 `allure-report/`。用例粒度为一篇文档的一次执行（DocTest），Case 作为 allure suite 分组。

## Case 标签与 CASE_TYPE

`CASE_TYPE` 只支持 `and` 连接的合取式与 `not` 取反，**`or` 与括号会报错退出**（见 `lynx/case-filter.sh`）。保留标签 `always` 恒被选中，用于环境初始化这类必须先跑的前置 Case。`CASE_TYPE` 未设置时全部选中——本地手工跑行为不变。

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
| otel | 2 Java 自动注入示例 | `smoke install java` |
| otel | 3 Java 自动注入 + 调用链 | `install java opensearch` |
| tracing | 1 环境初始化 | `smoke install` |
| tracing | 2 安装与卸载（ES） | `install elasticsearch` |
| tracing | 3 安装与卸载（OpenSearch） | `install opensearch` |
| tracing | 4 SPM 多副本（ES） | `ha elasticsearch` |
| tracing | 5 SPM 多副本（OpenSearch） | `ha opensearch` |
| tracing | 6 v2.0→v2.1 升级（ES） | `upgrade elasticsearch` |
| tracing | 7 v2.0→v2.1 升级（OpenSearch） | `upgrade opensearch` |

DocTest 级标签有两个：`egress`（mesh Case 3/5 的三篇 `routing-egress-traffic-*`）、`opensearch`（mesh Case 3/5 中调用链平台的装 / 卸两步）。

## dailybuild 现有测试项

| 测试项 | order | CASE_TYPE |
| --- | --- | --- |
| `docs-mesh` | 0 | 全否定式（见下） |
| `docs-otel` | 1 | 同上，三项逐字节相同 |
| `docs-tracing` | 2 | 同上，三项逐字节相同 |
| `docs-mesh-multicluster` | 3 | `multicluster and not egress` |

前三项是「除环境不支持的以外全选」：

```
not dualstack and not egress and not elasticsearch and not opensearch and not multicluster
```

多集群必须单开一项：表达式不支持 `or`，且 Case 6/7 会把 kubeconfig 切成双集群、在第二个集群上装网格，混进前三项会互相干扰。

实际选中：mesh Case 1/3/4/5/8/9/10/11、otel Case 1/2、tracing Case 1；多集群项另跑 mesh Case 6/7。

## 五个排除项的理由与恢复动作

| 排除项 | 为什么 | 环境具备后怎么做 |
| --- | --- | --- |
| `not dualstack` | 集群只有 ipv4 | 删掉该条 |
| `not egress` | 不通外网 | 删掉该条 |
| `not elasticsearch` | 天翼云 openSUSE MicroOS 根文件系统不可变只读，装不了 hostPath 方式的本地 ES 存储，`asm-1` 已去掉 `log_storage` 声明 | 给 `asm-1` 补回 `log_storage`，再删掉该条 |
| `not opensearch` | TopoLVM 要求业务集群各节点有空闲裸盘，`asm-1` / `asm-2` 的 `data_disks` 为空 | 给两个集群挂上数据盘，再删掉该条 |
| `not multicluster` | **不是环境限制**，是为了把 Case 6/7 留给 `docs-mesh-multicluster` 单跑 | 保持不动 |

`opensearch` 是 Case 级与 DocTest 级共用的同一个标签（otel Case 3、tracing Case 3/5/7，以及 mesh Case 3/5 里调用链平台的装 / 卸两步），删掉 `and not opensearch` 时四处一并放开，脚本不用改。

因此 `docs-tracing` 当前只会选中 tracing Case 1（环境初始化）——它不碰任何存储后端，是该测试项唯一跑得起来的 Case，没有它一个用例都不会跑。

otel Case 2（Java 自动注入示例）不碰存储后端：它自己装一遍 Operator + Collector，只验「Operator 自动注入 Java agent」，因此照常进 dailybuild；需要调用链平台的完整上报链路拆在 otel Case 3。

tracing Case 6/7（升级）除 `upgrade` 外还各带一个存储标签，四个测试项都选不中——这是有意的：升级测试要求环境上先有一套 v2.0 部署，dailybuild 的环境是全新安装出来的 v2.1，跑了也只会 SKIPPED。将来要纳入，得按多集群那样单开一个 `CASE_TYPE="upgrade"` 的测试项，并让该测试项的环境停在 v2.0。

## 与 CASE_TYPE 无关的环境跳过

`ENABLE_METALLB=false` 时，mesh Case 3/5 的三篇 `exposing-*` 与 Case 6/7 多集群由编排脚本直接跳过（没有 LoadBalancer 地址跑必失败）。天翼云 MicroOS 支持 `other_vips`，dailybuild 的 `asm-1` / `asm-2` 各有 1 个 ipv4 VIP，四个测试项均已置 `true`，这两处正常执行。

> 环境能力（有没有 LoadBalancer、是不是双栈）不要用标签表达——`CASE_TYPE` 表达的是「这轮想测什么」，环境变量表达的是「这套环境能测什么」，混在一起会让「环境没配好」混进「本来就不测」。

新增或修改标签时要同步 release-config 的 `CASE_TYPE`，见 [maintenance.md](maintenance.md#14-需要新标签时同步-release-config)。
