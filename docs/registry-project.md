# registry 项目：Alauda Container Platform Registry 文档测试

## 1. 这个项目测什么

被测文档在 **`acp-docs`**：

| 路径 | 内容 |
| --- | --- |
| `docs/en/configure/registry/` | Registry 管理侧：overview / image_registry_operator / setting_up_and_configuring / exposing / managing_access_and_cleanup / index |
| `docs/en/developer/registry/` | 开发者侧：accessing_the_registry / managing_images_with_ac / index |

测试脚本 `runme-test_<doc>.sh` 与对应 `.mdx` **同仓同目录**，与框架既有约定一致。

## 2. 与 mesh / otel / tracing 的差异

| 维度 | mesh / otel / tracing | registry |
| --- | --- | --- |
| 被测对象 | 可安装的集群插件 / Operator | **平台内置能力**（`image-registry-system`） |
| Operator 包 | 平台通常已上架 | **全新 ACP 4.4 环境的 OperatorHub 里没有**，必须显式上架 |
| 卸载 | 多数用例带 cleanup | **不卸载**——Registry 是平台能力，后续 Case 都依赖它 |
| 存储依赖 | 部分用例需要 OpenSearch / TopoLite | 默认 `emptyDir`，不依赖外部存储 |

### 为什么 Operator 包必须显式上架

全新 ACP 4.4.0（`installer-core-v4.4.0-x86.tar`）装完后，三个 CatalogSource
（`custom` / `platform` / `system`）里只有 3 个 PackageManifest：
`ingress-nginx-operator`、`envoy-gateway-operator`、`metallb-operator`。

文档 § Install by Using YAML 的第一步建 `Subscription` 会被准入 webhook 拒：

```
admission webhook "check-subscription.cpaas.io" denied the request:
packagemanifests.packages.operators.coreos.com "cluster-image-registry-operator" not found
```

包在制品库：`cluster-image-registry-operator/v4.4/cluster-image-registry-operator.stable.amd64.v4.4.<N>.tgz`。
`project_init` 通过 `PKG_REGISTRY_OPERATOR_URL` 下载并上架。

## 3. 环境供给

框架默认假设 ACP 环境已存在。registry 项目额外实现了**可选**的供给机制，
用于 dailybuild 环境不可用时现场造一套。

### 3.1 用法

```bash
# 看当前状态（不做任何变更）
./provision.sh --project registry --status

# 没环境就造，有环境就跳过
./provision.sh --project registry

# 强制重造
./provision.sh --project registry --force

# 释放
./provision.sh --project registry --cleanup
```

供给成功后产物写入 `tmp/provisioned.env`（0600），**`run.sh` 启动时自动加载**。
文件不存在时该逻辑是 no-op，因此不影响「环境已由外部提供」的默认路径。

### 3.2 为什么设计成"可选钩子"而不是改默认流程

- 不调用 `provision.sh` 时，`run.sh` 行为与改动前**完全一致**
- 已有环境时 `provision.sh` 是 no-op，不会误造第二套
- 未实现 `project_provision` 的项目调用 `provision.sh` 会**明确报错**，而不是静默跳过
- mesh / otel / tracing 不实现该钩子 → 行为不变

### 3.3 provider

| provider | 文件 | 状态 |
| --- | --- | --- |
| `ctyun` | `projects/registry/provision-ctyun.sh` | 天翼云贵州3 relay 路径。**流程已实跑通过，但拆成函数后尚未端到端重跑** |

选择方式：`REGISTRY_PROVISION_PROVIDER=ctyun`（默认）。

### 3.4 ctyun provider 的前置条件

1. 本机 VPN 已连通 ctyun 私网 —— relay 机器**没有公网 IP**，SSH 只能走 VPN 私网直连。
   验证：`ping -c1 10.64.0.1`
2. relay 凭据 JSON（0600），含 `accessKey` / `secretKey` / `endpoint` / `regionID`
3. SSH 私钥（microOS 镜像默认用户 `boot`）
4. `ctyun-relayctl` 二进制（可从 `cluster-api-provider-ctyun-relay` 离线编译）
5. `cluster-api-provider-ctyun-relay` 的 checkout（含 runbook 与 provider 包）

### 3.5 时间盒

个人账号 relay TTL **硬性 8h**，无法放宽。全流程实测约 55–65 分钟：

| 阶段 | 耗时 |
| --- | --- |
| bootstrap 机创建 | ~10 min |
| installer 下载 + 解压 | ~5 min |
| `setup.sh` → minialauda Ready | ~7 min |
| provider 包推送 + 证书 + AppRelease | ~5 min |
| ctyun 凭据 + global manifest apply | ~3 min |
| 控制面创建 → KCP Ready | ~6 min |
| 安装器提交 | ~1 min |
| **安装器部署（17 步）** | **~25 min** |

**请务必在时间盒起始时就跑。**

### 3.6 实测踩坑

`provision-ctyun.sh` 的头部注释里逐条列了 8 条，其中最容易浪费时间的三条：

1. **provider 包必须用 `beta` 渠道**。群公告给的 `default` 渠道（commit `aa1856c2`）
   其 `CtyunCluster` CRD 不含 `apiEndpointType` / `retentionHours`，
   照 runbook §5.2 做会报 `field not declared in schema`。
2. **bootstrap VM 内网 DNS 必须用 `10.64.0.145`**，runbook 给的公网 DNS 解析不了 `*.alauda.cn`。
3. **IP 池稀疏**，指定 IP 大概率 409；用 `ip-reserve -subnet-id` 自动分配。

## 4. 环境能力开关

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `ENABLE_REGISTRY_EXPOSING` | `true` | `false` 时 Case 5 以 `[env]` 跳过 |
| `REGISTRY_UPGRADE_PACKAGE_URL` | 空 | 空时 Case 6 以 `[env]` 跳过 |
| `REGISTRY_PULL_SECRET_NAME` | `global-registry-auth` | 组件工作负载的 registry pull Secret |
| `PKG_REGISTRY_OPERATOR_URL` | 空 | 空即 verify-only |
| `REGISTRY_PROVISION_PROVIDER` | `ctyun` | 环境供给 provider |

**环境能力不要用标签表达**（框架约定）——用环境变量判断后 `case_skip ... env`。

## 5. 已知的"静默出错"陷阱

写 registry 测试脚本时特别注意这三类——它们**不报错，只给错误结果**：

1. **`managementState` 无默认值**。未设置时 `Config/cluster` 报 `Available=True (Removed)`，
   `image-registry` / `image-api-server` 根本不存在。断言组件存在前先确认 `Managed`。

2. **`kubectl auth can-i` 对 `registry/metrics` 恒返回 `no`**。
   该资源不在 `image.alauda.io/v1` 的 API discovery 里，`can-i` 无法解析。
   权限断言必须用 `SubjectAccessReview`。

3. **`ac get images` 在 legacy / modern 两种模式下输出列不同**。
   legacy 是 `<namespace/name>:<tag>`，modern 是 `<digest>` / `<完整引用>`。
   文档里的 awk 按列位置取值，模式没切对会拼出垃圾串。

## 6. 待办

- [ ] 把 `runme-test_*.sh` 写进 `acp-docs`（用 `.claude/skills/auto-test-creator` 生成）
- [ ] 给被测 `.mdx` 的代码块补 `{name=registry:<action>}` 属性
- [ ] `Dockerfile` 增加 `acp-docs` 的 clone（注意仓库体积）
- [ ] `lynx/assets-manifest.tsv` 登记测试脚本里的外部 URL（若有）
- [ ] release-config 的 `CASE_TYPE` 增加 registry 测试项
- [ ] `provision-ctyun.sh` 的第 4 步（装 ACP）尚未脚本化，需要时补齐
