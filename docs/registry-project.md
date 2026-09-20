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
2. **relay 凭据文件（由调用者提供，见 3.5）**
3. SSH 私钥（microOS 镜像默认用户 `boot`）
4. `ctyun-relayctl` 二进制（可从 `cluster-api-provider-ctyun-relay` 离线编译）
5. `cluster-api-provider-ctyun-relay` 的 checkout（含 runbook 与 provider 包）

### 3.5 凭据契约：**由调用者提供，仓库不保存**

**本仓库不保存任何 AK/SK，也不假设凭据属于谁。**

```bash
export CTYUN_CRED_FILE="$HOME/.codex/secrets/ctyun-relay/<你的账号>.json"   # 权限 0600
```

文件格式：

```json
{
  "apiEndpointType": "Relay",
  "endpoint": "https://ctyun-relay.alaudatech.net",
  "accessKey": "<AK>",
  "secretKey": "<SK>",
  "regionID": "<region>"
}
```

未提供时，`provision-ctyun.sh` 的前置校验会**明确失败**并打印上面的格式，
不会回退到任何默认路径。

#### 为什么不在仓库里给默认值

早期版本曾把某个人的账号名写成 `CTYUN_ACCOUNT` 的默认值。那不是密钥，但意味着
**「仓库知道某个人是谁」**：

- 别人用必然指向错误路径，失败原因还不明显
- 账号名是不该外泄的个人标识

`framework/tests/provision_test.sh` 的第 7 节把这条变成了**构建期会跑的守卫**：

| 守卫 | 断言 |
| --- | --- |
| 7.1 | 凭据路径不得硬编码具体账号名 |
| 7.2 | 仓库内不得出现 AK/SK 字面量（占位符与注释除外） |
| 7.3 | 不得写死某个人的家目录路径 |
| 7.4 | 未提供凭据时必须明确报错并给出格式 |

扫描器 `framework/tests/scan_secrets.py` 命中时**只回显掩码**，不把疑似密钥写进日志。

### 3.6 时间盒

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

### 3.7 实测踩坑

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

## 6. 怎么跑（不依赖 dailybuild）

这些测试**不需要** dailybuild 或任何 CI 就能跑。手动：

```bash
cd docs-runme-tests

# 有现成 ACP 环境时
export PLATFORM_ADDRESS=https://<your-acp>
export PLATFORM_USERNAME=<user>
export PLATFORM_PASSWORD=<password>
export RUNME_VERSION=3.16.11
export PKG_REGISTRY_OPERATOR_URL=<可选，Operator 包地址；留空要求平台已上架>

# 没有现成环境时（可选机制）
export CTYUN_CRED_FILE=~/.codex/secrets/ctyun-relay/<你的账号>.json
./provision.sh --project registry

# 跑单篇
./run.sh --project registry --file image-registry-operator

# 全量
./run-registry-all.sh
```

前置：`acp-docs` 要 clone 到 `docs-runme-tests` 的**兄弟目录**（`repos.conf` 里是 `registry:../acp-docs`），
或设 `REGISTRY_REPO_ROOT=/abs/path/to/acp-docs`。

## 7. 待办

分三档。**第一档是现在必须做的**，后两档等真需要时再做。

### 7.1 现在需要

- [ ] 把 `{name=registry:<操作>}` 属性补到其余 6 篇 Registry 文档
      （`image_registry_operator.mdx` 已完成，可作样板）
- [ ] 为这 6 篇各写一份 `runme-test_*.sh`
      （用 `.claude/skills/auto-test-creator` 生成，规范见 [writing-doc-tests.md](writing-doc-tests.md)）

### 7.2 等要接入 dailybuild 时再做

**这两项只在「希望 dailybuild 自动跑」时才需要。不做的话测试照样能手动跑**，
见上面第 6 节。

- [ ] **`Dockerfile` 增加 `acp-docs` 的 clone**
      作用：让 CI 构建出的测试镜像里**含有 acp-docs 与其中的测试脚本**。
      dailybuild 跑的是镜像，镜像里没有文档仓库就找不到 `runme-test_*.sh`。
      注意 `acp-docs` 体积远大于 mesh/otel/tracing 的三个文档仓库，会明显增加镜像大小与构建时间。
- [ ] **`apt-test/release-config` 增加 registry 测试项**
      作用：告诉 dailybuild **选中哪些 Case**。框架的 `CASE_TYPE` 只支持 `and` 合取与 `not`，
      不支持 `or` 和括号。不加这一项的话，registry 的 Case 在 dailybuild 上
      **不会跑，而且不会有任何报错**——只会在 allure 里显示成
      `[expected] 未被 CASE_TYPE 选中` 的跳过。

### 7.3 不着急

- [ ] `provision-ctyun.sh` 第 4 步（装 ACP）脚本化
      目前停在明确报错，可通过 `CTYUN_STEP4_SCRIPT` 接外部脚本。
- [ ] 把 `framework/acp-verify.sh` 的断言能力反哺给 mesh / otel / tracing 的既有脚本
      （可选优化，不影响新模块使用）

## 8. 关于「要不要改 acp-docs」

**测试脚本必须在 acp-docs 里，这是引擎写死的**：

```bash
# run.sh 的 _find_test_script
p=$(find "$repo/docs" -type f -name "runme-test_${file}.sh")
```

`$repo` 是 `repos.conf` 里注册的**文档仓库根**。`--file` 模式只在这个路径下找脚本。
绕过它的唯一办法是改引擎（框架级改动），或者直接
`FRAMEWORK_ROOT=... bash <脚本路径>` 手跑——但那样会丢掉三层报告与 allure 集成。

**MDX 的 `{name=}` 属性也必须加**，原因有二：

1. runme 只能按名字引用代码块（`runme run "<prefix>:<action>"`），没有按索引/行号的路径
2. 框架自己的 helper **硬编码了一批块名约定**。例如 `framework/common.sh` 的
   `install_operator` 会去找这些块：
   `<prefix>:check-packagemanifest-versions`、`<prefix>:confirm-catalogsource`、
   `<prefix>:create-subscription-<operator>`、`<prefix>:wait-installplan-pending`、
   `<prefix>:approve-installplan-manual`、`<prefix>:wait-csv-succeeded`、
   `<prefix>:check-csv-status`。不加 name 就用不了这些 helper。

**但「改 acp-docs」≠「必须提 PR」**。`{name=}` 是 MDX 代码围栏的元数据，
**渲染后完全不可见**，对读者零影响；mesh/otel/tracing 三个文档仓库都是这个约定。
当前状态是**只推了分支、没开 PR**，需要用的人 checkout 分支即可。
要不要开 PR、什么时候开，取决于 acp-docs 的维护节奏。
