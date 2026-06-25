---
name: auto-test-creator
description: >
  Use this skill whenever the user wants to create, update, debug, or manage automated test scripts
  for MDX documentation files. This includes: generating runme-test_*.sh scripts for docs/en/ MDX files,
  adding or checking {name=prefix:action} attributes on MDX code blocks, updating the docs-runme-tests
  README.md test table, modifying run-<project>-all.sh orchestration scripts (including --no-cleanup/--cleanup-only
  split execution), or troubleshooting failing runme test scripts. Trigger this skill when the user
  mentions any of: MDX testing, runme tests, document testing, code block name attributes, test script
  generation, run-<project>-all.sh updates, test coverage for documentation, or automated doc validation.
  Also use when the user references specific MDX files and wants to verify their code blocks work correctly.
---

# auto-test-creator: MDX 文档自动化测试脚本生成器

为项目中的 MDX 文档生成自动化测试脚本，确保文档中的命令和步骤可执行且输出正确。

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
   - 使用的测试模式（A-H）
   - 对应的 runme 代码块名称
4. **缺失步骤分析**（如有发现）：
   - 具体描述发现的问题
   - 建议的处理方式（在文档中补充步骤 / 在测试脚本中增加辅助逻辑）
5. **cleanup 判断**：是否需要 cleanup 函数，依据是什么
6. **编排脚本更新方案**：在对应项目的 `run-<project>-all.sh` 中的放置位置和执行方式

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

### 第五步：更新测试文档表格

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

#### 创建新的 case

```bash
# ------------------------------------------------------------------
# Case N: <测试描述>
# ------------------------------------------------------------------
case_begin "N" "<测试描述>"

if (
    set -e
    ./run.sh --file <test-name> --no-cleanup
    ./run.sh --file <test-name> --cleanup-only
); then
    case_end 0
else
    case_end 1
fi
```

> **测试结果统计（三层：Run → Case → DocTest）**：统计由 `framework/report.sh` 承载，编排脚本顶部需 `source framework/report.sh` + `report_init <项目>` + `export RUNME_TEST_ORCHESTRATED=1` + `trap report_finalize EXIT`（现有 `run-<project>-all.sh` 已具备）。Case 边界用：
> - `case_begin "N" "描述"` 开始一个 Case；`case_end 0/1` 结束（**普通 Case 失败只记录、不 `exit 1`，跑完全部再汇总**）。
> - 致命前置（如环境初始化）失败要中止整个 Run 时，用 `case_end_fatal 1` 取代 `case_end 1`。
> - 条件跳过（缺环境变量等）用 `case_skip "N" "描述" "跳过原因"` 取代整个 if 块。
> - 文档脚本内部主动跳过用 `skip_test "原因"`（引擎据此记 DocTest 为 skipped 第三态）。
>
> 退出时 `report_finalize` 自动产出美化终端摘要 + `tmp/runs/<run-id>/{summary.json,junit.xml}`。详见仓库 README「测试结果统计」章节。

### 第七步：设置可执行权限

```bash
chmod +x <测试脚本路径>
```

## 参考文件

如需更详细的信息，请参阅：

- `docs-runme-tests/README.md` - 测试框架完整说明
- `docs-runme-tests/framework/common.sh` - 公共工具函数源码
- `docs-runme-tests/framework/verify.sh` - 验证函数源码
- `docs-runme-tests/run.sh` - 测试执行引擎
- `docs-runme-tests/run-<project>-all.sh` - 各项目测试编排脚本

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
