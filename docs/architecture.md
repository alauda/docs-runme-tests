# 工作原理

## 1. runme 工具

测试用 [runme](https://runme.dev) 执行 MDX 文档中的代码块：解析带 `{name=xxx}` 属性的代码块，`runme run <block>` 执行、`runme print <block>` 取内容。引擎在执行测试前会 `cd` 到该文档仓库根，使 runme 能定位其代码块。

> runme 用 `$SHELL` 决定拿什么解释器执行 ```bash 代码块，`$SHELL` 为空就退回 dash，`column -t -s $'\t'` 这类写法当场失效。构建期的 `lynx/check-runtime-shell.sh` 专门拦这一条。
>
> 对 ```yaml 代码块，`runme run` 只回显不执行且返回 0，所以测试脚本要用 `runme print` 取内容后 `eval`。

## 2. 项目钩子

每个 `projects/<name>/project.sh` 实现三个标准钩子，由引擎调用：

| 钩子 | 调用时机 | 职责 |
| --- | --- | --- |
| `project_check_env` | 每次运行开头 | 校验项目专属环境变量 |
| `project_init <clusters>` | 仅 `--init-only` / `--force-init` | kubeconfig + 插件包 + operator 等重量级初始化 |
| `project_prepare` | 每次运行 | kubeconfig 加载等轻量级准备 |

引擎还会向项目钩子与测试脚本导出：`FRAMEWORK_ROOT`、`DOC_REPO_ROOT`、`PROJECT`、各 `SKIP_*` 开关，以及带 `--cluster` 时的 `TEST_TARGET_CLUSTER`（本次运行的目标集群名）。后者是因为走平台 API 的操作要的是 ACP 集群名而不是 kubeconfig context——例如 tracing 的 Jaeger 集群插件资源建在 Global 集群，只切 context 无法决定它落到哪个集群。

## 3. 测试脚本结构

每个 `runme-test_*.sh` 含 `test_<name>()`（执行步骤与验证），卸载 / 清理类文档还含 `cleanup_<name>()`。脚本头部固定为：

```bash
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
```

## 4. 验证工具

`framework/verify.sh` 提供输出比对函数：`__cmp_same`（精确）、`__cmp_contains`（包含）、`__cmp_not_contains`、`__cmp_regex`、`__cmp_lines`（逐行 +/- 断言）等。

> `__cmp_like` 暂有问题，勿用。

## 5. mesh 网关与内核兼容公共函数

`projects/mesh/project.sh` 提供以下网关公共函数（封装自 `gateways/gateway-installation/` 两篇文档），供 `directing-traffic-into-the-mesh` / `directing-outbound-traffic` / `install-*-multi-network` 等测试复用：

| 函数 | 用途 |
| --- | --- |
| `install_gateway_via_injection <gw_name> <gw_ns> [context]` | 通过 gateway injection 安装网关（含可选 HPA/PDB；去 infra 调度；内核兼容开启时 Deployment 以 root 运行） |
| `apply_kernel_compat_istio_gateway [run_as_root=true] [context]` | Istio Gateway（注入）路径内核兼容：修补 mesh 级注入模板并等待 Istio Ready |
| `apply_kernel_compat_k8s_gateway_api <ns> <gw_name> [run_as_root=true] [context]` | K8s Gateway API 路径内核兼容：建 `asm-kube-gateway-options` ConfigMap 并给 Gateway 挂 `parametersRef` |
| `relax_psa_for_root_gateway <ns> [run_as_root=true] [context]` | 网关以 root 运行时，把命名空间 PSA `enforce` 从 `restricted` 放宽为 `baseline` |

两个 `apply_kernel_compat_*` 受 `ENABLE_GW_LINUX_KERNEL_COMPAT` 门控（默认 `false` 时直接返回 no-op）。`run_as_root=false` → Scenario 1（仅去 sysctls，高端口网关）；`true` → Scenario 2（+ NET_BIND_SERVICE + root，特权端口网关）。多集群东西向网关与 ambient waypoint 传 `false`；监听 80 的 ambient ingress 网关用默认 `true`。

**与 Restricted PSA 的关系**：文档已把 bookinfo / httpbin / curl / egress-gateway 等命名空间设为 `enforce=restricted`，该 profile 禁止 root 容器，与 Scenario 2 的 `runAsUser: 0` 互斥，故 `apply_kernel_compat_k8s_gateway_api` 与 `reconcile_injected_gateway_runasroot` 在 `run_as_root=true` 时会先放宽为 `baseline`（与 `linux-kernel-compatibility-notice.mdx` 的结论一致）。默认不触发，命名空间保持 Restricted。

> Gateway API 网关与 waypoint 的 seccomp 配置走另一条通道：`Istio` 资源的 `spec.values.gatewayClasses.<class>.deployment` overlay，由各文档自己的 `*:patch-gatewayclass*` 代码块下发（见 `installing/pod-security-admission.mdx`），必须在创建 `Gateway` 之前执行。

## 6. 测试结果统计（Run → Case → DocTest）

由 `framework/report.sh` 提供，数据源为每次运行的 `results.jsonl`（JSON Lines）。

- **Run**：一次 `run-<project>-all.sh` 或一次独立 `./run.sh --file`。
- **Case**：编排脚本中的一个用例组（`case_begin` / `case_end`），内含一到多个 `./run.sh`。
- **DocTest**：一次 `./run.sh --file <doc>`，对应一篇文档的 `runme-test_<doc>.sh`。

**失败策略**：跑完全部再汇总——致命前置（环境初始化）失败立即中止，普通 Case 失败记录后继续。

**状态三态**：passed / failed / skipped。跳过按语义分两类：

| 函数 | 语义 | allure 分类 |
| --- | --- | --- |
| `skip_test_env "原因"` | 环境 / 版本 / 依赖不具备 | `[env]` |
| `skip_test_expected "原因"` | 产品版本、架构或测试范围明确不测 | `[expected]` |
| `skip_test "原因"` | `skip_test_expected` 的历史别名，**新代码不要用** | `[expected]` |

编排层条件跳过用 `case_skip <case_id> <case_name> <reason> [category]`，`category` 同为 `env` / `expected`（默认 `expected`）。分类会写进 allure 的 `categories.json`，看板上是「环境不支持」「预期不测试」两栏。写错会让「环境没配好」混进「本来就不测」，排查时直接被忽略过去。

**产物**（位于 `tmp/runs/<run-id>/`，`latest` 软链指向最近一次）：

| 文件 | 说明 |
| --- | --- |
| `results.jsonl` | 唯一数据源，每行一条记录 |
| `summary.json` | 三层结构化汇总（两套计数 + 每 Case 明细） |
| `junit.xml` | 标准 JUnit，对接 CI |

终端结束时打印美化摘要（总耗时、Case/DocTest 两套计数、每 Case 一行、失败 / 跳过明细）。退出码：有 failed 则非 0。

## 7. 框架单元测试

`framework/tests/` 下的单测均不依赖集群与平台（伪造 kubectl / runme / allure），构建期会全量跑一遍：

```bash
for t in framework/tests/*_test.sh; do bash "$t" >/dev/null || echo "FAIL: $t"; done
```

## 8. 编写新测试

推荐用 Claude Code 的 `/auto-test-creator` skill 自动生成，定义见 `.claude/skills/auto-test-creator/SKILL.md`。它会分析 MDX、添加 `{name=}` 属性、生成测试脚本、更新文档清单与编排脚本。

手工新增时的同步义务见 [maintenance.md](maintenance.md#1-case-更新新增或修改一篇文档的测试)。
