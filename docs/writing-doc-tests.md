# 给任意模块写文档测试

这篇是**模块无关**的作业指导：不管是 Registry、Service Mesh、还是将来任何一个产品模块，
给它的文档加自动化测试都走同一套骨架。具体某篇文档的测试脚本怎么写，
交给 `.claude/skills/auto-test-creator` 生成；这篇讲**骨架与判断**。

> 已经有 `auto-test-creator` skill 讲"怎么生成一个脚本"。这篇讲的是
> **"为什么这样写"以及"换模块时什么该改、什么不该改"**，两者互补。

---

## 1. 先分清三件事，不要混

| 层 | 在哪 | 换模块时 |
| --- | --- | --- |
| **执行引擎** | `run.sh` + `framework/*.sh` | **不改** |
| **通用断言** | `framework/verify.sh`（文本）+ `framework/acp-verify.sh`（集群状态） | **不改** |
| **模块专属** | `projects/<模块>/project.sh` + 该模块文档旁的 `runme-test_*.sh` | **要改** |

**判断标准**：一段逻辑如果两个不同模块的文档测试都会用到，它就该进 `framework/`；
只对某一个模块成立的，进 `projects/<模块>/` 或那个模块的测试脚本。

---

## 2. 两类断言，用错会写出"永远通过"的测试

### 2.1 文本断言（`framework/verify.sh`）

命令有稳定的期望输出时用：

```bash
output=$(runme run <prefix>:<action>)
expected=$(runme print <prefix>:<action>-output)
__cmp_contains "$output" "$expected" || return 1
```

输出含动态值（pod 后缀、IP、AGE）时改用 `__cmp_lines`：

```bash
__cmp_lines "$output" "$(cat <<'EOF'
+ pod-a
+ Running
- Error
EOF
)" || return 1
```

### 2.2 集群状态断言（`framework/acp-verify.sh`）

文档的 "Expected results" 大多是**散文**（"the CSV is Succeeded"、
"Config/cluster reports Available=True"），没有配对的 `-output` 块。
这时用状态断言：

```bash
assert_condition configs.imageregistry.operator.alauda.io cluster Available True || return 1
assert_jsonpath_eq cm foo '{.spec.mode}' Managed || return 1
assert_workload_ready deployment bar -n ns || return 1
```

**可用函数一览**：

| 函数 | 断言 |
| --- | --- |
| `assert_resource_exists <kind> <name> [ns]` | 资源存在 |
| `assert_resource_absent <kind> <name> [ns]` | 资源**不存在** |
| `assert_count <n> <kind> [ns]` | 资源数量 |
| `assert_jsonpath_eq <kind> <name> <path> <expected> [ns]` | 字段等于 |
| `assert_jsonpath_nonempty <kind> <name> <path> [ns]` | 字段非空 |
| `assert_condition <kind> <name> <type> <status> [ns]` | condition 状态 |
| `assert_workload_ready <kind> <name> [ns]` | 工作负载就绪 |
| `assert_crd_field_exists <crd> <path>` | CRD schema 有字段 |
| `assert_crd_field_absent <crd> <path>` | CRD schema **无**字段 |
| `assert_rbac_allowed <user> <verb> <group> <res> [sub]` | 权限允许 |
| `assert_rbac_denied <user> <verb> <group> <res> [sub]` | 权限拒绝 |
| `assert_output_always <expected> <prefix:action>` | 输出**恒为**某值 |
| `assert_output_contains <prefix:action> <needle>` | 输出包含子串 |
| `assert_idempotent <prefix:action> [dir]` | 可重复执行 |

---

## 3. 四个必须知道的执行陷阱

### 3.1 `runme run` 只回传**最后一条**命令的返回码

文档里这种形状很常见：

```bash
kubectl patch <资源> --type=merge -p '...'

kubectl rollout status deployment/<名字> --timeout=300s
```

`patch` 失败、而 `rollout status` 对**未变更**的资源照样成功 → 整块返回 0 →
测试判定通过，实际什么都没改。

**改用**：

```bash
run_block_strict <prefix>:<action>            # 内部用 bash -ec，首条失败即中断
```

`run_block_strict` 来自 `framework/acp-verify.sh`。
**不要**写成 `( set -e; eval "$content" )` —— errexit 对 eval 的多行字符串不生效。

### 3.2 `runme run` 对 ```yaml 块**只回显不执行**

返回码还是 0。看起来"跑过了"，实际什么都没做。

**改用**：

```bash
apply_yaml_block <prefix>:<action>            # 取内容后 kubectl apply -f -
# 或模式 C：runme print 写进文件，再执行文档里的 apply 命令
```

### 3.3 权限断言不要用 `kubectl auth can-i`

对**不在 API discovery 里**的资源（典型：`image.alauda.io` 的 `registry/metrics`），
`kubectl auth can-i` 无法解析资源名，**恒返回 `no`** —— 即使 RBAC 完全正确。

实测：把 `system:image-registry-metrics-reader` 绑给一个 SA 后，
`SubjectAccessReview` 判 `allowed=true`，而 `can-i` 仍返回 `no`。
照 `can-i` 的结论排查会一路查错方向。

**改用** `assert_rbac_allowed` / `assert_rbac_denied`（内部走 SAR）。

> 附带坑：kubectl 会缓存 API discovery（默认 10 分钟）。新装的聚合 API 刚起来时
> 缓存里没有对应子资源，`can-i` 也会误报 `no`。同一类问题的两种表现。

### 3.4 断言"不存在"与断言"存在"一样重要

文档经常给否定性论断（「全新环境里没有这个包」「该字段未实现」「这个限制不由 registry 施加」）。
这类论断**不能靠"命令没报错"通过**，必须显式断言缺失：

```bash
assert_resource_absent packagemanifests.packages.operators.coreos.com cluster-image-registry-operator -n cpaas-system
assert_crd_field_absent configs.imageregistry.operator.alauda.io '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.storage.properties.oss'
```

注意 `assert_resource_absent` 只把 **NotFound** 当"不存在"。
权限错误、API 不存在等会判**失败** —— 否则"查不了"会被当成"没有"。

---

## 4. 骨架：任何模块的测试脚本都长这样

```bash
#!/usr/bin/env bash
# <模块> — <文档名> 文档测试
set -e
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/acp-verify.sh"

test_<doc_name>() {
    log_info "开始 <文档名> 文档测试"

    # ① 前置：确认文档写下的前提条件成立
    #    例：文档说"包必须在 OperatorHub 里"，就先断言它在——
    #    否则后面每一步的失败原因都会被准入拒绝掩盖
    _step_prerequisites || return 1

    # ② 逐块执行：每个带 {name=} 的块都要跑到（100% 覆盖）
    run_block_strict <prefix>:<action-a> || return 1
    run_block_strict <prefix>:<action-b> || return 1

    # ③ 断言文档的期望结果（散文写的也要验）
    assert_condition <kind> <name> Available True || return 1

    log_success "<文档名> 文档测试完成"
    return 0
}
```

### 换模块时要改什么

| 要改 | 不要改 |
| --- | --- |
| 块名前缀（`<prefix>:`） | `run_block_strict` / `assert_*` 的用法 |
| 步骤函数里的资源 kind / name | 前置检查的**思路** |
| 环境能力开关的判断条件 | `skip_test_env` 的用法 |
| 模块专属前置（`projects/<模块>/project.sh`） | `framework/` 里任何东西 |

---

## 5. 环境能力差异：用 `skip_test_env`，不要用标签

环境不具备某能力时（没有 LoadBalancer、没有监控插件、目录源里没有更新版本），
**不要**让用例失败，也不要加标签排除：

```bash
if [ -z "${SOME_PACKAGE_URL:-}" ]; then
    skip_test_env "未提供 SOME_PACKAGE_URL，目录源中无更新版本，跳过"
fi
```

框架的约定：**环境能力用环境变量判断后 `case_skip ... env`**，
标签只表达"测试范围"（`smoke` / `multicluster` / …）。
写反了会让「环境没配好」混进「本来就不测」，看板上再也分不清。

---

## 6. 完成一个模块的检查清单

- [ ] 被测 `.mdx` 的每个代码块都有 `{name=<前缀>:<操作>}`
- [ ] `runme-test_<doc>.sh` 与 `.mdx` **同仓同目录**
- [ ] 脚本覆盖全部带 name 的块（`auto-test-creator` 的 100% 覆盖要求）
- [ ] 多命令块用 `run_block_strict`，不是 `runme run`
- [ ] yaml 块用 `apply_yaml_block` 或模式 C，不是 `runme run`
- [ ] 权限断言用 `assert_rbac_*`，不是 `kubectl auth can-i`
- [ ] 环境能力差异用 `skip_test_env`，不是标签
- [ ] `lynx/case-ids.tsv` 已登记 `case_id`（**漏了会让镜像构建失败**）
- [ ] `run-<模块>-all.sh` 里用 `case_begin_if` 带标签（裸 `case_begin` 在 lynx 上会无条件执行）
- [ ] `bash lynx/check-shell-compat.sh` 通过（`$VAR` 后跟中文标点必须写 `${VAR}`）
- [ ] 用 `/bin/bash -n` 验过（macOS 自带 3.2；不要用 `declare -A` / `mapfile` / GNU `sed -i`）

---

## 7. 参考实现

| 参考 | 位置 | 演示了什么 |
| --- | --- | --- |
| Registry / Image Registry Operator | `acp-docs/docs/en/configure/registry/runme-test_image-registry-operator.sh` | 通用骨架、状态断言、`run_block_strict`、环境能力跳过、把"文档改动的理由"固化成断言 |
| 通用断言库 | `docs-runme-tests/framework/acp-verify.sh` | 全部状态断言的实现与设计约定 |
| 断言库单测 | `docs-runme-tests/framework/tests/acp_verify_test.sh` | 每个断言的「应通过 / 应失败」两侧都测（防"恒返回 0"） |
| mesh 系列 | `servicemesh2-docs/docs/en/**/runme-test_*.sh` | 多集群、动态占位符、`__cmp_lines` 的实战用法 |
| tracing 升级 | `distributed-tracing-docs/docs/en/upgrading/_upgrade-common.sh` | 公共代码块参数化、`_upgrade_run_block` |

---

## 8. 最后一条：断言要能失败

写断言时问自己一句：**「如果文档说的不对，这条断言会不会失败？」**

不会失败的断言比没有断言更糟——它给人虚假的安全感。
`framework/tests/acp_verify_test.sh` 里每个断言都测了「应通过」与「应失败」两侧，
就是这个道理。给新模块写断言时，也照这个标准测一遍。
