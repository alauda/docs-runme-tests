---
name: auto-test-creator
description: >
  Use this skill whenever the user wants to create, update, debug, or manage automated test scripts
  for MDX documentation files. This includes: generating runme-test_*.sh scripts for docs/en/ MDX files,
  adding or checking {name=prefix:action} attributes on MDX code blocks, updating the docs-runme-tests
  README.md test table, registering case_ids in lynx/case-ids.tsv, registering external URLs in
  lynx/assets-manifest.tsv for offline runs, choosing Case tags for CASE_TYPE filtering, modifying
  run-<project>-all.sh orchestration scripts (including --no-cleanup/--cleanup-only
  split execution), or troubleshooting failing runme test scripts. Trigger this skill when the user
  mentions any of: MDX testing, runme tests, document testing, code block name attributes, test script
  generation, run-<project>-all.sh updates, case_id registration, offline assets, CASE_TYPE tags,
  test coverage for documentation, or automated doc validation.
  Also use when the user references specific MDX files and wants to verify their code blocks work correctly.
---

# auto-test-creator: MDX 文档自动化测试脚本生成器

为项目中的 MDX 文档生成自动化测试脚本，确保文档中的命令和步骤可执行且输出正确。

> **这些测试同时要在 dailybuild / lynx 的离线环境里跑。**
> 意味着新写的测试脚本除了"本地能跑通"，还必须满足三条硬约束，漏一条就会在
> **镜像构建阶段直接失败**，或者更糟——镜像照常构建、dailybuild 照常绿灯，
> 但那条用例根本没跑：
>
> 1. **登记 case_id**（第五步）—— 未登记的 `runme-test_*.sh` 会让镜像构建失败
> 2. **外部 URL 走离线资产**（第四步「离线资产」小节）—— 否则离线环境跑到一半才炸
> 3. **Case 必须用 `case_begin_if` 带标签**（第六步）—— 否则要么在 lynx 上无条件执行，
>    要么永远选不中
>
> 完整的"改了 X 还要同步改哪儿"见 `docs-runme-tests/UPDATE-README.md`。

## 工作流程

### 第一步：分析目标 MDX 文档

1. 读取用户指定的 MDX 文档文件
2. 提取所有代码块，分析哪些需要测试
3. 确认代码块是否已有 `{name=prefix:action}` 属性
4. 如果代码块缺少 name 属性，需要先添加
5. **检测潜在的缺失步骤**（见下方详细说明）

#### 缺失步骤检测

分析 MDX 文档时，需要关注以下可能存在的缺失执行步骤：

- **隐含的前置条件**：文档中的命令可能依赖未在文档中显式记录的前置步骤（如创建命名空间、设置标签、安装依赖等）
- **等待/就绪步骤缺失**：部署资源后通常需要等待就绪，但文档中可能跳过了等待步骤
- **环境变量设置遗漏**：后续命令可能引用了未在文档中设置的环境变量
- **代码块之间的逻辑断层**：前后代码块之间缺少必要的中间步骤
- **清理步骤不完整**：如果文档描述了资源创建但缺少对应的清理步骤

将所有发现的问题记录到执行计划中，供用户审阅。

### 第二步：创建执行计划

在开始编写测试脚本之前，先创建执行计划（plan），等待用户审批后再实施。

**计划内容必须包含：**

1. **文档概要**：文档功能描述、包含的代码块数量
2. **代码块清单**：列出所有需要添加/修改 name 属性的代码块，及其拟定的 name
3. **测试步骤规划**：列出测试脚本中每个步骤的详细说明，包括：
   - 步骤编号和描述
   - 使用的测试模式（A-J）
   - 对应的 runme 代码块名称
4. **缺失步骤分析**（如有发现）：
   - 具体描述发现的问题
   - 建议的处理方式（在文档中补充步骤 / 在测试脚本中增加辅助逻辑）
5. **cleanup 判断**：是否需要 cleanup 函数，依据是什么
6. **编排脚本更新方案**：在对应项目的 `run-<project>-all.sh` 中的放置位置、执行方式、
   以及该 Case 的**标签**（决定它在 dailybuild 上跑不跑）
7. **离线与登记事项**：拟分配的 case_id；代码块里是否有外部 URL、要新增哪几条
   `assets-manifest.tsv` 记录；是否需要同步 release-config 的 `CASE_TYPE`

**计划格式示例：**

```markdown
## 执行计划：<文档名称> 测试脚本

### 1. 文档概要

- 文件路径：`docs/en/xxx/yyy.mdx`
- 功能描述：xxx
- 代码块总数：N 个（M 个需要测试）

### 2. 代码块命名规划

| #   | 代码块类型 | 当前状态  | 拟定 name              | 备注       |
| --- | ---------- | --------- | ---------------------- | ---------- |
| 1   | bash       | 缺少 name | `prefix:action`        |            |
| 2   | text       | 缺少 name | `prefix:action-output` | 输出验证块 |

### 3. 测试步骤规划

| 步骤 | 描述     | 测试模式 | runme 代码块                             |
| ---- | -------- | -------- | ---------------------------------------- |
| 1    | 创建资源 | 模式 A   | `prefix:create-resource`                 |
| 2    | 验证输出 | 模式 B   | `prefix:verify` + `prefix:verify-output` |

### 4. 缺失步骤分析（如无则省略此节）

- ⚠️ 步骤 3 和步骤 4 之间缺少等待部署就绪的步骤
- ⚠️ 文档未包含命名空间创建步骤，但后续命令依赖该命名空间

### 5. cleanup 判断

- [有/无] cleanup 函数
- 依据：文档中 [包含/不包含] 清理步骤代码块

### 6. 编排脚本更新

- 添加到 Case N：<描述>
- 执行方式：[直接执行 / 分步执行（--no-cleanup + --cleanup-only）]
- Case 标签：`smoke install xxx`（是否进首批 dailybuild：[是/否]，依据：带不带 `smoke`）

### 7. 离线与登记事项

- 拟分配 case_id：`ASM-DOC-0NN`（当前最大编号 +1）
- 外部 URL：[无 / 有 N 条，需登记进 `lynx/assets-manifest.tsv`，脚本用模式 J]
- release-config 同步：[不需要 / 需要，因为新标签 `xxx` 不在现有 CASE_TYPE 表达式内]
```

**使用 `EnterPlanMode` 工具进入计划模式**，将计划写入 plan 文件，等待用户审批。

### 第三步：为 MDX 代码块添加 name 属性

用户审批计划后，按照计划执行以下操作。

**命名规范：**

- 格式：`{name=前缀:操作名}`
- 前缀从文档功能模块派生，使用连字符连接（如 `dual-stack`、`install-mesh`、`config-kiali`）
- 操作名描述代码块的具体操作（如 `create-istio`、`verify-config`、`deploy-application`）
- 同一文档中所有代码块使用相同前缀
- **输出验证代码块**：名称以 `-output` 结尾，与对应命令块配对

**示例：**

````markdown
<!-- 命令代码块 -->

````bash {name=my-feature:create-resource}
kubectl create namespace test
\```

<!-- 对应的期望输出代码块 -->
```text {name=my-feature:create-resource-output}
namespace/test created
\```
````
````

**重要注意事项：**

- 每个需要测试的代码块都必须有 name 属性
- 需要验证输出的命令，必须有配对的 `-output` 代码块
- 代码块类型可以是 `bash`、`shell`、`yaml`、`text`、`html` 等
- YAML 文件内容代码块可以用 `name` 标记以便 `runme print` 获取内容

### 第四步：创建测试脚本

在 MDX 文档同目录下创建 `runme-test_<文档名>.sh` 文件。

**脚本模板：**

```bash
#!/usr/bin/env bash
# <文档描述>测试脚本

set -e

# FRAMEWORK_ROOT 由 docs-runme-tests/run.sh 引擎注入
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
# 代码块里有外部 URL（模式 J）时需要 runme_run_with_assets：
# source "$FRAMEWORK_ROOT/framework/assets.sh"
# mesh 项目脚本如需 kubectl_apply_with_mirror 等，额外引入对应 project.sh：
# source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

test_<feature_name>() {
    log_info "=========================================="
    log_info "开始 <功能名称> 测试"
    log_info "=========================================="

    # 测试步骤...

    log_success "=========================================="
    log_success "<功能名称> 测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# 仅在文档包含清理步骤时才添加 cleanup 函数
cleanup_<feature_name>() {
    log_info "=========================================="
    log_info "清理 <功能名称> 测试资源"
    log_info "=========================================="

    runme run <prefix>:cleanup || {
        log_error "清理资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
```

### 关键规则

#### 框架定位（FRAMEWORK_ROOT 注入）

测试脚本不再自行计算仓库路径。`docs-runme-tests/run.sh` 引擎在执行测试脚本前会注入以下环境变量：

| 变量                  | 含义                                                        |
| --------------------- | ----------------------------------------------------------- |
| `FRAMEWORK_ROOT`      | docs-runme-tests 框架仓库根                                 |
| `DOC_REPO_ROOT`       | 当前被测脚本所在的文档仓库根                                 |
| `<PROJECT>_REPO_ROOT` | 各文档仓库根（如 `OTEL_REPO_ROOT`），用于跨仓库执行 runme 块 |

脚本头部固定写法（与脚本所在目录深度无关）：

```bash
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
```

#### 测试步骤模式

**模式 A - 执行命令并检查返回值：**

```bash
log_info "步骤 X: <步骤描述>"
runme run <prefix>:<action> || {
    log_error "<操作>失败"
    return 1
}
```

**模式 B - 执行命令并验证输出（使用 -output 配对代码块）：**

```bash
log_info "步骤 X: <步骤描述>"
local output expected
output=$(runme run <prefix>:<action>)
expected=$(runme print <prefix>:<action>-output)

if ! __cmp_contains "$output" "$expected"; then
    log_error "<验证>失败"
    log_error "期待输出: $expected"
    log_error "实际输出: $output"
    return 1
fi
log_success "<验证>通过"
```

**注**：不能死板的使用 `__cmp_contains`，要先分析 `expected` 的内容。如果输出包含动态值（如 pod 名称后缀、IP、AGE、时间戳等），应使用**模式 I（`__cmp_lines`）**来验证关键字段而非精确匹配。

**模式 C - 获取模板内容并写入文件：**

```bash
log_info "步骤 X: 生成配置文件"
runme print <prefix>:<template-name> > "/tmp/<filename>" || {
    log_error "获取模板失败"
    return 1
}
```

**模式 D - 使用 kubectl_apply_with_mirror（部署含镜像的资源）：**

```bash
log_info "步骤 X: 部署应用"
kubectl_apply_with_mirror <prefix>:<deploy-action> || {
    log_error "部署失败"
    return 1
}
```

**模式 E - 使用 kubectl_apply_runme_block（在指定目录执行）：**

```bash
log_info "步骤 X: 应用配置"
kubectl_apply_runme_block "<prefix>:<apply-action>" "/tmp/" || {
    log_error "应用配置失败"
    return 1
}
```

**模式 F - 使用 eval 执行设置环境变量：**

```bash
log_info "步骤 X: 获取配置"
eval "$(runme print <prefix>:<get-config>)" || {
    log_error "获取配置失败"
    return 1
}
```

**模式 G - 使用 install_operator 安装 Operator：**

```bash
install_operator \
    "<operator-name>" \
    "<namespace>" \
    "$PKG_<OPERATOR>_URL" \
    "<runme-prefix>"
```

**注（verify-only 模式）**：`PKG_*_URL` 为空是**合法输入**，不是配置错误。
dailybuild 上所有插件包由平台预上架，框架不设置任何 `PKG_*_URL`，
`install_operator` / `install_cluster_plugin` 会进 verify-only 模式：只校验是否已上架，
不下载不上架；真没上架时精确报错。所以：

- 不要在测试脚本里写 `: "${PKG_XXX_URL:?}"` 这类硬校验，那会让 dailybuild 直接失败
- 项目钩子 `project_check_env` 里对空 URL 只 `log_info` 提示，不要 `return 1`

**模式 J - 引用外部 URL 的代码块（离线资产）：**

如果文档代码块里有 `kubectl apply -f https://...` 这种外部 URL，**不能用 `runme run`**——
dailybuild 环境连不上公网。改用：

```bash
log_info "步骤 X: 部署 sample 应用"
runme_run_with_assets <prefix>:<action> || {
    log_error "部署失败"
    return 1
}
```

`runme_run_with_assets` 来自 `framework/assets.sh`，会把命中 `lynx/assets-manifest.tsv`
的 URL 换成镜像内预置文件；未命中的 URL 原样保留、回退联网 curl，本地开发行为不变。

配套动作（**两步都要做**）：

1. 把新 URL 登记进 `docs-runme-tests/lynx/assets-manifest.tsv`，两列 TAB 分隔：
   `<url><TAB><去掉协议头的 URL 全路径>`
2. 跑 `bash lynx/check-manifest.sh` 确认输出"资产清单校验通过"

走 `kubectl_apply_with_mirror`（模式 D）的块**不用改调用方**——该函数内部已经用
`fetch_url_content` 处理了离线资产。

#### 可用的公共工具函数

来自 `framework/common.sh`：

| 函数                          | 用途                         |
| ----------------------------- | ---------------------------- |
| `log_info/warn/error/success` | 日志输出                     |
| `kubectl_apply_with_mirror`   | 带镜像加速的 kubectl apply   |
| `kubectl_apply_runme_block`   | 在指定目录中执行 runme block |
| `_wait_for_deployment`        | 等待 Deployment 就绪         |
| `_wait_for_resource`          | 等待资源创建                 |
| `retry_command`               | 重试执行命令                 |
| `install_operator`            | 通用 Operator 安装           |

来自 `framework/verify.sh`：

| 函数                 | 用途                                   |
| -------------------- | -------------------------------------- |
| `__cmp_same`         | 精确匹配                               |
| `__cmp_contains`     | 包含子串                               |
| `__cmp_not_contains` | 不包含子串                             |
| `__cmp_elided`       | 模糊匹配（支持 `...` 通配符）          |
| `__cmp_regex`        | 正则匹配                               |
| `__cmp_first_line`   | 首行匹配                               |
| `__cmp_lines`        | 逐行验证（`+` 必须包含，`-` 不能包含） |

**注意**：`__cmp_like` 目前有问题，不要使用。

#### 100% 测试覆盖率

测试脚本必须覆盖 MDX 文档中所有带 `{name=}` 属性的代码块：

- 所有命令代码块都必须通过 `runme run` 执行
- 所有输出代码块都必须通过 `runme print` 获取并用于验证
- 不能遗漏任何代码块

**严格遵守文档边界**：测试脚本只测试文档中存在的代码块，不要自行添加额外的验证步骤（如额外的 kubectl get 命令）。测试的目的是验证文档中的命令是否可执行且输出正确，而不是编写端到端测试。

#### cleanup 函数判断

只有当 MDX 文档中明确包含清理/卸载步骤的代码块（如名为 `<prefix>:cleanup` 的代码块），或者文档本身就是清理类文档时，才在测试脚本中添加 `cleanup_*` 函数。不要自行编写清理逻辑。

#### 处理动态占位符

某些文档中的命令包含动态占位符（如 `<name_of_custom_resource>`），需要在测试脚本中动态替换。

**模式 H - 动态占位符替换：**

当文档中的命令包含占位符（如 `<xxx>`），需要先从前序命令的输出中提取实际值，然后替换模板中的占位符再执行：

```bash
# 1. 执行前序命令获取实际值
log_info "步骤 X: 获取资源名称"
local resource_output
resource_output=$(runme run <prefix>:get-resource 2>&1) || {
    log_error "获取资源失败"
    return 1
}

# 2. 从输出中提取实际资源名称
local resource_name
resource_name=$(echo "$resource_output" | awk 'NR==2 {print $1}')

# 3. 获取命令模板，替换占位符后执行
log_info "步骤 Y: 删除资源"
local delete_cmd
delete_cmd=$(runme print <prefix>:delete-resource)
delete_cmd="${delete_cmd//<placeholder>/$resource_name}"
local delete_output
delete_output=$(eval "$delete_cmd" 2>&1) || {
    log_error "删除资源失败"
    return 1
}

# 4. 验证输出（输出模板中的占位符也需要替换）
local expected_output
expected_output=$(runme print <prefix>:delete-resource-output)
expected_output="${expected_output//<placeholder>/$resource_name}"
if ! __cmp_contains "$delete_output" "$expected_output"; then
    log_error "验证失败"
    return 1
fi
```

**识别占位符的方法**：阅读 MDX 文档时，注意命令中用尖括号 `<>` 包裹的内容。如果文档说"用前一步的输出替换 `<xxx>`"，则需要在脚本中实现动态替换。

**模式 I - 使用 `__cmp_lines` 验证含动态值的输出：**

`kubectl get pod`、`kubectl get svc`、`istioctl proxy-status` 等命令的输出中包含动态生成的值（pod 名称后缀、IP 地址、AGE 时间、VIP 等），无法做精确匹配。`__cmp_lines` 函数通过逐行关键字断言来解决这个问题：

- `+ keyword`：断言输出中**必须包含**该关键字的行
- `- keyword`：断言输出中**不能包含**该关键字的行

这比手动编写 `grep -q` 循环更简洁、可读性更好，且与项目其他测试脚本保持一致。

```bash
# 输出包含动态值（pod 名称后缀、AGE 等），使用 __cmp_lines 验证关键字段
log_info "步骤 X: 验证资源状态"
local output
output=$(runme run <prefix>:<verify-action> 2>&1)

if ! __cmp_lines "$output" "$(cat <<'EOF'
+ keyword-that-must-exist
+ another-required-keyword
- keyword-that-must-not-exist
EOF
)"; then
    log_error "验证失败"
    log_error "实际输出: $output"
    return 1
fi
log_success "验证通过"
```

**何时使用 `__cmp_lines`：**

- `kubectl get pods` 输出：pod 名含随机后缀、AGE 列动态变化 → 用 `+ pod-prefix` 和 `+ Running` 等关键字验证
- `kubectl get svc` 输出：ClusterIP 动态分配 → 用 `+ service-name` 验证
- `istioctl proxy-status` 输出：pod 名和版本号 → 用 `+ deployment-name` 和 `+ version` 验证
- 任何包含动态 IP、时间戳、随机 ID 的表格输出

**参考实现**：`servicemesh2-docs/docs/en/updating/update-mesh/runme-test_update-inplace.sh` 中步骤 9、12、15 展示了 `__cmp_lines` 的标准用法。

**与手动 grep 循环的对比：**

避免写这样的冗长代码：

```bash
# ❌ 不推荐：手动 grep 循环
local missing=()
for item in "pod-a" "pod-b" "pod-c"; do
    if ! echo "$output" | grep -q "$item"; then
        missing+=("$item")
    fi
done
if [ ${#missing[@]} -ne 0 ]; then
    log_error "验证失败"
    return 1
fi
```

用 `__cmp_lines` 替代：

```bash
# ✅ 推荐：使用 __cmp_lines
if ! __cmp_lines "$output" "$(cat <<'EOF'
+ pod-a
+ pod-b
+ pod-c
EOF
)"; then
    log_error "验证失败"
    log_error "实际输出: $output"
    return 1
fi
```

#### 捕获 stderr

对于可能输出到 stderr 的命令（如 kubectl），使用 `2>&1` 确保完整捕获输出：

```bash
output=$(runme run <prefix>:<action> 2>&1) || {
    log_error "操作失败"
    log_error "输出: $output"
    return 1
}
```

### 第五步：登记 case_id 并更新测试文档表格

#### 5.1 登记 case_id（必做，漏了会让镜像构建失败）

编辑 `docs-runme-tests/lynx/case-ids.tsv`，三列 TAB 分隔 `<project><TAB><doc><TAB><case_id>`：

```
mesh	install-mesh	ASM-DOC-002
```

- 编号规则：`mesh=ASM-DOC-NNN`、`otel=OTEL-DOC-NNN`、`tracing=TRACE-DOC-NNN`
- `doc` 列 = 文件名去掉 `runme-test_` 前缀和 `.sh` 后缀
- 新增文档取当前最大编号 **+1**
- **一经分配永不复用**：文档改名时保留原编号、只改 `doc` 列。allure 报告靠它做历史对齐，
  换编号等于历史断链
- 自检：`bash lynx/check-case-ids.sh`

#### 5.2 更新 README 测试清单表

编辑 `docs-runme-tests/README.md`，在对应项目的测试文档表格中添加新条目：

```markdown
| <文档名称> | [runme-test\_<文档名>.sh](相对路径) | `./run.sh --project <项目> --file <文档名>` |
```

### 第六步：更新测试编排脚本

编辑对应项目的 `run-<project>-all.sh`（如 `run-mesh-all.sh` / `run-otel-all.sh` / `run-tracing-all.sh`），在合适的位置添加新的测试 case 或加入已有 case。下方示例中的 `./run.sh --file <name>` 可省略 `--project`（引擎按 repos.conf 自动查找）；编排脚本中建议显式写 `./run.sh --project <项目> --file <name>`。

#### 判断执行方式

根据测试脚本是否包含 cleanup 函数来决定执行方式：

**无 cleanup 函数 — 直接执行：**

```bash
./run.sh --file <test-name>
```

**有 cleanup 函数 — 分两步执行：**

测试和清理分开执行，这样即使清理失败也能明确定位问题，且允许在调试时跳过清理（`--no-cleanup`）或单独重试清理（`--cleanup-only`）。

```bash
./run.sh --file <test-name> --no-cleanup
./run.sh --file <test-name> --cleanup-only
```

#### 添加到已有 case

```bash
# 在对应 case 的 if ( ... ) 块中添加
./run.sh --file <new-test-name> --no-cleanup
./run.sh --file <new-test-name> --cleanup-only
```

#### 创建新的 case（必须用 `case_begin_if` + 标签）

```bash
# ------------------------------------------------------------------
# Case N: <测试描述>
# ------------------------------------------------------------------
if case_begin_if "N" "<测试描述>" smoke install <功能标签>; then
    if (
        set -e
        ./run.sh --project <项目> --file <test-name> --no-cleanup
        ./run.sh --project <项目> --file <test-name> --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi
```

**不要写裸 `case_begin`**。`case_begin_if` 会按 `CASE_TYPE` 过滤：选中则开 Case 并返回 0，
未选中则记一条 `[expected]` 跳过并返回 1。写成裸 `case_begin` 的 Case 在 lynx 上会无条件执行，
绕过 dailybuild 的分批策略。

#### 标签怎么选

`CASE_TYPE` 只支持 `and` 连接的合取式与 `not` 取反，**不支持 `or` 和括号**
（见 `lynx/case-filter.sh`；写了 `or` 会直接报错退出，不会静默误判）。

| 想要的效果 | 标签 |
| --- | --- |
| 每次都跑（环境初始化这类前置） | `always`——保留标签，恒被选中，不参与表达式求值 |
| 进首批 dailybuild | 必须带 `smoke`（首批表达式是 `smoke and not egress`） |
| 只在多集群测试项里跑 | `multicluster` |
| 暂不纳入、先攒着 | 只给功能标签（如 `opensearch`），不给 `smoke` |

**加了新标签，多半要同步改 `apt-test/release-config` 的 `CASE_TYPE`。**
因为不支持 `or`，"让两组互不相干的 Case 都跑"没法写成一个表达式——必须另开一个 lynx 测试项
（现有 `docs-mesh-multicluster` 就是为此单开的）。漏改的后果是这条用例在 dailybuild 上
永远不跑，且不报错，只在 allure 里显示成一条跳过。核对方法：

```bash
source lynx/case-filter.sh
_case_type_matches "smoke and not egress" smoke install sidecar && echo 选中 || echo 未选中
```

#### DocTest 级开关

单篇文档要按标签开关（不整个 Case）时，用 `doctest_selected`：

```bash
if doctest_selected egress; then
    ./run.sh --project mesh --file routing-egress-traffic-tls-origination
fi
```

> **测试结果统计（三层：Run → Case → DocTest）**：统计由 `framework/report.sh` 承载，编排脚本顶部需 `source framework/report.sh` + `report_init <项目>` + `export RUNME_TEST_ORCHESTRATED=1` + `trap report_finalize EXIT`（现有 `run-<project>-all.sh` 已具备）。Case 边界用：
> - `case_begin_if "N" "描述" <标签>...` 开始一个 Case（推荐）；`case_end 0/1` 结束（**普通 Case 失败只记录、不 `exit 1`，跑完全部再汇总**）。
> - 致命前置（如环境初始化）失败要中止整个 Run 时，用 `case_end_fatal 1` 取代 `case_end 1`。
> - 环境条件不满足（缺环境变量等）用 `case_skip "N" "描述" "跳过原因" env` 取代整个 if 块——
>   第 4 个参数是分类，缺省 `expected`；缺环境变量属于 `env`。
> - 文档脚本内部主动跳过要**分清两种语义**：
>   - `skip_test_env "原因"`——环境不支持（缺集群 / 缺存储 / 单栈环境跑双栈），记 `[env]`
>   - `skip_test_expected "原因"`——预期就不测（本轮有意不覆盖），记 `[expected]`
>   - `skip_test "原因"` 是 `skip_test_expected` 的别名，**新代码不要用**
>
>   分类会进 allure 的 `categories.json`，看板上是两栏；写错会让"环境没配好"混进
>   "本来就不测"，排查时被直接忽略过去。
>
> 退出时 `report_finalize` 自动产出美化终端摘要 + `tmp/runs/<run-id>/{summary.json,junit.xml}`，
> 在 lynx 上额外产出 `$TEST_RESULT_DIR/{allure-result,allure-report}`。详见仓库 README「测试结果统计」章节。

### 第七步：设置可执行权限

```bash
chmod +x <测试脚本路径>
```

注意提交时权限位要跟着进 git（`git update-index --chmod=+x <path>` 或直接确认
`git diff --summary` 里有 `mode change`）。跨仓库改动时这一步很容易漏，漏了 runme 跑不起来。

### 第八步：自检

在 `docs-runme-tests` 仓库根执行：

```bash
bash lynx/check-case-ids.sh       # case_id 登记了吗（第五步）
bash lynx/check-manifest.sh       # 新增的外部 URL 登记了吗（模式 J）
bash lynx/check-shell-compat.sh   # 有没有 macOS/bash 3.2 会炸的写法（见下）
```

三条都在镜像构建期强制执行，任一不过即构建失败。

## 硬性写法约束

### `$VAR` 后面紧跟中文标点必须写成 `${VAR}`

```bash
log_info "集群 ${cluster} 上不存在地址池 ${pool}，跳过"   # ✅
log_info "集群 $cluster 上不存在地址池 $pool，跳过"        # ❌ macOS 上会炸
```

bash 用 locale 相关的 `isalnum()` 判断变量名边界。macOS 的 BSD libc 在 UTF-8 locale 下
会把中文标点的首字节当成 Latin-1 字母，于是 `$pool，` 里的变量名被解析成 `pool` 加标点字节——
未定义；叠加 `set -u` 直接退出。Linux（glibc）上看不出任何问题，所以只能靠
`bash lynx/check-shell-compat.sh` 拦。

### 多条命令的代码块：只有最后一条的返回码算数

`runme run <块>` 与 `kubectl_apply_runme_block` 都只回传代码块里**最后一条**命令的
返回码。文档里很常见的这种两条命令的块：

```bash
kubectl patch opentelemetrycollector jaeger -n ${JAEGER_NS} --type=merge -p "$(envsubst < patch.yaml)"

kubectl rollout status deployment/jaeger-collector -n ${JAEGER_NS} --timeout=300s
```

`patch` 失败、`rollout status` 对**未发生变更**的 Deployment 照样成功时，整块返回 0——
测试判定通过，实际什么都没改。这类失败往往要到很久以后才以别的症状暴露。

同类形状还有「apply Job → wait → delete Job」（wait 超时被 delete 吞掉）、
「rollout status → logs | grep || echo」（`|| echo` 恒为 0）。

**写法**：这种块不要用 `runme run`，改成起一个 `bash -e` 子进程执行，首条失败即中断：

```bash
content=$(runme print "$block")
bash -ec "$content"                  # 需要指定目录时: (cd /tmp && bash -ec "$content")
```

**不能用 `( set -e; eval "$content" )`** —— 实测 errexit 对 eval 的多行字符串不生效，
`( set -e; eval 'false; true' )` 返回 0。代码块引用的变量都要是 `export` 的，子进程才继承。

参考实现：`distributed-tracing-docs/docs/en/upgrading/_upgrade-common.sh` 的
`_upgrade_run_block`。

### runme 不执行 ` ```yaml ` 代码块

`runme run <yaml 块>` 只把内容**回显**出来、并不执行，而且返回码是 0——
看起来"跑过了"，实际什么都没做。

不要为此去改文档的语言标记（那是文档的呈现语义）。测试脚本里改用：

```bash
eval "$(runme print <prefix>:<yaml-block>)"
```

或者用模式 C 把内容写进文件再 `kubectl apply -f`。

### 兼容 bash 3.2（macOS 自带版本）

不要用 `declare -A`（关联数组）、`mapfile`、`readarray`，不要用 GNU 专属的 `sed -i`
（BSD sed 的 `-i` 需要参数）。

## 参考文件

如需更详细的信息，请参阅：

- `docs-runme-tests/README.md` - 测试框架完整说明（**怎么用**）
- `docs-runme-tests/UPDATE-README.md` - 变更操作手册（**改了 X 还要同步改哪儿**）
- `docs-runme-tests/framework/common.sh` - 公共工具函数源码
- `docs-runme-tests/framework/verify.sh` - 验证函数源码
- `docs-runme-tests/framework/assets.sh` - 离线资产（`runme_run_with_assets` 等）
- `docs-runme-tests/run.sh` - 测试执行引擎
- `docs-runme-tests/run-<project>-all.sh` - 各项目测试编排脚本
- `docs-runme-tests/lynx/` - lynx / dailybuild 适配层（入口、CASE_TYPE 求值、allure、各清单）
- `apt-test/release-config/tests/<版本>/dailybuild/dailybuild_mircos_g1.yaml` - dailybuild 测试项定义（`CASE_TYPE` 在这里）

## 已有测试脚本参考

以下是 servicemesh2-docs 仓库中已有的 mesh 测试脚本，可作为编写新脚本的参考（路径相对该仓库根）：

- `docs/en/installing/dual-stack/runme-test_install-mesh-in-dual-stack-mode.sh`
- `docs/en/installing/installing-service-mesh/runme-test_install-mesh.sh`
- `docs/en/installing/installing-service-mesh/application-deployment/runme-test_deploying-the-bookinfo-application.sh`
- `docs/en/integration/observability/runme-test_metrics-and-mesh.sh`
- `docs/en/integration/observability/runme-test_kiali.sh`
- `docs/en/uninstalling/runme-test_uninstalling-alauda-build-of-kiali.sh`
- `docs/en/uninstalling/runme-test_uninstalling-alauda-service-mesh.sh`
- `docs/en/updating/update-mesh/runme-test_update-inplace.sh`
