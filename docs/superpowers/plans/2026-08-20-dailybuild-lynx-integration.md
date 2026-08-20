# 文档测试接入 dailybuild / lynx 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `docs-runme-tests` 同时支持本地手工运行与 lynx dailybuild 调度运行——以容器镜像交付，产出 allure 报告，运行时零外网依赖。

**Architecture:** 框架内核（`run.sh` / `framework/` / `projects/` / `runme-test_*.sh`）不感知 lynx。所有 lynx 相关知识集中在新增的 `lynx/` 目录与 `framework/report.sh` 的一个新输出后端里。三个文档仓库在镜像构建时按 ref clone 进来，`repos.conf` 的相对路径天然成立。

**Tech Stack:** Bash 3.2 兼容、`jq`、`kubectl`、`runme`、`violet`、`istioctl`、allure CLI 2.24.1 + JRE、Docker、Tekton PaC、lynx CRD（`testing.alauda.io/v1alpha1`）

设计文档：`docs/superpowers/specs/2026-08-20-dailybuild-lynx-integration-design.md`

## Global Constraints

- **Bash 3.2 兼容**：不用 `declare -A`、`mapfile`、`readarray`；数组遍历用 `while IFS= read -r` 收集。
- **跨平台**：Linux（CI/镜像）与 macOS（本地）都要能跑；不依赖 GNU sed 的 `-i` 就地编辑与 `\n` 替换扩展。
- **本地行为不能退化**：不设 `TEST_RESULT_DIR` 时不生成 allure，不需要本机装 allure CLI 与 JRE；`CASE_TYPE` 未设置时全部 Case 选中。
- **报告中不得出现密码、token、私钥**。
- **`CASE_TYPE` 语法**：只支持 `and` 连接的合取式与 `not` 取反；出现 `or` 必须报错退出。
- **保留标签 `always`**：带该标签的 Case 恒被选中，不参与表达式求值。
- **skip 前缀**：环境不支持 → `[env] `；预期不测试 → `[expected] `。
- **镜像 tag 规则**：`master` → `latest` + `master-<短 commit>`；`release-mesh-2.x` → `release-<ACP 大版本>` + `<branch>-<短 commit>`。
- **镜像仓库**：`build-harbor.alauda.cn/asm/docs-runme-tests`。
- **单测必须不依赖集群与平台**：新增单测一律用伪造的 `kubectl` / `runme` / `allure`。
- **提交规范**：不使用 `git commit --amend`；提交信息不含 `Co-Authored-By` 与 `Claude-Session`。
- **注释与日志用中文**，与现有代码风格一致。

**当前分支**：`feat/dailybuild-lynx-integration`（已创建，设计文档已提交）。

---

### Task 1: CASE_TYPE 表达式求值与 Case 标签

**Files:**
- Create: `lynx/case-filter.sh`
- Create: `framework/tests/case_filter_test.sh`
- Modify: `framework/report.sh`（顶部 source 区、`case_begin`、`_case_record`、新增 `case_selected` / `doctest_selected` / `case_begin_if`）

**Interfaces:**
- Consumes: 无
- Produces:
  - `_case_type_matches <case_type_expr> <tag>...` → 0 选中 / 1 未选中 / 2 表达式非法
  - `case_selected <tag>...` → 0/1，表达式非法时 `log_error` 并 `exit 1`
  - `doctest_selected <tag>...` → 同 `case_selected`
  - `case_begin_if <case_id> <case_name> <tag>...` → 选中则 `case_begin` 并返回 0；否则 `case_skip` 并返回 1
  - `case_begin <case_id> <case_name> [tags]` → 第三参数写入 `RUNME_TEST_CASE_TAGS`，并进入 `type=case` 记录的 `tags` 字段

- [ ] **Step 1: 写失败的单测**

创建 `framework/tests/case_filter_test.sh`：

```bash
#!/usr/bin/env bash
# case-filter.sh 单元测试（纯 bash，不依赖集群）
# 用法: bash framework/tests/case_filter_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/lynx/case-filter.sh"

T_PASS=0
T_FAIL=0

# check_rc <描述> <期望返回码> <case_type> <tag...>
check_rc() {
    local desc="$1" want="$2" expr="$3"; shift 3
    local got=0
    _case_type_matches "$expr" "$@" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$desc"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望 rc=%s 实际 rc=%s\n' "$desc" "$want" "$got"
    fi
}

test_matches() {
    printf '\n== _case_type_matches ==\n'
    check_rc "空表达式全选"            0 ""                          smoke install
    check_rc "单标签命中"              0 "smoke"                     smoke install
    check_rc "单标签未命中"            1 "update"                    smoke install
    check_rc "合取全命中"              0 "smoke and install"         smoke install sidecar
    check_rc "合取部分命中即未选中"    1 "smoke and update"          smoke install
    check_rc "not 排除命中"            1 "smoke and not egress"      smoke egress
    check_rc "not 排除未命中"          0 "smoke and not egress"      smoke install
    check_rc "仅 not"                  0 "not egress"                smoke install
    check_rc "always 恒选中"           0 "update and not install"    always install
    check_rc "always 对空表达式亦可"   0 ""                          always
    check_rc "or 表达式非法"           2 "smoke or update"           smoke
    check_rc "标签前缀不误命中"        1 "smoke"                     smoketest install
}

main() {
    test_matches
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
```

- [ ] **Step 2: 运行单测确认失败**

```bash
bash framework/tests/case_filter_test.sh
```

预期：报错 `framework/tests/case_filter_test.sh: line 13: .../lynx/case-filter.sh: No such file or directory`。

- [ ] **Step 3: 实现 `lynx/case-filter.sh`**

```bash
#!/usr/bin/env bash
# CASE_TYPE 表达式求值
#
# 语法（ares pytest -m 语义的子集）：只支持 and 连接的合取式与 not 取反，
# 例如 "smoke and not egress"。不支持 or 与括号——需要并集时多开一个 lynx 测试项。
#
# 保留标签 always：带该标签的 Case 恒被选中，不参与表达式求值。用于环境初始化
# 这类「任何子集都必须先跑」的前置 Case。

# _case_type_matches <case_type_expr> <tag>...
# 返回: 0=选中  1=未选中  2=表达式非法
_case_type_matches() {
    local expr="$1"; shift
    local tags=" $* "

    # 保留标签 always：无条件选中
    case "$tags" in *" always "*) return 0 ;; esac

    # 空表达式（或全空白）= 全选
    case "$expr" in
        *[![:space:]]*) : ;;
        *) return 0 ;;
    esac

    # or / 括号：明确不支持，报非法而不是静默误判
    case " $expr " in
        *" or "*|*"("*|*")"*)
            printf '不支持的 CASE_TYPE 表达式（仅支持 and / not 合取式）: %s\n' "$expr" >&2
            return 2
            ;;
    esac

    local negate=0 token
    for token in $expr; do
        case "$token" in
            and) continue ;;
            not) negate=1; continue ;;
            *)
                if [ "$negate" -eq 1 ]; then
                    case "$tags" in *" $token "*) return 1 ;; esac
                else
                    case "$tags" in
                        *" $token "*) : ;;
                        *) return 1 ;;
                    esac
                fi
                negate=0
                ;;
        esac
    done
    return 0
}
```

- [ ] **Step 4: 运行单测确认通过**

```bash
bash framework/tests/case_filter_test.sh
```

预期：`通过: 12  失败: 0`。

- [ ] **Step 5: 在 report.sh 顶部加载过滤器并新增门控函数**

在 `framework/report.sh` 第 9 行（`# ── 内部：向 results.jsonl 追加一行 ──` 之前）插入：

```bash
# ── 可选加载 CASE_TYPE 过滤器（lynx 层，缺失时 case_selected 恒为真）──
if [ -f "${FRAMEWORK_ROOT:-}/lynx/case-filter.sh" ]; then
    # shellcheck disable=SC1090
    . "${FRAMEWORK_ROOT}/lynx/case-filter.sh"
fi

# ── case_selected <tag>... ──
# 依据 CASE_TYPE 判断某组标签是否被选中。过滤器未加载时恒为真（本地行为不变）。
# 表达式非法时立刻退出——静默跳过全部用例比报错危险得多。
case_selected() {
    if ! declare -F _case_type_matches >/dev/null 2>&1; then
        return 0
    fi
    local rc=0
    _case_type_matches "${CASE_TYPE:-}" "$@" || rc=$?
    if [ "$rc" -eq 2 ]; then
        log_error "CASE_TYPE 表达式非法（仅支持 and / not 合取式）: ${CASE_TYPE:-}"
        exit 1
    fi
    return "$rc"
}

# ── doctest_selected <tag>... ──
# 与 case_selected 同语义，命名区分调用场景（Case 内部按标签跳过个别 DocTest）。
doctest_selected() {
    case_selected "$@"
}

# ── case_begin_if <case_id> <case_name> <tag>... ──
# 选中则 case_begin 并返回 0；未选中则 case_skip（分类 expected）并返回 1。
case_begin_if() {
    local cid="$1" cname="$2"
    shift 2
    if case_selected "$@"; then
        case_begin "$cid" "$cname" "$*"
        return 0
    fi
    case_skip "$cid" "$cname" "CASE_TYPE='${CASE_TYPE:-}' 未选中标签 [$*]"
    return 1
}
```

- [ ] **Step 6: 让 case_begin 接收标签并写入 case 记录**

在 `framework/report.sh` 中把 `case_begin` 替换为：

```bash
# ── case_begin <case_id> <case_name> [tags] ──
case_begin() {
    RUNME_TEST_CASE_ID="$1"
    RUNME_TEST_CASE_NAME="$2"
    RUNME_TEST_CASE_TAGS="${3:-}"
    export RUNME_TEST_CASE_ID RUNME_TEST_CASE_NAME RUNME_TEST_CASE_TAGS
    __CASE_START_TS="$(date +%s)"
    log_header "Case $1: $2"
}
```

把 `_case_record` 替换为：

```bash
# ── 内部：写 type=case 记录 ──
_case_record() {
    local status="$1" end_ts duration
    end_ts="$(date +%s)"
    duration=$(( end_ts - ${__CASE_START_TS:-$end_ts} ))
    _report_append "$(jq -nc \
        --arg type "case" --arg case_id "${RUNME_TEST_CASE_ID:-}" \
        --arg case_name "${RUNME_TEST_CASE_NAME:-}" --arg status "$status" \
        --arg tags "${RUNME_TEST_CASE_TAGS:-}" \
        --argjson duration_s "$duration" \
        '{type:$type,case_id:$case_id,case_name:$case_name,status:$status,tags:$tags,duration_s:$duration_s}')"
}
```

`case_end` 与 `case_end_fatal` 里的 `unset RUNME_TEST_CASE_ID RUNME_TEST_CASE_NAME` 全部改为
`unset RUNME_TEST_CASE_ID RUNME_TEST_CASE_NAME RUNME_TEST_CASE_TAGS`（共 3 处）。

- [ ] **Step 7: 在 report_test.sh 补 case_begin 标签的回归**

在 `framework/tests/report_test.sh` 的 `test_case_skip` 之后插入：

```bash
# ── 测试：case_begin 标签进入 case 记录 ──
test_case_tags() {
    printf '\n== case_begin tags ==\n'
    new_sandbox
    case_begin 3 "单网格" "smoke install sidecar" >/dev/null
    case_end 0 >/dev/null
    local line; line="$(cat "$RUNME_TEST_RUN_DIR/results.jsonl")"
    check_contains "tags 写入 case 记录" "$line" '"tags":"smoke install sidecar"'
    rm -rf "$RUNME_TEST_RUN_DIR"
}

# ── 测试：case_begin_if 按 CASE_TYPE 门控 ──
test_case_begin_if() {
    printf '\n== case_begin_if ==\n'
    new_sandbox
    CASE_TYPE="smoke and not egress"
    if case_begin_if 3 "命中" smoke install >/dev/null; then
        case_end 0 >/dev/null
        check_eq "命中时进入 Case" "1" "1"
    else
        check_eq "命中时进入 Case" "0" "1"
    fi
    case_begin_if 8 "未命中" update >/dev/null || true
    local body; body="$(cat "$RUNME_TEST_RUN_DIR/results.jsonl")"
    check_contains "未命中记为 case_skip" "$body" '"type":"case_skip"'
    check_contains "未命中原因含 CASE_TYPE" "$body" 'CASE_TYPE'
    unset CASE_TYPE
    rm -rf "$RUNME_TEST_RUN_DIR"
}
```

在 `main()` 的 `test_case_skip` 之后加入两行调用：

```bash
    test_case_tags
    test_case_begin_if
```

- [ ] **Step 8: 运行两个单测确认通过**

```bash
bash framework/tests/case_filter_test.sh && bash framework/tests/report_test.sh
```

预期：两个都以 `失败: 0` 结束。

- [ ] **Step 9: 提交**

```bash
git add lynx/case-filter.sh framework/tests/case_filter_test.sh framework/report.sh framework/tests/report_test.sh
git commit -m "feat: CASE_TYPE 表达式过滤与 Case 标签

- 新增 lynx/case-filter.sh，仅支持 and/not 合取式，or 报错退出
- 保留标签 always 恒选中，供环境初始化类 Case 使用
- report.sh 新增 case_selected / doctest_selected / case_begin_if
- case_begin 接收 tags 并写入 type=case 记录"
```

---

### Task 2: skip 二分类（环境不支持 / 预期不测试）

**Files:**
- Modify: `framework/common.sh:105-111`（`skip_test`）
- Modify: `framework/report.sh`（`case_skip`）
- Modify: `framework/tests/report_test.sh`

**Interfaces:**
- Consumes: 无
- Produces:
  - `skip_test_env <reason>` → `__TEST_SKIP_REASON="[env] <reason>"`
  - `skip_test_expected <reason>` → `__TEST_SKIP_REASON="[expected] <reason>"`
  - `skip_test <reason>` → 保留为 `skip_test_expected` 的别名
  - `case_skip <case_id> <case_name> <reason> [category]` → `skip_reason="[<category>] <reason>"`，`category` 默认 `expected`

- [ ] **Step 1: 写失败的单测**

在 `framework/tests/report_test.sh` 的 `test_skip_test` 函数之后插入：

```bash
# ── 测试：skip 二分类前缀 ──
test_skip_categories() {
    printf '\n== skip 二分类 ==\n'
    __TEST_SKIPPED=0; __TEST_SKIP_REASON=""
    skip_test_env "集群非双栈" >/dev/null
    check_eq "env 前缀" "$__TEST_SKIP_REASON" "[env] 集群非双栈"
    check_eq "env 置位" "$__TEST_SKIPPED" "1"

    __TEST_SKIPPED=0; __TEST_SKIP_REASON=""
    skip_test_expected "CASE_TYPE 未选中" >/dev/null
    check_eq "expected 前缀" "$__TEST_SKIP_REASON" "[expected] CASE_TYPE 未选中"

    __TEST_SKIPPED=0; __TEST_SKIP_REASON=""
    skip_test "历史调用" >/dev/null
    check_eq "skip_test 别名走 expected" "$__TEST_SKIP_REASON" "[expected] 历史调用"
}

# ── 测试：case_skip 分类参数 ──
test_case_skip_category() {
    printf '\n== case_skip 分类 ==\n'
    new_sandbox
    case_skip 2 "双栈" "IS_DUAL_STACK != true" env >/dev/null
    check_contains "指定 env 分类" "$(cat "$RUNME_TEST_RUN_DIR/results.jsonl")" '"skip_reason":"[env] IS_DUAL_STACK != true"'
    rm -rf "$RUNME_TEST_RUN_DIR"

    new_sandbox
    case_skip 8 "更新策略" "未选中" >/dev/null
    check_contains "缺省 expected 分类" "$(cat "$RUNME_TEST_RUN_DIR/results.jsonl")" '"skip_reason":"[expected] 未选中"'
    rm -rf "$RUNME_TEST_RUN_DIR"
}
```

在 `main()` 中 `test_skip_test` 之后加入：

```bash
    test_skip_categories
    test_case_skip_category
```

- [ ] **Step 2: 运行单测确认失败**

```bash
bash framework/tests/report_test.sh
```

预期：出现 `skip_test_env: command not found` 一类错误，且 `失败:` 计数非 0。

- [ ] **Step 3: 实现 skip 二分类**

把 `framework/common.sh` 中的 `skip_test`（约 105-111 行）整段替换为：

```bash
# 文档测试脚本主动声明「跳过」。分两类（自动化规范第 8 条）：
#   skip_test_env      —— 环境 / 版本 / 依赖不具备，报告里按成功处理
#   skip_test_expected —— 产品版本、架构或测试选择明确不执行
# 两者都设置 __TEST_SKIPPED 标记后 return 0；引擎 run.sh 据此把 DocTest 记为 skipped。
# 前缀 [env] / [expected] 供 allure categories 分类使用，勿改。
skip_test_env() {
    __TEST_SKIPPED=1
    __TEST_SKIP_REASON="[env] $1"
    log_warn "SKIPPED（环境不支持）: $1"
    return 0
}

skip_test_expected() {
    __TEST_SKIPPED=1
    __TEST_SKIP_REASON="[expected] $1"
    log_warn "SKIPPED（预期不测试）: $1"
    return 0
}

# 历史别名：语义等同 skip_test_expected，逐篇迁移到语义正确的那个后可移除
skip_test() {
    skip_test_expected "$1"
}
```

在 `framework/report.sh` 中把 `case_skip` 替换为：

```bash
# ── case_skip <case_id> <case_name> <reason> [category] ──
# category: expected（默认，预期不测试）| env（环境不支持）
case_skip() {
    local category="${4:-expected}"
    _report_append "$(jq -nc \
        --arg type "case_skip" --arg case_id "$1" --arg case_name "$2" \
        --arg skip_reason "[${category}] $3" \
        '{type:$type,case_id:$case_id,case_name:$case_name,skip_reason:$skip_reason}')"
    log_warn "Case $1: $2 —— SKIPPED（$3）"
}
```

- [ ] **Step 4: 运行单测确认通过**

```bash
bash framework/tests/report_test.sh
```

预期：`失败: 0`。

- [ ] **Step 5: 提交**

```bash
git add framework/common.sh framework/report.sh framework/tests/report_test.sh
git commit -m "feat: skip 二分类（环境不支持 / 预期不测试）

- 新增 skip_test_env / skip_test_expected，前缀 [env] / [expected]
- skip_test 保留为 skip_test_expected 别名
- case_skip 新增 category 参数，默认 expected"
```

---

### Task 3: allure 报告后端

**Files:**
- Create: `lynx/allure.sh`
- Create: `framework/tests/allure_test.sh`
- Modify: `framework/report.sh`（顶部 source 区、`report_finalize`）

**Interfaces:**
- Consumes: `results.jsonl` 的 `type=doctest` / `type=case` / `type=case_skip` 记录（Task 1 已给 `type=case` 加上 `tags` 字段）；`lynx/case-ids.tsv`（Task 9 产出，缺失时 `case_id` 标签省略）
- Produces:
  - `allure_emit_results <results.jsonl> <allure-result-dir>` → 每条 doctest 一个 `<uuid>-result.json`
  - `allure_emit_broken <allure-result-dir> <message>` → 写一条 `broken` 占位用例
  - `allure_write_environment <allure-result-dir>`
  - `allure_write_categories <allure-result-dir>`
  - `allure_generate <allure-result-dir> <allure-report-dir>`
  - `allure_finalize <results.jsonl> <TEST_RESULT_DIR>` → 上述四步的组合
  - `report_finalize` 在 `TEST_RESULT_DIR` 非空时调用 `allure_finalize`，并按 `EXIT_ON_TEST_FAILURE` 决定返回码

- [ ] **Step 1: 写失败的单测**

创建 `framework/tests/allure_test.sh`：

```bash
#!/usr/bin/env bash
# lynx/allure.sh 单元测试（纯 bash + jq，不依赖集群，allure CLI 用桩替代）
# 用法: bash framework/tests/allure_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/lynx/allure.sh"

T_PASS=0
T_FAIL=0

check_contains() {
    if __cmp_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 造一份 results.jsonl：1 个 Case（含 tags）+ 2 条 doctest（1 passed 1 skipped）
make_results() {
    local f="$1"
    cat > "$f" <<'EOF'
{"type":"doctest","project":"mesh","file":"install-mesh","script":"runme-test_install-mesh.sh","case_id":"3","case_name":"单网格","phase":"test","status":"passed","skip_reason":"","fail_reason":"","start_ts":100,"end_ts":160,"duration_s":60}
{"type":"doctest","project":"mesh","file":"routing-egress-traffic-via-istio-apis","script":"runme-test_routing-egress-traffic-via-istio-apis.sh","case_id":"3","case_name":"单网格","phase":"test","status":"skipped","skip_reason":"[env] 集群不能访问外网","fail_reason":"","start_ts":160,"end_ts":161,"duration_s":1}
{"type":"case","case_id":"3","case_name":"单网格","status":"passed","tags":"smoke install sidecar","duration_s":61}
EOF
}

test_emit_results() {
    printf '\n== allure_emit_results ==\n'
    local dir; dir="$(mktemp -d)"
    make_results "$dir/results.jsonl"
    printf 'mesh\tinstall-mesh\tASM-DOC-002\n' > "$dir/case-ids.tsv"
    ALLURE_CASE_IDS_FILE="$dir/case-ids.tsv" allure_emit_results "$dir/results.jsonl" "$dir/allure-result"

    check_eq "生成 2 个用例文件" "$(find "$dir/allure-result" -name '*-result.json' | wc -l | tr -d ' ')" "2"

    local merged; merged="$(cat "$dir"/allure-result/*-result.json)"
    check_contains "fullName 带项目前缀" "$merged" '"fullName": "mesh/install-mesh"'
    check_contains "毫秒时间戳"          "$merged" '"start": 100000'
    check_contains "suite 标签"          "$merged" '"value": "Case 3: 单网格"'
    check_contains "feature 标签"        "$merged" '"value": "mesh"'
    check_contains "tag 标签展开"        "$merged" '"value": "sidecar"'
    check_contains "case_id 标签"        "$merged" '"value": "ASM-DOC-002"'
    check_contains "skipped 用例"        "$merged" '"status": "skipped"'
    check_contains "skip 原因带 env 前缀" "$merged" '[env] 集群不能访问外网'
    rm -rf "$dir"
}

test_emit_broken() {
    printf '\n== allure_emit_broken ==\n'
    local dir; dir="$(mktemp -d)"
    allure_emit_broken "$dir/allure-result" "docs-test mesh 异常退出"
    local merged; merged="$(cat "$dir"/allure-result/*-result.json)"
    check_contains "broken 状态" "$merged" '"status": "broken"'
    check_contains "含中断说明" "$merged" '异常退出'
    rm -rf "$dir"
}

test_environment_and_categories() {
    printf '\n== environment.properties / categories.json ==\n'
    local dir; dir="$(mktemp -d)"
    PLATFORM_ADDRESS="https://acp.example" PLATFORM_PASSWORD="s3cret" \
        SINGLE_CLUSTER_NAME="asm-1" CASE_TYPE="smoke and not egress" \
        allure_write_environment "$dir/allure-result"
    local env_out; env_out="$(cat "$dir/allure-result/environment.properties")"
    check_contains "写平台地址"   "$env_out" "platform.address=https://acp.example"
    check_contains "写被测集群"   "$env_out" "cluster.single=asm-1"
    check_contains "写 CASE_TYPE" "$env_out" "case.type=smoke and not egress"
    check_eq "不含密码" "$(printf '%s' "$env_out" | grep -c 's3cret')" "0"

    allure_write_categories "$dir/allure-result"
    local cat_out; cat_out="$(cat "$dir/allure-result/categories.json")"
    check_contains "含环境不支持分类" "$cat_out" "环境不支持"
    check_contains "含预期不测试分类" "$cat_out" "预期不测试"
    check_eq "categories.json 是合法 JSON" "$(printf '%s' "$cat_out" | jq -e 'type' 2>/dev/null)" '"array"'
    rm -rf "$dir"
}

test_generate_missing_cli() {
    printf '\n== allure_generate 缺 CLI 时报错 ==\n'
    local dir; dir="$(mktemp -d)"
    mkdir -p "$dir/allure-result"
    local rc=0
    PATH="/nonexistent-bin" allure_generate "$dir/allure-result" "$dir/allure-report" >/dev/null 2>&1 || rc=$?
    check_eq "缺 CLI 返回非 0" "$rc" "1"
    rm -rf "$dir"
}

main() {
    test_emit_results
    test_emit_broken
    test_environment_and_categories
    test_generate_missing_cli
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
```

- [ ] **Step 2: 运行单测确认失败**

```bash
bash framework/tests/allure_test.sh
```

预期：`.../lynx/allure.sh: No such file or directory`。

- [ ] **Step 3: 实现 `lynx/allure.sh`**

```bash
#!/usr/bin/env bash
# allure 报告后端：results.jsonl → allure-result/*.json → allure-report/
#
# 由 framework/report.sh 在 TEST_RESULT_DIR 非空时调用（即只在镜像/lynx 场景生效，
# 本地直接跑 run.sh 不触发，也就不需要本机装 allure CLI 与 JRE）。
#
# 用例粒度 = DocTest（一篇文档的一次 ./run.sh --file），Case 作为 suite 标签分组。

# case_id 清单：三列 TSV —— project<TAB>doc<TAB>case_id
ALLURE_CASE_IDS_FILE="${ALLURE_CASE_IDS_FILE:-${FRAMEWORK_ROOT:-.}/lynx/case-ids.tsv}"

# 生成 UUID（容器内 /proc 必然存在；缺失时回退随机十六进制）
_allure_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
    fi
}

# 查 case_id；清单缺失或未登记时输出空串（allure 标签随之省略）
_allure_case_id() {
    local project="$1" doc="$2"
    [ -f "$ALLURE_CASE_IDS_FILE" ] || return 0
    awk -F'\t' -v p="$project" -v d="$doc" '$1==p && $2==d {print $3; exit}' "$ALLURE_CASE_IDS_FILE"
}

# allure_emit_results <results.jsonl> <allure-result-dir>
allure_emit_results() {
    local results="$1" outdir="$2"
    [ -f "$results" ] || { log_error "allure_emit_results: 找不到 $results"; return 1; }
    mkdir -p "$outdir" || return 1

    # case_id -> {name, tags}：来自 type=case / type=case_skip 记录
    local casemap
    casemap=$(jq -sc '[.[] | select(.type=="case" or .type=="case_skip")
                       | {key: .case_id, value: {name: .case_name, tags: (.tags // "")}}]
                      | from_entries' "$results") || return 1

    local line rtype project doc uuid cid
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        rtype=$(printf '%s' "$line" | jq -r '.type // ""')
        [ "$rtype" = "doctest" ] || continue
        project=$(printf '%s' "$line" | jq -r '.project')
        doc=$(printf '%s' "$line" | jq -r '.file')
        uuid=$(_allure_uuid)
        cid=$(_allure_case_id "$project" "$doc")
        printf '%s' "$line" | jq \
            --arg uuid "$uuid" --arg case_id "${cid:-}" --argjson casemap "$casemap" '
            . as $r
            | ($casemap[$r.case_id] // {name: "（无 Case）", tags: ""}) as $c
            | {
                uuid: $uuid,
                name: $r.file,
                fullName: "\($r.project)/\($r.file)",
                historyId: "\($r.project)/\($r.file)",
                status: $r.status,
                statusDetails: {
                    message: (if $r.status == "failed" then ($r.fail_reason // "")
                              else ($r.skip_reason // "") end)
                },
                start: (($r.start_ts // 0) * 1000),
                stop:  (($r.end_ts   // 0) * 1000),
                labels: (
                    [ {name: "suite",    value: "Case \($r.case_id): \($c.name)"},
                      {name: "feature",  value: $r.project},
                      {name: "severity", value: "normal"} ]
                    + (if $case_id == "" then [] else [{name: "case_id", value: $case_id}] end)
                    + ($c.tags | split(" ") | map(select(length > 0)) | map({name: "tag", value: .}))
                )
              }' > "$outdir/${uuid}-result.json" || return 1
    done < "$results"
    return 0
}

# allure_emit_broken <allure-result-dir> <message>
# 编排异常中断、没有任何结果可汇总时，写一条 broken 占位用例。
# 空的 allure 目录会让 lynx 的 summaryResult 变成 NUL，比一条明确的 broken 更难排查。
allure_emit_broken() {
    local outdir="$1" message="$2"
    mkdir -p "$outdir" || return 1
    local uuid now
    uuid=$(_allure_uuid)
    now=$(( $(date +%s) * 1000 ))
    jq -nc --arg uuid "$uuid" --arg msg "$message" --argjson now "$now" \
        '{uuid: $uuid, name: "docs-test 执行中断", fullName: "docs-test/aborted",
          historyId: "docs-test/aborted", status: "broken",
          statusDetails: {message: $msg}, start: $now, stop: $now,
          labels: [{name: "severity", value: "critical"}]}' \
        > "$outdir/${uuid}-result.json"
}

# allure_write_environment <allure-result-dir>
# 注意：只写非敏感信息，绝不写密码 / token（自动化规范第 9 条）
allure_write_environment() {
    local dir="$1"
    mkdir -p "$dir" || return 1
    {
        printf 'platform.address=%s\n' "${PLATFORM_ADDRESS:-}"
        printf 'cluster.single=%s\n'   "${SINGLE_CLUSTER_NAME:-}"
        printf 'cluster.east=%s\n'     "${EAST_CLUSTER_NAME:-}"
        printf 'cluster.west=%s\n'     "${WEST_CLUSTER_NAME:-}"
        printf 'cluster.global=%s\n'   "${GLOBAL_CLUSTER_NAME:-}"
        printf 'image.tag=%s\n'        "${DOCS_TEST_IMAGE_TAG:-unknown}"
        printf 'docs.mesh.ref=%s\n'    "${MESH_DOCS_REF:-unknown}"
        printf 'docs.otel.ref=%s\n'    "${OTEL_DOCS_REF:-unknown}"
        printf 'docs.tracing.ref=%s\n' "${TRACING_DOCS_REF:-unknown}"
        printf 'case.type=%s\n'        "${CASE_TYPE:-}"
        printf 'resource.prefix=%s\n'  "${RESOURCE_PREFIX:-}"
        printf 'is.dual.stack=%s\n'    "${IS_DUAL_STACK:-false}"
        printf 'enable.metallb=%s\n'   "${ENABLE_METALLB:-false}"
    } > "$dir/environment.properties"
}

# allure_write_categories <allure-result-dir>
# 把 skip 的两个分类与真实缺陷区分开；未匹配的 failed 落入 allure 默认的 Product defects
allure_write_categories() {
    local dir="$1"
    mkdir -p "$dir" || return 1
    cat > "$dir/categories.json" <<'EOF'
[
  {
    "name": "环境不支持",
    "matchedStatuses": ["skipped"],
    "messageRegex": "^\\[env\\][\\s\\S]*"
  },
  {
    "name": "预期不测试",
    "matchedStatuses": ["skipped"],
    "messageRegex": "^\\[expected\\][\\s\\S]*"
  }
]
EOF
}

# allure_generate <allure-result-dir> <allure-report-dir>
allure_generate() {
    local rdir="$1" odir="$2"
    if ! command -v allure >/dev/null 2>&1; then
        log_error "未找到 allure CLI，无法生成 allure-report（镜像应预装 allure + JRE）"
        return 1
    fi
    allure generate "$rdir" -o "$odir" --clean || {
        log_error "allure generate 失败: $rdir -> $odir"
        return 1
    }
    return 0
}

# allure_finalize <results.jsonl> <TEST_RESULT_DIR>
allure_finalize() {
    local results="$1" root="$2"
    local rdir="$root/allure-result" odir="$root/allure-report"
    allure_emit_results     "$results" "$rdir" || return 1
    allure_write_environment "$rdir"           || return 1
    allure_write_categories  "$rdir"           || return 1
    allure_generate          "$rdir" "$odir"   || return 1
    log_success "allure 报告已生成: $odir"
    return 0
}
```

- [ ] **Step 4: 运行单测确认通过**

```bash
bash framework/tests/allure_test.sh
```

预期：`失败: 0`。（`test_generate_missing_cli` 通过 `PATH=/nonexistent-bin` 验证缺 CLI 时返回 1。）

- [ ] **Step 5: 把 allure 后端接进 report_finalize**

在 `framework/report.sh` 的 Task 1 已插入的「可选加载 CASE_TYPE 过滤器」代码块之后，追加：

```bash
# ── 可选加载 allure 后端（lynx 层，缺失时不产 allure）──
if [ -f "${FRAMEWORK_ROOT:-}/lynx/allure.sh" ]; then
    # shellcheck disable=SC1090
    . "${FRAMEWORK_ROOT}/lynx/allure.sh"
fi
```

在 `report_finalize` 中，把这段：

```bash
    local summary
    summary="$(_report_aggregate "$results")"
    printf '%s\n' "$summary" > "$RUNME_TEST_RUN_DIR/summary.json"
    _report_write_junit "$summary" > "$RUNME_TEST_RUN_DIR/junit.xml"
```

替换为：

```bash
    local summary
    summary="$(_report_aggregate "$results")"
    printf '%s\n' "$summary" > "$RUNME_TEST_RUN_DIR/summary.json"
    _report_write_junit "$summary" > "$RUNME_TEST_RUN_DIR/junit.xml"

    # allure 报告：仅 TEST_RESULT_DIR 非空时生成（即镜像 / lynx 场景）。
    # 生成失败属于框架级失败，必须非 0 退出，否则 lynx 只会拿到一份空报告。
    if [ -n "${TEST_RESULT_DIR:-}" ] && declare -F allure_finalize >/dev/null 2>&1; then
        if ! allure_finalize "$results" "$TEST_RESULT_DIR"; then
            log_error "allure 报告生成失败"
            __REPORT_FINALIZE_RC=1
            return 1
        fi
    fi
```

再把结尾的返回码判定：

```bash
    if [ "$result" = "failed" ]; then __REPORT_FINALIZE_RC=1; return 1; fi
    __REPORT_FINALIZE_RC=0
    return 0
```

替换为：

```bash
    if [ "$result" = "failed" ]; then
        # EXIT_ON_TEST_FAILURE=false（lynx 场景）：用例失败不改变退出码，
        # 结果完全由 allure 报告承载，避免 lynx 把「测试有失败」误判成「任务 Error」。
        # 框架级失败（上面的 allure 生成失败等）不受此开关影响，始终非 0。
        if [ "${EXIT_ON_TEST_FAILURE:-true}" = "false" ]; then
            log_warn "存在失败用例，但 EXIT_ON_TEST_FAILURE=false，按成功退出（结果以 allure 报告为准）"
            __REPORT_FINALIZE_RC=0
            return 0
        fi
        __REPORT_FINALIZE_RC=1
        return 1
    fi
    __REPORT_FINALIZE_RC=0
    return 0
```

- [ ] **Step 6: 在 report_test.sh 补 EXIT_ON_TEST_FAILURE 回归**

在 `framework/tests/report_test.sh` 的 `test_finalize_exit` 之后插入：

```bash
# ── 测试：EXIT_ON_TEST_FAILURE=false 时失败不改退出码 ──
test_exit_on_test_failure() {
    printf '\n== EXIT_ON_TEST_FAILURE ==\n'
    new_sandbox
    report_record_doctest mesh kiali runme-test_kiali.sh test failed "" "pod 未就绪" 100 160
    local rc=0
    EXIT_ON_TEST_FAILURE=false TEST_RESULT_DIR="" report_finalize >/dev/null 2>&1 || rc=$?
    check_eq "false 时退出码 0" "$rc" "0"
    rm -rf "$RUNME_TEST_RUN_DIR"

    new_sandbox
    report_record_doctest mesh kiali runme-test_kiali.sh test failed "" "pod 未就绪" 100 160
    rc=0
    EXIT_ON_TEST_FAILURE=true TEST_RESULT_DIR="" report_finalize >/dev/null 2>&1 || rc=$?
    check_eq "true 时退出码 1" "$rc" "1"
    rm -rf "$RUNME_TEST_RUN_DIR"
}
```

在 `main()` 中 `test_finalize_exit` 之后加入 `test_exit_on_test_failure`。

- [ ] **Step 7: 运行两个单测确认通过**

```bash
bash framework/tests/allure_test.sh && bash framework/tests/report_test.sh
```

预期：两个都 `失败: 0`。

- [ ] **Step 8: 提交**

```bash
git add lynx/allure.sh framework/tests/allure_test.sh framework/report.sh framework/tests/report_test.sh
git commit -m "feat: allure 报告后端

- 新增 lynx/allure.sh：DocTest 为用例粒度，Case 作为 suite，标签含 case_id/tag
- environment.properties 只写非敏感信息；categories.json 区分 env/expected 跳过
- report_finalize 在 TEST_RESULT_DIR 非空时产 allure，生成失败即框架级失败
- 新增 EXIT_ON_TEST_FAILURE：false 时用例失败不改变退出码"
```

---

### Task 4: 离线资产层（URL → 镜像内预置文件）

**Files:**
- Create: `framework/assets.sh`
- Create: `lynx/assets-manifest.tsv`
- Create: `lynx/check-manifest.sh`
- Create: `framework/tests/assets_test.sh`
- Modify: `run.sh`（第 23 行之后加载 `assets.sh`）
- Modify: `projects/mesh/project.sh`（`kubectl_apply_with_mirror`）
- Modify: `.gitignore`（忽略 `assets/`）

**Interfaces:**
- Consumes: 无
- Produces:
  - `asset_local_path <url>` → 命中且文件存在时输出本地绝对路径，否则输出空串（返回码恒 0）
  - `fetch_url_content <url>` → 命中本地则 `cat`，否则 `curl -fsSL`
  - `rewrite_urls_to_assets <cmd-string>` → 把命令串里命中清单的 URL 替换为本地路径
  - `runme_run_with_assets <block-name>` → `runme print` 取内容 → 替换 URL → `eval`
  - `lynx/assets-manifest.tsv`：两列 TSV，`<url><TAB><相对 assets/ 的路径>`，17 行

- [ ] **Step 1: 写失败的单测**

创建 `framework/tests/assets_test.sh`：

```bash
#!/usr/bin/env bash
# framework/assets.sh 单元测试（纯 bash，不联网、不依赖集群）
# 用法: bash framework/tests/assets_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/assets.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_contains() {
    if __cmp_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 造一个沙箱清单 + 预置文件
setup_sandbox() {
    SANDBOX="$(mktemp -d)"
    printf 'https://example.com/a/b.yaml\texample.com/a/b.yaml\n' >  "$SANDBOX/manifest.tsv"
    printf 'https://example.com/missing.yaml\texample.com/missing.yaml\n' >> "$SANDBOX/manifest.tsv"
    mkdir -p "$SANDBOX/assets/example.com/a"
    printf 'kind: ConfigMap\n' > "$SANDBOX/assets/example.com/a/b.yaml"
    ASSETS_MANIFEST="$SANDBOX/manifest.tsv"
    ASSETS_DIR="$SANDBOX/assets"
}

test_local_path() {
    printf '\n== asset_local_path ==\n'
    setup_sandbox
    check_eq "命中且文件存在" "$(asset_local_path 'https://example.com/a/b.yaml')" "$SANDBOX/assets/example.com/a/b.yaml"
    check_eq "命中但文件缺失→空" "$(asset_local_path 'https://example.com/missing.yaml')" ""
    check_eq "未登记→空"          "$(asset_local_path 'https://example.com/other.yaml')" ""
    rm -rf "$SANDBOX"
}

test_fetch_content() {
    printf '\n== fetch_url_content ==\n'
    setup_sandbox
    check_eq "命中读本地文件" "$(fetch_url_content 'https://example.com/a/b.yaml' 2>/dev/null)" "kind: ConfigMap"
    rm -rf "$SANDBOX"
}

test_rewrite() {
    printf '\n== rewrite_urls_to_assets ==\n'
    setup_sandbox
    local out
    out="$(rewrite_urls_to_assets 'kubectl -n ns apply -f https://example.com/a/b.yaml')"
    check_eq "URL 换成本地路径" "$out" "kubectl -n ns apply -f $SANDBOX/assets/example.com/a/b.yaml"
    out="$(rewrite_urls_to_assets 'kubectl apply -f https://example.com/other.yaml')"
    check_contains "未登记的 URL 保持原样" "$out" "https://example.com/other.yaml"
    rm -rf "$SANDBOX"
}

test_runme_run_with_assets() {
    printf '\n== runme_run_with_assets ==\n'
    setup_sandbox
    # 伪造 runme：print 时回显一条会把文件内容打出来的命令
    local stub; stub="$(mktemp -d)"
    cat > "$stub/runme" <<EOF
#!/usr/bin/env bash
[ "\$1" = "print" ] || exit 1
echo "cat https://example.com/a/b.yaml"
EOF
    chmod +x "$stub/runme"
    local out
    out="$(PATH="$stub:$PATH" runme_run_with_assets fake:block 2>/dev/null)"
    check_eq "替换后 eval 读到本地内容" "$out" "kind: ConfigMap"
    rm -rf "$stub" "$SANDBOX"
}

test_manifest_wellformed() {
    printf '\n== lynx/assets-manifest.tsv 格式 ==\n'
    local f="$FRAMEWORK_ROOT/lynx/assets-manifest.tsv"
    check_eq "清单存在" "$([ -f "$f" ] && echo yes || echo no)" "yes"
    check_eq "17 条记录" "$(grep -cE '^https?://' "$f")" "17"
    check_eq "每行恰好两列" "$(awk -F'\t' '/^https?:\/\// && NF != 2 {c++} END {print c+0}' "$f")" "0"
    check_eq "路径无重复"   "$(awk -F'\t' '/^https?:\/\//{print $2}' "$f" | sort | uniq -d | wc -l | tr -d ' ')" "0"
    check_eq "URL 无重复"   "$(awk -F'\t' '/^https?:\/\//{print $1}' "$f" | sort | uniq -d | wc -l | tr -d ' ')" "0"
}

main() {
    test_local_path
    test_fetch_content
    test_rewrite
    test_runme_run_with_assets
    test_manifest_wellformed
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
```

- [ ] **Step 2: 运行单测确认失败**

```bash
bash framework/tests/assets_test.sh
```

预期：`.../framework/assets.sh: No such file or directory`。

- [ ] **Step 3: 实现 `framework/assets.sh`**

```bash
#!/usr/bin/env bash
# 离线资产：把文档中引用的外部 URL 解析到镜像内预置文件
#
# 背景：mesh 文档有 46 处 `-f <外部 URL>` 的代码块（17 个去重 URL），运行时要在
# 测试机侧 curl 才能拿到 sample YAML。dailybuild 环境访问不了公网，故构建期把这些
# 文件下载进镜像，运行时按清单改走本地。
#
# 清单: lynx/assets-manifest.tsv，两列 TAB 分隔：<url> <相对 assets/ 的路径>
# 预置目录: $FRAMEWORK_ROOT/assets/
#
# 未命中清单的 URL 一律回退联网 curl，保证本地开发场景行为不变。

ASSETS_MANIFEST="${ASSETS_MANIFEST:-${FRAMEWORK_ROOT:-.}/lynx/assets-manifest.tsv}"
ASSETS_DIR="${ASSETS_DIR:-${FRAMEWORK_ROOT:-.}/assets}"

# 查询 URL 对应的本地文件路径。命中清单且文件真实存在才输出，否则输出空串。
# 返回码恒为 0——「没有预置」是正常情况，不是错误。
# 用法: p=$(asset_local_path <url>)
asset_local_path() {
    local url="$1" rel
    [ -f "$ASSETS_MANIFEST" ] || return 0
    rel=$(awk -F'\t' -v u="$url" '$1 == u {print $2; exit}' "$ASSETS_MANIFEST")
    [ -n "$rel" ] || return 0
    [ -f "$ASSETS_DIR/$rel" ] || return 0
    printf '%s' "$ASSETS_DIR/$rel"
}

# 取 URL 内容：命中本地预置则 cat，否则 curl。
# 提示信息走 stderr，保证 stdout 只有文件内容（调用方常用命令替换捕获）。
fetch_url_content() {
    local url="$1" local_path
    local_path=$(asset_local_path "$url")
    if [ -n "$local_path" ]; then
        log_info "使用预置资产: $url -> $local_path" >&2
        cat "$local_path"
        return $?
    fi
    curl -fsSL "$url"
}

# 把命令串里命中清单的 URL 替换为本地文件路径（未命中的原样保留）
# 用法: cmd=$(rewrite_urls_to_assets "$cmd")
rewrite_urls_to_assets() {
    local cmd="$1" url local_path
    # 用 while-read 而非 mapfile，兼容 macOS 自带的 Bash 3.2
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        local_path=$(asset_local_path "$url")
        [ -n "$local_path" ] || continue
        cmd="${cmd//$url/$local_path}"
    done < <(printf '%s' "$cmd" | grep -oE 'https?://[^[:space:]"'"'"']+' | sort -u)
    printf '%s' "$cmd"
}

# 执行 runme 代码块，先把其中的外部 URL 换成预置资产
# 用法: runme_run_with_assets <block-name>
# 说明: 用于那些直接 `runme run` 执行 `kubectl apply -f <url>` 的块。走
#       kubectl_apply_with_mirror 的块不需要改调用方——该函数内部已改用
#       fetch_url_content。
runme_run_with_assets() {
    local block="$1" content
    content=$(runme print "$block" 2>/dev/null)
    if [ -z "$content" ]; then
        log_error "无法获取代码块内容: $block"
        return 1
    fi
    content=$(rewrite_urls_to_assets "$content")
    eval "$content"
}
```

- [ ] **Step 4: 写 `lynx/assets-manifest.tsv`**

分隔符必须是真实 TAB。内容如下（第一列 URL、第二列本地相对路径）：

```
# 离线资产清单：<url><TAB><相对 assets/ 的路径>
# 由 Dockerfile 在构建期逐条 curl 落盘；lynx/check-manifest.sh 校验文档中的
# `-f <url>` 是否都已登记。新增/变更文档 URL 时必须同步本文件。
https://raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/sleep/sleep.yaml	raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/sleep/sleep.yaml
https://raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/tcp-echo/tcp-echo-dual-stack.yaml	raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/tcp-echo/tcp-echo-dual-stack.yaml
https://raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/tcp-echo/tcp-echo-ipv4.yaml	raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/tcp-echo/tcp-echo-ipv4.yaml
https://raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/tcp-echo/tcp-echo-ipv6.yaml	raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/tcp-echo/tcp-echo-ipv6.yaml
https://raw.githubusercontent.com/alauda-mesh/istio/refs/heads/istio-1.30/samples/bookinfo/gateway-api/bookinfo-gateway.yaml	raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/bookinfo/gateway-api/bookinfo-gateway.yaml
https://raw.githubusercontent.com/alauda-mesh/istio/refs/heads/istio-1.30/samples/bookinfo/networking/bookinfo-gateway.yaml	raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/bookinfo/networking/bookinfo-gateway.yaml
https://raw.githubusercontent.com/alauda-mesh/istio/refs/heads/istio-1.30/samples/bookinfo/platform/kube/bookinfo-versions.yaml	raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/bookinfo/platform/kube/bookinfo-versions.yaml
https://raw.githubusercontent.com/alauda-mesh/istio/refs/heads/istio-1.30/samples/bookinfo/platform/kube/bookinfo.yaml	raw.githubusercontent.com/alauda-mesh/istio/istio-1.30/samples/bookinfo/platform/kube/bookinfo.yaml
https://raw.githubusercontent.com/alauda-mesh/sail-operator/refs/heads/release-2.2/chart/samples/ingress-gateway.yaml	raw.githubusercontent.com/alauda-mesh/sail-operator/release-2.2/chart/samples/ingress-gateway.yaml
https://raw.githubusercontent.com/alauda-mesh/sail-operator/release-2.2/docs/deployment-models/resources/east-west-gateway-net1.yaml	raw.githubusercontent.com/alauda-mesh/sail-operator/release-2.2/docs/deployment-models/resources/east-west-gateway-net1.yaml
https://raw.githubusercontent.com/alauda-mesh/sail-operator/release-2.2/docs/deployment-models/resources/east-west-gateway-net2.yaml	raw.githubusercontent.com/alauda-mesh/sail-operator/release-2.2/docs/deployment-models/resources/east-west-gateway-net2.yaml
https://raw.githubusercontent.com/alauda-mesh/sail-operator/release-2.2/docs/deployment-models/resources/expose-istiod.yaml	raw.githubusercontent.com/alauda-mesh/sail-operator/release-2.2/docs/deployment-models/resources/expose-istiod.yaml
https://raw.githubusercontent.com/alauda-mesh/sail-operator/release-2.2/docs/deployment-models/resources/expose-services.yaml	raw.githubusercontent.com/alauda-mesh/sail-operator/release-2.2/docs/deployment-models/resources/expose-services.yaml
https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.30/samples/curl/curl.yaml	raw.githubusercontent.com/istio/istio/release-1.30/samples/curl/curl.yaml
https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.30/samples/helloworld/helloworld.yaml	raw.githubusercontent.com/istio/istio/release-1.30/samples/helloworld/helloworld.yaml
https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.30/samples/httpbin/httpbin.yaml	raw.githubusercontent.com/istio/istio/release-1.30/samples/httpbin/httpbin.yaml
https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.30/samples/sleep/sleep.yaml	raw.githubusercontent.com/istio/istio/release-1.30/samples/sleep/sleep.yaml
```

写完后校验分隔符确实是 TAB：

```bash
awk -F'\t' '/^https?:\/\// && NF != 2 {print "非 TAB 分隔: " NR}' lynx/assets-manifest.tsv
```

预期：无输出。

- [ ] **Step 5: 实现 `lynx/check-manifest.sh`**

```bash
#!/usr/bin/env bash
# 校验：文档命名代码块里的每一个 `-f <外部 URL>` 都已登记进 lynx/assets-manifest.tsv
#
# 挂在镜像构建流水线上。文档改了 URL 而清单没跟上时，镜像里就会缺资产，
# 离线环境跑到一半才炸——这里提前拦住。
#
# 用法: bash lynx/check-manifest.sh [<doc-repo-root>...]
#       不带参数时按 repos.conf 遍历所有已注册的文档仓库。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$FRAMEWORK_ROOT/lynx/assets-manifest.tsv"

if [ ! -f "$MANIFEST" ]; then
    printf '错误: 找不到清单 %s\n' "$MANIFEST" >&2
    exit 1
fi

# 收集待扫描的文档仓库
repos=()
if [ $# -gt 0 ]; then
    repos=("$@")
else
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [ -n "$line" ] || continue
        path="${line#*:}"
        case "$path" in
            /*) resolved="$path" ;;
            *)  resolved="$FRAMEWORK_ROOT/$path" ;;
        esac
        [ -d "$resolved" ] && repos+=("$resolved")
    done < "$FRAMEWORK_ROOT/repos.conf"
fi

if [ ${#repos[@]} -eq 0 ]; then
    printf '错误: 没有可扫描的文档仓库\n' >&2
    exit 1
fi

# 提取命名代码块内 `-f <url>` 形式的 URL
extract_urls() {
    local repo="$1"
    [ -d "$repo/docs" ] || return 0
    find "$repo/docs" -name '*.mdx' -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
        awk '
            /^[[:space:]]*```/ {
                if (inblock) { inblock = 0 }
                else if ($0 ~ /\{name=/) { inblock = 1 }
                next
            }
            inblock {
                s = $0
                while (match(s, /-f[[:space:]]+https?:\/\/[^[:space:]"'"'"']+/)) {
                    u = substr(s, RSTART, RLENGTH)
                    sub(/^-f[[:space:]]+/, "", u)
                    print u
                    s = substr(s, RSTART + RLENGTH)
                }
            }
        ' "$f"
    done
}

tmp_found="$(mktemp)"
tmp_known="$(mktemp)"
trap 'rm -f "$tmp_found" "$tmp_known"' EXIT

for repo in "${repos[@]}"; do
    extract_urls "$repo"
done | sort -u > "$tmp_found"

awk -F'\t' '/^https?:\/\//{print $1}' "$MANIFEST" | sort -u > "$tmp_known"

missing="$(comm -23 "$tmp_found" "$tmp_known")"
stale="$(comm -13 "$tmp_found" "$tmp_known")"

rc=0
if [ -n "$missing" ]; then
    printf '错误: 以下文档 URL 未登记进 %s：\n' "$MANIFEST" >&2
    printf '%s\n' "$missing" | sed 's/^/  - /' >&2
    rc=1
fi
if [ -n "$stale" ]; then
    printf '警告: 清单中以下 URL 已不再被任何文档引用（可清理）：\n' >&2
    printf '%s\n' "$stale" | sed 's/^/  - /' >&2
fi
if [ "$rc" -eq 0 ]; then
    printf '资产清单校验通过：%d 个 URL 全部已登记\n' "$(wc -l < "$tmp_found" | tr -d ' ')"
fi
exit "$rc"
```

- [ ] **Step 6: 在 run.sh 加载 assets.sh，并让 kubectl_apply_with_mirror 走预置资产**

在 `run.sh` 第 23 行 `source "$FRAMEWORK_DIR/tools.sh"` 之后加一行：

```bash
source "$FRAMEWORK_DIR/assets.sh"
```

把 `projects/mesh/project.sh` 的 `kubectl_apply_with_mirror` 中这两段改掉。

其一，无镜像替换策略时的直通分支（原第 59-63 行）：

```bash
    else
        # 没有镜像替换策略，直接执行原命令（仍把外部 URL 换成预置资产）
        eval "$(rewrite_urls_to_assets "$cmd_content")"
        return $?
    fi
```

其二，下载并改写镜像的分支（原第 74-79 行）：

```bash
    # 取 YAML 内容（命中预置资产则读本地，否则联网 curl），替换镜像地址后应用
    log_info "下载并替换镜像地址: $url"
    fetch_url_content "$url" \
        | sed "s|docker\.io|${docker_io_target}|g" \
        | sed "s|registry\.istio\.io/release|${istio_release_target}|g" \
        | eval "${cmd_content//-f $url/-f -}"
```

同时把函数头部注释里的「下载 YAML 并改写镜像后再 kubectl apply」补一句：

```bash
#   - YAML 内容经 framework/assets.sh 的 fetch_url_content 获取：命中 lynx/assets-manifest.tsv
#     的预置资产时读镜像内本地文件（离线环境必需），否则回退联网 curl。
```

- [ ] **Step 7: .gitignore 忽略预置资产目录**

在 `.gitignore` 的 `tmp/` 之后加：

```
assets/
```

- [ ] **Step 8: 运行单测与清单校验**

```bash
bash framework/tests/assets_test.sh
bash lynx/check-manifest.sh
```

预期：单测 `失败: 0`；清单校验输出 `资产清单校验通过：17 个 URL 全部已登记`。

- [ ] **Step 9: 提交**

```bash
git add framework/assets.sh framework/tests/assets_test.sh lynx/assets-manifest.tsv lynx/check-manifest.sh run.sh projects/mesh/project.sh .gitignore
git commit -m "feat: 离线资产层，外部 sample YAML 改走镜像内预置

- 新增 framework/assets.sh：asset_local_path / fetch_url_content /
  rewrite_urls_to_assets / runme_run_with_assets，未命中清单时回退联网
- 新增 lynx/assets-manifest.tsv（17 个去重 URL）与 check-manifest.sh 校验脚本
- kubectl_apply_with_mirror 两条分支均改走预置资产"
```

---

### Task 5: servicemesh2-docs 的 9 处直接 runme run 改走预置资产

**Files:**
- Modify: `<servicemesh2-docs>/docs/en/installing/ambient-mode/runme-test_ambient-l7-features.sh:178`
- Modify: `<servicemesh2-docs>/docs/en/installing/multi-cluster/runme-test_install-multi-primary-multi-network.sh:85,93,117,124`
- Modify: `<servicemesh2-docs>/docs/en/installing/multi-cluster/runme-test_install-primary-remote-multi-network.sh:113,120,125,168`

**Interfaces:**
- Consumes: `runme_run_with_assets <block-name>`（Task 4）
- Produces: 无新接口

> 背景：46 个含外部 `-f URL` 的代码块中，37 个走 `kubectl_apply_with_mirror`（Task 4 已一次性修好），剩下 9 个是测试脚本直接 `runme run`，必须逐个替换。其中 `ambient-l7-features:cleanup-authorization-policy` 属于首批范围（mesh Case 5），其余 8 个属于多集群 Case 6/7。

- [ ] **Step 1: 确认改前的调用点**

```bash
cd ../servicemesh2-docs
grep -rn "runme run ambient-l7-features:cleanup-authorization-policy\|runme run multi-primary-multi-network:create-eastwest-gw-\|runme run multi-primary-multi-network:expose-services-\|runme run primary-remote-multi-network:create-eastwest-gw-\|runme run primary-remote-multi-network:expose-istiod-east\|runme run primary-remote-multi-network:expose-services-east" docs/en --include=*.sh
```

预期：正好 9 行命中，分布在上面列出的 3 个文件里。

- [ ] **Step 2: 逐个替换为 runme_run_with_assets**

对上一步列出的 9 行，把 `runme run <block>` 改成 `runme_run_with_assets <block>`，其余部分（`|| { ... }` 错误处理块）保持不变。可以用一条精确的替换命令完成：

```bash
cd ../servicemesh2-docs
for b in \
  ambient-l7-features:cleanup-authorization-policy \
  multi-primary-multi-network:create-eastwest-gw-east \
  multi-primary-multi-network:create-eastwest-gw-west \
  multi-primary-multi-network:expose-services-east \
  multi-primary-multi-network:expose-services-west \
  primary-remote-multi-network:create-eastwest-gw-east \
  primary-remote-multi-network:create-eastwest-gw-west \
  primary-remote-multi-network:expose-istiod-east \
  primary-remote-multi-network:expose-services-east ; do
  grep -rl "runme run $b" docs/en --include=*.sh | while read -r f; do
    # 用临时文件替换，避免依赖 GNU sed 的 -i（BSD sed 的 -i 需紧跟备份后缀）
    sed "s|runme run $b|runme_run_with_assets $b|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
done
```

- [ ] **Step 3: 验证替换结果**

```bash
cd ../servicemesh2-docs
echo "剩余 runme run（应为 0 行）:"
grep -rn "runme run ambient-l7-features:cleanup-authorization-policy\|runme run multi-primary-multi-network:create-eastwest-gw-\|runme run multi-primary-multi-network:expose-services-\|runme run primary-remote-multi-network:create-eastwest-gw-\|runme run primary-remote-multi-network:expose-istiod-east\|runme run primary-remote-multi-network:expose-services-east" docs/en --include=*.sh | wc -l
echo "新的 runme_run_with_assets（应为 9 行）:"
grep -rn "runme_run_with_assets" docs/en --include=*.sh | wc -l
echo "语法检查:"
for f in docs/en/installing/ambient-mode/runme-test_ambient-l7-features.sh \
         docs/en/installing/multi-cluster/runme-test_install-multi-primary-multi-network.sh \
         docs/en/installing/multi-cluster/runme-test_install-primary-remote-multi-network.sh; do
  bash -n "$f" && echo "  OK $f"
done
```

预期：第一个 `0`，第二个 `9`，三个文件都输出 `OK`。

- [ ] **Step 4: 在 docs-runme-tests 侧确认无遗漏**

```bash
cd ../docs-runme-tests
bash lynx/check-manifest.sh
```

预期：`资产清单校验通过：17 个 URL 全部已登记`。

- [ ] **Step 5: 提交（在 servicemesh2-docs 仓库）**

```bash
cd ../servicemesh2-docs
git checkout -b feat/dailybuild-lynx-integration
git add docs/en/installing/ambient-mode/runme-test_ambient-l7-features.sh \
        docs/en/installing/multi-cluster/runme-test_install-multi-primary-multi-network.sh \
        docs/en/installing/multi-cluster/runme-test_install-primary-remote-multi-network.sh
git commit -m "test: 直接执行外部 URL 的代码块改走预置资产

9 处 runme run 改为 runme_run_with_assets，使离线环境下从镜像内
预置的 sample YAML 读取内容；未命中清单时仍回退联网 curl。"
cd ../docs-runme-tests
```

---

### Task 6: 插件包 verify-only 模式

**Files:**
- Modify: `framework/tools.sh`（`download_package` / `upload_package` 空值守卫）
- Modify: `framework/common.sh`（`install_operator` 的 CSV 名解析；`install_cluster_plugin` 的上架分支）
- Modify: `projects/mesh/project.sh`（`upload_all_packages`、`project_check_env`）
- Modify: `projects/otel/project.sh`（`project_check_env`、`project_init`）
- Modify: `projects/tracing/project.sh`（`project_check_env`、`project_init`）
- Modify: `projects/tracing/jaeger-plugin.sh`（上架分支守卫）
- Create: `framework/tests/verify_only_test.sh`
- Modify: `README.md`（环境变量章节）

**Interfaces:**
- Consumes: 无
- Produces:
  - `_operator_csv_from_packagemanifest <operator_name>` → 从 PackageManifest 的 defaultChannel 解析 `currentCSV`，失败返回 1
  - `install_operator <operator_name> <namespace> <package_url|""> <runme_prefix>` → `package_url` 为空即 verify-only
  - `install_cluster_plugin <module_name> <target_cluster> <package_url|""> [prereq_url...]` → 同上
  - `download_package` / `upload_package`：URL 为空时 `log_error` 并返回 1

- [ ] **Step 1: 写失败的单测**

创建 `framework/tests/verify_only_test.sh`：

```bash
#!/usr/bin/env bash
# 插件包 verify-only 模式单元测试（伪造 kubectl，不依赖集群）
# 用法: bash framework/tests/verify_only_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/tools.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_contains() {
    if __cmp_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 伪造 kubectl：只回答 `get packagemanifest <name> -o json`
make_kubectl_stub() {
    STUB="$(mktemp -d)"
    cat > "$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "get" ] && [ "$2" = "packagemanifest" ]; then
    if [ "$3" != "servicemesh-operator2" ]; then exit 1; fi
    if [ "${4:-}" = "-o" ] && [ "${5:-}" = "json" ]; then
        cat <<'JSON'
{"status":{"defaultChannel":"stable","catalogSource":"platform","catalogSourceNamespace":"cpaas-system",
"channels":[{"name":"stable","currentCSV":"servicemesh-operator2.v2.2.0"},
            {"name":"stable-2.1","currentCSV":"servicemesh-operator2.v2.1.0"}]}}
JSON
    fi
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB/kubectl"
}

test_download_upload_guard() {
    printf '\n== download_package / upload_package 空值守卫 ==\n'
    local out rc
    out="$(download_package "" 2>&1)"; rc=$?
    check_eq "download 空 URL 返回 1" "$rc" "1"
    check_contains "download 报错含提示" "$out" "插件包地址为空"

    out="$(upload_package "some-cluster" "" 2>&1)"; rc=$?
    check_eq "upload 空 URL 返回 1" "$rc" "1"
    check_contains "upload 报错含提示" "$out" "插件包地址为空"
}

test_csv_from_packagemanifest() {
    printf '\n== _operator_csv_from_packagemanifest ==\n'
    make_kubectl_stub
    local out rc
    out="$(PATH="$STUB:$PATH" _operator_csv_from_packagemanifest servicemesh-operator2 2>/dev/null)"; rc=$?
    check_eq "解析 defaultChannel 的 currentCSV" "$out" "servicemesh-operator2.v2.2.0"
    check_eq "成功返回 0" "$rc" "0"

    rc=0
    PATH="$STUB:$PATH" _operator_csv_from_packagemanifest nonexistent-operator >/dev/null 2>&1 || rc=$?
    check_eq "PackageManifest 不存在返回 1" "$rc" "1"
    rm -rf "$STUB"
}

test_parse_csv_still_works() {
    printf '\n== parse_csv_name_from_package 回归 ==\n'
    check_eq "有 URL 时按包名解析" \
        "$(parse_csv_name_from_package 'http://x/servicemesh-operator2.stable.ALL.v2.1.0.tgz')" \
        "servicemesh-operator2.v2.1.0"
    check_eq "空 URL 解析为空" "$(parse_csv_name_from_package '')" ""
}

main() {
    test_download_upload_guard
    test_csv_from_packagemanifest
    test_parse_csv_still_works
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
```

- [ ] **Step 2: 运行单测确认失败**

```bash
bash framework/tests/verify_only_test.sh
```

预期：`download 空 URL 返回 1` 与 `_operator_csv_from_packagemanifest` 相关断言失败（当前 `download_package ""` 会 curl 空地址、`_operator_csv_from_packagemanifest` 未定义）。

- [ ] **Step 3: 给 download_package / upload_package 加空值守卫**

在 `framework/tools.sh` 的 `download_package` 开头（`local filename` 之前）插入：

```bash
    if [ -z "$url" ]; then
        log_error "download_package: 插件包地址为空（verify-only 模式下不应调用本函数）"
        return 1
    fi
```

在 `upload_package` 开头（`local filename` 之前）插入：

```bash
    if [ -z "$package_url" ]; then
        log_error "upload_package: 插件包地址为空（verify-only 模式下不应调用本函数）"
        return 1
    fi
```

- [ ] **Step 4: 新增 `_operator_csv_from_packagemanifest` 并改造 install_operator**

在 `framework/common.sh` 的 `_operator_reentry_probe` 函数之后插入：

```bash
# verify-only 模式下从 PackageManifest 反查目标 CSV 名（不依赖插件包 URL）
# 用法: csv=$(_operator_csv_from_packagemanifest <operator_name>) || return 1
# NOTE: 依赖调用方已切换到正确的 kubectl context
_operator_csv_from_packagemanifest() {
    local operator_name="$1" pm_json csv
    pm_json=$(kubectl get packagemanifest "$operator_name" -o json 2>/dev/null) || return 1
    [ -n "$pm_json" ] || return 1
    csv=$(printf '%s' "$pm_json" | jq -r '
        .status as $s | $s.channels[]? | select(.name == $s.defaultChannel) | .currentCSV // empty')
    [ -n "$csv" ] || return 1
    printf '%s' "$csv"
}
```

在 `install_operator` 中，把参数校验与 `csv_name` 推导两段改成：

```bash
    # 参数校验（package_url 允许为空 —— 空即 verify-only：包由平台预上架）
    if [ -z "$operator_name" ] || [ -z "$namespace" ] || [ -z "$runme_prefix" ]; then
        log_error "install_operator: 缺少必要参数"
        log_error "用法: install_operator <operator_name> <namespace> <package_url|\"\"> <runme_prefix>"
        return 1
    fi

    log_info "=========================================="
    log_info "安装 $operator_name 到 namespace $namespace"
    log_info "=========================================="

    local csv_name
    if [ -n "$package_url" ]; then
        csv_name=$(parse_csv_name_from_package "$package_url")
    else
        # verify-only：包由 dailybuild 预上架，CSV 名从 PackageManifest 反查
        log_info "未提供插件包地址，进入 verify-only 模式：从 PackageManifest 解析 $operator_name"
        if ! retry_command "kubectl get packagemanifest $operator_name >/dev/null 2>&1" 20 5; then
            log_error "未找到 PackageManifest: $operator_name"
            log_error "verify-only 模式要求该插件已上架到当前集群。"
            log_error "- dailybuild：确认 release-config 的 Release YAML 已在 l5_plugin_packages 声明该包并指定该集群"
            log_error "- 本地：export 对应的 PKG_*_URL 让框架自行下载上架"
            return 1
        fi
        csv_name=$(_operator_csv_from_packagemanifest "$operator_name") || {
            log_error "无法从 PackageManifest $operator_name 解析 defaultChannel 的 currentCSV"
            return 1
        }
        log_success "verify-only 目标 CSV: $csv_name"
    fi
```

- [ ] **Step 5: 改造 install_cluster_plugin 的上架分支**

在 `framework/common.sh` 的 `install_cluster_plugin` 中，把参数校验改成允许空 URL：

```bash
    if [ -z "$module_name" ] || [ -z "$target_cluster" ]; then
        log_error "install_cluster_plugin: 缺少必要参数"
        log_error "用法: install_cluster_plugin <module_name> <target_cluster> <package_url|\"\"> [prereq_package_url...]"
        return 1
    fi
    shift 3
```

把「步骤 1: 上架插件包」整段（从 `log_info "步骤 1: 上架插件包"` 到前置包上架的 `done`）替换为：

```bash
    # 1. 上架插件包（每次未就绪时都执行，确保依赖就位；violet 对已存在的包/镜像会自动跳过）。
    #    package_url 为空即 verify-only：包由平台预上架，本函数只校验、不下载不上架。
    log_info "步骤 1: 上架插件包"
    local pkg
    if [ -n "$package_url" ]; then
        download_package "$package_url" || return 1
    fi
    for pkg in "$@"; do
        [ -n "$pkg" ] || continue
        download_package "$pkg" || return 1
    done

    # 主包：URL 可解析版本时按精确版本判断，不能被同插件的旧 ModuleConfig 误判为已上架。
    if [ -n "$package_version" ] && _cluster_plugin_version_published "$module_name" "$package_version"; then
        log_info "插件 $module_name 目标版本 $package_version 已上架（ModuleConfig 存在），跳过 push"
    elif [ -z "$package_version" ] && \
        kubectl get moduleconfigs -l "cpaas.io/module-name=${module_name}" -o name 2>/dev/null | grep -q .; then
        log_info "插件 $module_name 已上架（ModuleConfig 存在），跳过 push"
    elif [ -z "$package_url" ]; then
        log_error "集群插件 $module_name 未上架到 Global 集群 ${global_cluster}，且未提供插件包地址（verify-only 模式）"
        log_error "- dailybuild：确认 release-config 的 Release YAML 已声明该插件包并指定该集群"
        log_error "- 本地：export 对应的 PKG_*_URL 让框架自行下载上架"
        return 1
    else
        upload_package "$global_cluster" "$package_url" || return 1
    fi

    # 前置包：上架到目标业务集群（与其他 operator 一致，仅上架不安装、不创建 ModuleInfo）
    # verify-only 下前置包为空——若平台也没预上架，后续 ModuleInfo 会以依赖缺失报错。
    for pkg in "$@"; do
        [ -n "$pkg" ] || continue
        log_info "上架前置插件包到业务集群 $target_cluster (仅上架不安装): $(basename "$pkg")"
        upload_package "$target_cluster" "$pkg" || return 1
    done
```

- [ ] **Step 6: jaeger-plugin.sh 上架分支加守卫**

在 `projects/tracing/jaeger-plugin.sh` 的 `_tracing_jaeger_plugin_install_via_global` 中，把 else 分支：

```bash
    else
        log_info "上架插件包到 Global 集群: $(basename "$PKG_JAEGER_CLUSTER_PLUGIN_URL")"
```

改为：

```bash
    elif [ -z "${PKG_JAEGER_CLUSTER_PLUGIN_URL:-}" ]; then
        log_error "集群插件 $module_name 未上架到 Global 集群 ${global_cluster}，且未提供 PKG_JAEGER_CLUSTER_PLUGIN_URL（verify-only 模式）"
        log_error "- dailybuild：确认 release-config 的 Release YAML 已声明 Jaeger v2 集群插件包"
        log_error "- 本地：export PKG_JAEGER_CLUSTER_PLUGIN_URL=<包地址>"
        return 1
    else
        log_info "上架插件包到 Global 集群: $(basename "$PKG_JAEGER_CLUSTER_PLUGIN_URL")"
```

（第 69 行 `pkg_version=$(basename "$PKG_JAEGER_CLUSTER_PLUGIN_URL" | grep -oE ...)` 无需改动：URL 为空时 `pkg_version` 为空，函数自动回退取最高已发布版本。）

- [ ] **Step 7: 三个项目的 project_check_env 与 project_init 放宽**

`projects/mesh/project.sh` 的 `project_check_env` 整体替换为：

```bash
# 校验 mesh 项目专属环境变量
# 注：所有 PKG_*_URL 均为可选。为空即 verify-only —— 插件包由平台（dailybuild）预上架，
# 框架只校验不下载不上架；缺包时由 install_operator / install_cluster_plugin 给出
# 指向正确处置动作的报错。
project_check_env() {
    local optional=(
        "PKG_SERVICEMESH_OPERATOR2_URL"
        "PKG_KIALI_OPERATOR_URL"
        "PKG_OPENTELEMETRY_OPERATOR2_URL"
        "PKG_MULTUS_URL"
    )
    if [ "${ENABLE_METALLB:-false}" = "true" ]; then
        optional+=("PKG_METALLB_URL" "PKG_METALLB_OPERATOR_URL")
    fi
    if [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ]; then
        optional+=("PKG_MESH_V2_TEST_SUITE_URL")
    fi

    local missing=() var
    for var in "${optional[@]}"; do
        if [ -z "${!var}" ]; then
            missing+=("$var")
        fi
    done
    if [ ${#missing[@]} -ne 0 ]; then
        log_info "mesh 项目未提供以下插件包地址，对应插件进入 verify-only 模式（要求平台已预上架）: ${missing[*]}"
    fi
    return 0
}
```

`projects/mesh/project.sh` 的 `upload_all_packages` 中，把 packages 数组构造与空数组处理改成：

```bash
    # 注：metallb-operator 不在此无条件上传；它作为 MetalLB 集群插件的前置，
    # 仅 ENABLE_METALLB=true 时由 install_all_cluster_plugins 按需上架到 Global 集群。
    # 未提供地址的包跳过（verify-only：由平台预上架）。
    local packages=() u
    for u in "$PKG_SERVICEMESH_OPERATOR2_URL" "$PKG_KIALI_OPERATOR_URL" "$PKG_OPENTELEMETRY_OPERATOR2_URL"; do
        [ -n "$u" ] && packages+=("$u")
    done
    if [ ${#packages[@]} -eq 0 ]; then
        log_info "未提供任何 Operator 插件包地址，跳过上架（verify-only：由平台预上架）"
        return 0
    fi
```

`projects/otel/project.sh` 的 `project_check_env` 整体替换为：

```bash
# 校验 otel 项目专属环境变量
# 注：PKG_*_URL 为可选，为空即 verify-only（插件包由平台预上架）。
project_check_env() {
    if [ -z "$PKG_OPENTELEMETRY_OPERATOR2_URL" ]; then
        log_info "未提供 PKG_OPENTELEMETRY_OPERATOR2_URL，OTel Operator 进入 verify-only 模式（要求平台已预上架）"
    fi
    if [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ] && [ -z "$PKG_MESH_V2_TEST_SUITE_URL" ]; then
        log_info "未提供 PKG_MESH_V2_TEST_SUITE_URL，mesh-v2-test-suite 进入 verify-only 模式（要求平台已预上架）"
    fi
    return 0
}
```

`projects/otel/project.sh` 的 `project_init` 中，把下载上传段替换为：

```bash
    # 下载并上传 OTel Operator 插件包（install_operator 依赖其 PackageManifest 存在）。
    # 地址为空即 verify-only：跳过，由平台预上架。
    local cluster
    if [ -n "$PKG_OPENTELEMETRY_OPERATOR2_URL" ]; then
        download_package "$PKG_OPENTELEMETRY_OPERATOR2_URL" || return 1
        for cluster in "${clusters[@]}"; do
            if ! check_package_uploaded "$cluster" "$PKG_OPENTELEMETRY_OPERATOR2_URL"; then
                upload_package "$cluster" "$PKG_OPENTELEMETRY_OPERATOR2_URL" || return 1
            fi
        done
    else
        log_info "未提供 PKG_OPENTELEMETRY_OPERATOR2_URL，跳过上架（verify-only）"
    fi
```

`projects/tracing/project.sh` 的 `project_check_env` 里，把 `PKG_OPENTELEMETRY_OPERATOR2_URL` 与 `PKG_JAEGER_CLUSTER_PLUGIN_URL` 两段硬校验替换为：

```bash
    if [ -z "$PKG_OPENTELEMETRY_OPERATOR2_URL" ]; then
        log_info "未提供 PKG_OPENTELEMETRY_OPERATOR2_URL，OTel Operator 进入 verify-only 模式（要求平台已预上架）"
    fi
    if [ -z "$PKG_JAEGER_CLUSTER_PLUGIN_URL" ]; then
        log_info "未提供 PKG_JAEGER_CLUSTER_PLUGIN_URL，Jaeger v2 集群插件进入 verify-only 模式（要求平台已预上架）"
    fi
```

`projects/tracing/project.sh` 的 `project_init` 中，把下载上传段替换为与 otel 相同的写法（把 `otel` 字样换成 `tracing` 无需变，只是同一段逻辑）：

```bash
    # 下载并上传 OTel Operator 插件包（install_operator 依赖其 PackageManifest 存在）。
    # 地址为空即 verify-only：跳过，由平台预上架。
    local cluster
    if [ -n "$PKG_OPENTELEMETRY_OPERATOR2_URL" ]; then
        download_package "$PKG_OPENTELEMETRY_OPERATOR2_URL" || return 1
        for cluster in "${clusters[@]}"; do
            if ! check_package_uploaded "$cluster" "$PKG_OPENTELEMETRY_OPERATOR2_URL"; then
                upload_package "$cluster" "$PKG_OPENTELEMETRY_OPERATOR2_URL" || return 1
            fi
        done
    else
        log_info "未提供 PKG_OPENTELEMETRY_OPERATOR2_URL，跳过上架（verify-only）"
    fi
```

- [ ] **Step 8: 更新 README 的环境变量说明**

在 `README.md` 的「插件包地址」代码块之前插入一段：

```markdown
> **verify-only 模式**：所有 `PKG_*_URL` 均为**可选**。留空时框架不下载、不上架该插件包，
> 改为直接校验它是否已在集群上架（Operator 查 PackageManifest，集群插件查 ModuleConfig），
> 并从中反查目标版本。这正是 dailybuild 的用法——插件包由 lynx 依据 Release YAML 预上架，
> 测试 Pod 不需要访问 package-minio。本地手工跑则照旧提供地址，由框架自行下载上架。
```

并把「项目专属变量」表格中三行的「必需」列改为：

| 项目 | 必需 | 条件必需 / 软依赖 |
| --- | --- | --- |
| mesh | 无（`PKG_*_URL` 全部可选，留空即 verify-only） | 提供地址时按原逻辑下载上架；`ENABLE_METALLB=true` 时若也未预上架 metallb / metallb-operator，安装会报错 |
| otel | 无（同上） | `USE_MESH_V2_TEST_SUITE_PLUGIN=true` 时需 `PKG_MESH_V2_TEST_SUITE_URL` 或平台已预上架 |
| tracing | 无（同上） | ES / OpenSearch 存储后端配置同原表；Jaeger v2 集群插件需 `PKG_JAEGER_CLUSTER_PLUGIN_URL` 或平台已预上架 |

- [ ] **Step 9: 运行单测确认通过**

```bash
bash framework/tests/verify_only_test.sh
bash framework/tests/install_operator_test.sh
bash framework/tests/install_cluster_plugin_test.sh
bash framework/tests/mesh_project_test.sh
bash framework/tests/report_test.sh
bash framework/tests/acp_auth_test.sh
```

预期：六个单测全部 `失败: 0`（后五个是既有单测，用于确认改造没破坏原有行为）。

- [ ] **Step 10: 提交**

```bash
git add framework/tools.sh framework/common.sh framework/tests/verify_only_test.sh \
        projects/mesh/project.sh projects/otel/project.sh projects/tracing/project.sh \
        projects/tracing/jaeger-plugin.sh README.md
git commit -m "feat: 插件包 verify-only 模式

- PKG_*_URL 全部降为可选，为空即只校验不下载不上架
- install_operator 新增 _operator_csv_from_packagemanifest 反查 CSV 名
- install_cluster_plugin / jaeger-plugin 未上架且无地址时给出指向处置动作的报错
- download_package / upload_package 加空值守卫"
```

---

### Task 7: MetalLB 地址池所有权模型

**Files:**
- Modify: `framework/common.sh`（`_render_external_ip_pool` / `create_external_ip_pool` / `setup_external_ip_pools` / `teardown_external_ip_pools`，新增 `_external_ip_pool_owner`）
- Create: `framework/tests/ip_pool_test.sh`
- Modify: `README.md`（MetalLB 变量说明）

**Interfaces:**
- Consumes: 无
- Produces:
  - `_render_external_ip_pool <pool> <namespace> <owner> <addr>...` → 渲染带 `runme-test/owner=<owner>` 标签的 IPAddressPool + L2Advertisement
  - `create_external_ip_pool <cluster> <pool> <owner> <addr>...`
  - `_external_ip_pool_owner <cluster> <pool>` → 输出 owner 标签值；池不存在时输出空串
  - `setup_external_ip_pools <cluster>...` → 池已存在则复用（不再要求 `METALLB_EXTERNAL_ADDRESSES_JSON`）；新建时 owner 取 `${EXTERNAL_IP_POOL_OWNER:-doctest}`
  - `teardown_external_ip_pools <cluster>...` → 跳过 `owner=init` 的池

> 为什么要做：`setup_external_ip_pools` 由单篇测试脚本调用（`exposing-*` 三篇与
> `deploying-the-bookinfo-application`），而 lynx 的 `$GLOBAL_EXTERNAL_IPPOOL` 只给当前
> `region_name` 的 IP，一个 mesh 测试项拿不到第二个集群的 IP。改成「initials 每集群建一次池、
> 测试脚本复用」，本地手工跑（无 init 建池 → 读 JSON 创建 → 用完删除）行为完全不变。

- [ ] **Step 1: 写失败的单测**

创建 `framework/tests/ip_pool_test.sh`：

```bash
#!/usr/bin/env bash
# 外部 IP 地址池所有权模型单元测试（伪造 kubectl，不依赖集群）
# 用法: bash framework/tests/ip_pool_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_contains() {
    if __cmp_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

test_render_owner_label() {
    printf '\n== _render_external_ip_pool owner 标签 ==\n'
    local out
    out="$(_render_external_ip_pool mesh-v2 metallb-system init 192.168.1.10/32)"
    check_contains "IPAddressPool 带 owner 标签" "$out" "runme-test/owner: init"
    check_contains "地址逐行展开"                "$out" "- 192.168.1.10/32"
    check_eq "两个资源各一处 owner 标签" "$(printf '%s\n' "$out" | grep -c 'runme-test/owner: init')" "2"
    out="$(_render_external_ip_pool mesh-v2 metallb-system doctest 10.0.0.1/32)"
    check_contains "doctest owner" "$out" "runme-test/owner: doctest"
}

# 伪造 kubectl + kubeconfig 目录，让 _cluster_kubeconfig_path 能通过
setup_stub() {
    STUB="$(mktemp -d)"
    KUBECONFIG_DIR="$STUB/kc"
    mkdir -p "$KUBECONFIG_DIR"
    : > "$KUBECONFIG_DIR/c1.yaml"
    cat > "$STUB/kubectl" <<EOF
#!/usr/bin/env bash
# 仅回答 get ipaddresspool 的 owner 标签查询；POOL_OWNER 为空表示池不存在
for a in "\$@"; do
  if [ "\$a" = "ipaddresspool" ]; then
    if [ -z "\${POOL_OWNER:-}" ]; then exit 1; fi
    printf '%s' "\${POOL_OWNER}"
    exit 0
  fi
done
exit 0
EOF
    chmod +x "$STUB/kubectl"
    export KUBECONFIG_DIR
}

test_pool_owner_query() {
    printf '\n== _external_ip_pool_owner ==\n'
    setup_stub
    check_eq "池不存在→空串" "$(PATH="$STUB:$PATH" _external_ip_pool_owner c1 mesh-v2 2>/dev/null)" ""
    check_eq "读到 init"     "$(PATH="$STUB:$PATH" POOL_OWNER=init _external_ip_pool_owner c1 mesh-v2 2>/dev/null)" "init"
    rm -rf "$STUB"
}

test_teardown_skips_init() {
    printf '\n== teardown 跳过 owner=init ==\n'
    setup_stub
    local out
    out="$(PATH="$STUB:$PATH" POOL_OWNER=init ENABLE_METALLB=true teardown_external_ip_pools c1 2>&1)"
    check_contains "跳过 init 池" "$out" "跳过清理"
    out="$(PATH="$STUB:$PATH" POOL_OWNER=doctest ENABLE_METALLB=true teardown_external_ip_pools c1 2>&1)"
    check_contains "删除 doctest 池" "$out" "删除外部 IP 地址池"
    rm -rf "$STUB"
}

test_setup_reuses_existing() {
    printf '\n== setup 复用已存在的池（不要求 JSON）==\n'
    setup_stub
    local out rc=0
    # 关键：不设置 METALLB_EXTERNAL_ADDRESSES_JSON，池已存在时也应成功
    out="$(PATH="$STUB:$PATH" POOL_OWNER=init ENABLE_METALLB=true \
           METALLB_EXTERNAL_ADDRESSES_JSON="" setup_external_ip_pools c1 2>&1)" || rc=$?
    check_eq "复用路径返回 0" "$rc" "0"
    check_contains "日志说明复用" "$out" "直接复用"

    # 池不存在且没有 JSON 时必须报错
    rc=0
    out="$(PATH="$STUB:$PATH" ENABLE_METALLB=true \
           METALLB_EXTERNAL_ADDRESSES_JSON="" setup_external_ip_pools c1 2>&1)" || rc=$?
    check_eq "无池无 JSON 返回 1" "$rc" "1"
    check_contains "报错提示 JSON" "$out" "METALLB_EXTERNAL_ADDRESSES_JSON"

    # 门控关闭时直接返回 0
    rc=0
    PATH="$STUB:$PATH" ENABLE_METALLB=false setup_external_ip_pools c1 >/dev/null 2>&1 || rc=$?
    check_eq "ENABLE_METALLB=false 直接返回 0" "$rc" "0"
    rm -rf "$STUB"
}

main() {
    test_render_owner_label
    test_pool_owner_query
    test_teardown_skips_init
    test_setup_reuses_existing
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
```

- [ ] **Step 2: 运行单测确认失败**

```bash
bash framework/tests/ip_pool_test.sh
```

预期：`owner 标签`、`_external_ip_pool_owner`、`复用` 相关断言失败。

- [ ] **Step 3: 给渲染函数加 owner 标签**

在 `framework/common.sh` 中把 `_render_external_ip_pool` 整体替换为：

```bash
# 内联渲染 IPAddressPool + L2Advertisement
# 用法: _render_external_ip_pool <pool> <namespace> <owner> <addr...>
# 说明:
#   - owner 取 init 或 doctest，写入 label runme-test/owner：
#     init    —— lynx initials 每集群建一次，长期存在，测试结束不清理
#     doctest —— 单篇测试脚本自建自清
#   - spec.avoidBuggyIPs: true；L2Advertisement spec.nodeSelectors: null（按真实环境验证载荷）
#   - addresses 由地址参数逐行展开（CIDR，如 192.168.139.13/32）
_render_external_ip_pool() {
    local pool="$1" namespace="$2" owner="$3"
    shift 3
    local addresses=("$@")

    cat <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${pool}
  namespace: ${namespace}
  labels:
    runme-test/owner: ${owner}
spec:
  avoidBuggyIPs: true
  addresses:
EOF
    local addr
    for addr in "${addresses[@]}"; do
        printf '    - %s\n' "$addr"
    done
    cat <<EOF
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${pool}
  namespace: ${namespace}
  labels:
    runme-test/owner: ${owner}
spec:
  ipAddressPools:
    - ${pool}
  nodeSelectors: null
EOF
}
```

- [ ] **Step 4: create_external_ip_pool 接收 owner，并新增 owner 查询函数**

把 `create_external_ip_pool` 的头部与渲染调用改为：

```bash
# 在指定业务集群创建外部 IP 地址池（IPAddressPool + L2Advertisement）
# 用法: create_external_ip_pool <cluster> <pool> <owner> <addr...>
create_external_ip_pool() {
    local cluster="$1" pool="$2" owner="$3"
    shift 3
    local addresses=("$@")

    if [ -z "$cluster" ] || [ -z "$pool" ] || [ -z "$owner" ] || [ ${#addresses[@]} -eq 0 ]; then
        log_error "create_external_ip_pool: 缺少参数 (cluster=$cluster, pool=$pool, owner=$owner, addresses=${addresses[*]})"
        return 1
    fi

    local kc
    kc=$(_cluster_kubeconfig_path "$cluster") || return 1
    # 函数内 local export KUBECONFIG，返回后自动还原，不污染 merged.yaml 的 current-context
    local KUBECONFIG="$kc"
    export KUBECONFIG

    log_info "创建外部 IP 地址池 $pool 于集群 $cluster (owner=$owner, 地址: ${addresses[*]})"
    _render_external_ip_pool "$pool" "$METALLB_NAMESPACE" "$owner" "${addresses[@]}" | kubectl apply -f - || {
        log_error "创建外部 IP 地址池失败: $pool@$cluster"
        return 1
    }
    return 0
}
```

在 `create_external_ip_pool` 之后插入：

```bash
# 查询指定集群上外部 IP 地址池的 owner 标签
# 用法: owner=$(_external_ip_pool_owner <cluster> <pool>)
# 输出: 池不存在或无标签时输出空串；返回码恒为 0（「没有池」是正常情况）
_external_ip_pool_owner() {
    local cluster="$1" pool="$2" kc
    kc=$(_cluster_kubeconfig_path "$cluster") || return 0
    local KUBECONFIG="$kc"
    export KUBECONFIG
    kubectl -n "$METALLB_NAMESPACE" get ipaddresspool "$pool" \
        -o jsonpath='{.metadata.labels.runme-test/owner}' 2>/dev/null || true
}
```

- [ ] **Step 5: setup 支持复用、teardown 跳过 init**

把 `setup_external_ip_pools` 整体替换为：

```bash
# 为网关 / 多集群测试在各业务集群创建外部 IP 地址池并等待可用（受 ENABLE_METALLB 门控）
# 用法: setup_external_ip_pools <cluster>...
# 说明:
#   - 池已存在（无论谁建的）时直接复用，不再要求 METALLB_EXTERNAL_ADDRESSES_JSON。
#     dailybuild 正是这条路径：lynx initials 每集群用该 region 自己的
#     $GLOBAL_EXTERNAL_IPPOOL 建好池（owner=init），三个测试项复用。
#   - 池不存在时按 METALLB_EXTERNAL_ADDRESSES_JSON 创建，owner 取
#     ${EXTERNAL_IP_POOL_OWNER:-doctest}（本地手工跑的既有路径）。
setup_external_ip_pools() {
    [ "${ENABLE_METALLB:-false}" = "true" ] || return 0

    if [ $# -eq 0 ]; then
        log_error "setup_external_ip_pools: 至少需要一个集群参数"
        return 1
    fi

    local pool="$METALLB_EXTERNAL_POOL_NAME"
    local owner="${EXTERNAL_IP_POOL_OWNER:-doctest}"
    local json="${METALLB_EXTERNAL_ADDRESSES_JSON:-}"
    local cluster existing

    for cluster in "$@"; do
        existing=$(_external_ip_pool_owner "$cluster" "$pool")
        if [ -n "$existing" ]; then
            log_info "外部 IP 地址池 $pool 已存在于集群 $cluster (owner=$existing)，直接复用"
            _wait_ipaddresspool_available "$cluster" "$pool" || return 1
            continue
        fi

        if [ -z "$json" ]; then
            log_error "集群 $cluster 上不存在外部 IP 地址池 $pool，且未设置 METALLB_EXTERNAL_ADDRESSES_JSON"
            log_error '示例: METALLB_EXTERNAL_ADDRESSES_JSON='\''[{"cluster":"business-1","ipv4Addresses":["192.168.139.13/32"]}]'\'''
            log_error "dailybuild 场景应由 initials 的 docs-test init 预先建好该池"
            return 1
        fi
        if ! printf '%s' "$json" | jq empty 2>/dev/null; then
            log_error "METALLB_EXTERNAL_ADDRESSES_JSON 不是有效 JSON"
            return 1
        fi

        # 取该集群地址（合并 ipv4Addresses 与 ipv6Addresses，后者缺省为空数组）
        # 用 while-read 逐行收集（兼容 macOS 自带 Bash 3.2，其无 mapfile/readarray）
        local addresses=() addr_line
        while IFS= read -r addr_line; do
            if [ -n "$addr_line" ]; then
                addresses+=("$addr_line")
            fi
        done < <(printf '%s' "$json" | jq -r --arg c "$cluster" \
            '.[] | select(.cluster == $c) | ((.ipv4Addresses // []) + (.ipv6Addresses // []))[]')
        if [ ${#addresses[@]} -eq 0 ]; then
            log_error "METALLB_EXTERNAL_ADDRESSES_JSON 中集群 $cluster 无地址配置 (需含 cluster=$cluster 的条目及 ipv4Addresses)"
            return 1
        fi
        create_external_ip_pool "$cluster" "$pool" "$owner" "${addresses[@]}" || return 1
        _wait_ipaddresspool_available "$cluster" "$pool" || return 1
    done
    log_success "外部 IP 地址池已就绪: 集群 $* (pool=$pool)"
    return 0
}
```

把 `teardown_external_ip_pools` 的循环体替换为：

```bash
    local pool="$METALLB_EXTERNAL_POOL_NAME"
    local cluster owner rc=0
    for cluster in "$@"; do
        owner=$(_external_ip_pool_owner "$cluster" "$pool")
        if [ "$owner" = "init" ]; then
            log_info "外部 IP 地址池 $pool@$cluster 由 init 创建（owner=init），跳过清理"
            continue
        fi
        delete_external_ip_pool "$cluster" "$pool" || rc=1
    done
```

- [ ] **Step 6: 更新 README 的 MetalLB 说明**

在 `README.md` 中 `METALLB_EXTERNAL_ADDRESSES_JSON` 那段注释之后补一句：

```markdown
> 地址池所有权：`init` 入口（`lynx/entrypoint.sh` 的 `docs-test init`）创建的池带
> `runme-test/owner=init` 标签，长期存在、测试结束不清理；单篇测试脚本自建的池带
> `owner=doctest`，用完即删。池已存在时 `setup_external_ip_pools` 直接复用，
> 不再要求 `METALLB_EXTERNAL_ADDRESSES_JSON`。
```

- [ ] **Step 7: 运行单测确认通过**

```bash
bash framework/tests/ip_pool_test.sh && bash framework/tests/mesh_project_test.sh
```

预期：两个都 `失败: 0`。

- [ ] **Step 8: 提交**

```bash
git add framework/common.sh framework/tests/ip_pool_test.sh README.md
git commit -m "feat: MetalLB 地址池所有权模型

- IPAddressPool / L2Advertisement 带 runme-test/owner 标签（init | doctest）
- setup_external_ip_pools 池已存在即复用，不再强制要求地址 JSON
- teardown_external_ip_pools 跳过 owner=init 的池
- create_external_ip_pool 新增 owner 参数"
```

---

### Task 8: lynx 镜像入口与环境变量适配

**Files:**
- Create: `lynx/env-adapter.sh`
- Create: `lynx/entrypoint.sh`
- Create: `framework/tests/env_adapter_test.sh`
- Modify: `README.md`（新增「在 lynx / dailybuild 中运行」章节）

**Interfaces:**
- Consumes: `allure_emit_broken` / `allure_write_environment` / `allure_write_categories` / `allure_generate`（Task 3）；`setup_external_ip_pools`（Task 7）
- Produces:
  - `lynx_adapt_env` → 把 lynx 内置变量映射为框架变量并补默认值
  - `lynx/entrypoint.sh <init|mesh|otel|tracing>` → 镜像 ENTRYPOINT

- [ ] **Step 1: 写失败的单测**

创建 `framework/tests/env_adapter_test.sh`：

```bash
#!/usr/bin/env bash
# lynx/env-adapter.sh 单元测试（纯 bash + jq，不依赖集群）
# 用法: bash framework/tests/env_adapter_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 在子 shell 里跑一次适配，回显指定变量，避免污染测试进程
adapt_and_echo() {
    local var="$1"; shift
    ( set -u
      # shellcheck disable=SC1090,SC1091
      . "$FRAMEWORK_ROOT/lynx/env-adapter.sh"
      env -i PATH="$PATH" HOME="$HOME" FRAMEWORK_ROOT="$FRAMEWORK_ROOT" "$@" \
        bash -c '
          . "$FRAMEWORK_ROOT/framework/common.sh"
          . "$FRAMEWORK_ROOT/lynx/env-adapter.sh"
          lynx_adapt_env >/dev/null 2>&1
          printf "%s" "${'"$var"':-}"
        ' )
}

test_credential_mapping() {
    printf '\n== 平台凭据映射 ==\n'
    check_eq "API_URL→PLATFORM_ADDRESS"      "$(adapt_and_echo PLATFORM_ADDRESS  API_URL=https://acp.example)"      "https://acp.example"
    check_eq "USERNAME→PLATFORM_USERNAME"    "$(adapt_and_echo PLATFORM_USERNAME USERNAME=admin)"                   "admin"
    check_eq "PASSWORD→PLATFORM_PASSWORD"    "$(adapt_and_echo PLATFORM_PASSWORD PASSWORD=p@ss)"                    "p@ss"
    check_eq "REGION_NAME→SINGLE_CLUSTER_NAME" "$(adapt_and_echo SINGLE_CLUSTER_NAME REGION_NAME=asm-1)"            "asm-1"
    check_eq "已有 PLATFORM_ADDRESS 不被覆盖" \
        "$(adapt_and_echo PLATFORM_ADDRESS API_URL=https://a PLATFORM_ADDRESS=https://b)" "https://b"
}

test_ippool_mapping() {
    printf '\n== GLOBAL_EXTERNAL_IPPOOL → METALLB_EXTERNAL_ADDRESSES_JSON ==\n'
    local out
    out="$(adapt_and_echo METALLB_EXTERNAL_ADDRESSES_JSON REGION_NAME=asm-1 GLOBAL_EXTERNAL_IPPOOL='"192.168.1.10,192.168.1.11"')"
    check_eq "集群名"   "$(printf '%s' "$out" | jq -r '.[0].cluster')"              "asm-1"
    check_eq "两个地址" "$(printf '%s' "$out" | jq -r '.[0].ipv4Addresses | length')" "2"
    check_eq "补 /32"   "$(printf '%s' "$out" | jq -r '.[0].ipv4Addresses[0]')"     "192.168.1.10/32"

    out="$(adapt_and_echo METALLB_EXTERNAL_ADDRESSES_JSON REGION_NAME=asm-1 \
           GLOBAL_EXTERNAL_IPPOOL=192.168.1.10 GLOBAL_EXTERNAL_IPPOOL_V6=fd00::1)"
    check_eq "v6 补 /128" "$(printf '%s' "$out" | jq -r '.[0].ipv6Addresses[0]')" "fd00::1/128"

    out="$(adapt_and_echo METALLB_EXTERNAL_ADDRESSES_JSON REGION_NAME=asm-1)"
    check_eq "无 IP 池时不产生 JSON" "$out" ""
}

test_defaults() {
    printf '\n== 默认值 ==\n'
    check_eq "GLOBAL_CLUSTER_NAME 默认 global" "$(adapt_and_echo GLOBAL_CLUSTER_NAME)"      "global"
    check_eq "ACP_KUBECONFIG_MODE 默认 direct" "$(adapt_and_echo ACP_KUBECONFIG_MODE)"      "direct"
    check_eq "IS_DUAL_STACK 默认 false"        "$(adapt_and_echo IS_DUAL_STACK)"            "false"
    check_eq "EXIT_ON_TEST_FAILURE 默认 false" "$(adapt_and_echo EXIT_ON_TEST_FAILURE)"     "false"
    check_eq "模板显式值优先"                  "$(adapt_and_echo IS_DUAL_STACK IS_DUAL_STACK=true)" "true"
}

main() {
    test_credential_mapping
    test_ippool_mapping
    test_defaults
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
```

- [ ] **Step 2: 运行单测确认失败**

```bash
bash framework/tests/env_adapter_test.sh
```

预期：`lynx/env-adapter.sh: No such file or directory`。

- [ ] **Step 3: 实现 `lynx/env-adapter.sh`**

```bash
#!/usr/bin/env bash
# lynx 内置变量 → 框架变量映射
#
# lynx 会替换测试项 envs 里的 $API_URL / $USERNAME / $PASSWORD / $REGION_NAME /
# $GLOBAL_EXTERNAL_IPPOOL 等内置变量，但**不替换 $TOKEN**（virt-readiness 实测记录：
# $TOKEN 以字面量抵达）。所以凭据一律走账号密码，由 framework/acp-auth.sh 经 dex 换 token。
#
# 所有赋值都用 := ——已显式设置的值优先，便于本地调试时逐个覆盖。

lynx_adapt_env() {
    # ── 平台凭据 ──
    : "${PLATFORM_ADDRESS:=${API_URL:-}}"
    : "${PLATFORM_USERNAME:=${USERNAME:-}}"
    : "${PLATFORM_PASSWORD:=${PASSWORD:-}}"
    export PLATFORM_ADDRESS PLATFORM_USERNAME PLATFORM_PASSWORD

    # ── 被测集群 ──
    : "${SINGLE_CLUSTER_NAME:=${REGION_NAME:-}}"
    export SINGLE_CLUSTER_NAME

    # ── 报告输出目录（lynx 注入；未注入时给镜像内缺省值）──
    : "${TEST_RESULT_DIR:=/app/report}"
    mkdir -p "$TEST_RESULT_DIR" 2>/dev/null || true
    export TEST_RESULT_DIR

    # ── 镜像构建期信息（RUNME_VERSION 是 run.sh check_env 的必需项）──
    if [ -f "${FRAMEWORK_ROOT:-.}/.image-info" ]; then
        # shellcheck disable=SC1090,SC1091
        . "${FRAMEWORK_ROOT}/.image-info"
    fi
    export RUNME_VERSION DOCS_TEST_IMAGE_TAG MESH_DOCS_REF OTEL_DOCS_REF TRACING_DOCS_REF

    # ── 外部地址池：$GLOBAL_EXTERNAL_IPPOOL 是逗号分隔的裸 IP（ares 会带引号，需剥掉），
    #    按当前 region 组装成框架需要的 JSON 格式。IPv6 走 GLOBAL_EXTERNAL_IPPOOL_V6。──
    if [ -z "${METALLB_EXTERNAL_ADDRESSES_JSON:-}" ] && \
       { [ -n "${GLOBAL_EXTERNAL_IPPOOL:-}" ] || [ -n "${GLOBAL_EXTERNAL_IPPOOL_V6:-}" ]; }; then
        local v4 v6
        v4="${GLOBAL_EXTERNAL_IPPOOL:-}"; v4="${v4//\"/}"
        v6="${GLOBAL_EXTERNAL_IPPOOL_V6:-}"; v6="${v6//\"/}"
        METALLB_EXTERNAL_ADDRESSES_JSON=$(jq -nc \
            --arg c "${SINGLE_CLUSTER_NAME:-}" --arg v4 "$v4" --arg v6 "$v6" '
            [ { cluster: $c,
                ipv4Addresses: ($v4 | split(",") | map(select(length > 0) | . + "/32")),
                ipv6Addresses: ($v6 | split(",") | map(select(length > 0) | . + "/128")) } ]')
        export METALLB_EXTERNAL_ADDRESSES_JSON
    fi

    # ── 安全缺省（模板未显式给出时）──
    : "${GLOBAL_CLUSTER_NAME:=global}"
    : "${ACP_KUBECONFIG_MODE:=direct}"
    : "${IS_DUAL_STACK:=false}"
    # lynx 场景默认不因用例失败而非 0 退出：结果由 allure 报告承载，
    # 否则 lynx 会把「测试有失败」误判成「测试任务 Error」。
    : "${EXIT_ON_TEST_FAILURE:=false}"
    export GLOBAL_CLUSTER_NAME ACP_KUBECONFIG_MODE IS_DUAL_STACK EXIT_ON_TEST_FAILURE
}
```

- [ ] **Step 4: 运行单测确认通过**

```bash
bash framework/tests/env_adapter_test.sh
```

预期：`失败: 0`。

- [ ] **Step 5: 实现 `lynx/entrypoint.sh`**

```bash
#!/usr/bin/env bash
# 镜像入口（lynx TestTemplate 里写 command: docs-test）
#
# 用法: docs-test <init|mesh|otel|tracing>
#   init    —— 每个业务集群跑一次的前置：拉 kubeconfig、装集群插件与 servicemesh-operator2、
#              用本 region 的 $GLOBAL_EXTERNAL_IPPOOL 建 MetalLB 地址池（owner=init）
#   mesh    —— ./run-mesh-all.sh
#   otel    —— ./run-otel-all.sh
#   tracing —— ./run-tracing-all.sh
#
# 无论编排怎么退出，都保证 $TEST_RESULT_DIR 下有一份 allure 报告：空的 allure 目录
# 会让 lynx 的 summaryResult 变成 NUL，比一条明确的 broken 用例难排查得多。
set -uo pipefail

FRAMEWORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FRAMEWORK_ROOT
cd "$FRAMEWORK_ROOT"

# 与 run.sh 相同的加载顺序（init 模式要直接调用 setup_external_ip_pools）
# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/report.sh"
source "$FRAMEWORK_ROOT/framework/acp-auth.sh"
source "$FRAMEWORK_ROOT/framework/kubeconfig.sh"
source "$FRAMEWORK_ROOT/framework/tools.sh"
source "$FRAMEWORK_ROOT/framework/assets.sh"
source "$FRAMEWORK_ROOT/lynx/env-adapter.sh"

export PATH="$FRAMEWORK_ROOT/bin:$PATH"

lynx_adapt_env

MODE="${1:-}"
case "$MODE" in
    init|mesh|otel|tracing) ;;
    *)
        log_error "用法: docs-test <init|mesh|otel|tracing>"
        exit 1
        ;;
esac

# 兜底：编排异常中断时也要留下可解析的 allure 报告
_emergency_report() {
    local rc=$?
    if [ -d "${TEST_RESULT_DIR:-/nonexistent}/allure-report" ]; then
        return 0
    fi
    log_warn "未产出 allure 报告（docs-test $MODE 退出码 $rc），生成占位报告"
    allure_emit_broken       "$TEST_RESULT_DIR/allure-result" "docs-test $MODE 异常退出，退出码 $rc" || true
    allure_write_environment "$TEST_RESULT_DIR/allure-result" || true
    allure_write_categories  "$TEST_RESULT_DIR/allure-result" || true
    allure_generate          "$TEST_RESULT_DIR/allure-result" "$TEST_RESULT_DIR/allure-report" || true
}
trap _emergency_report EXIT

if [ "$MODE" = "init" ]; then
    if [ -z "${SINGLE_CLUSTER_NAME:-}" ]; then
        log_error "init 模式需要 REGION_NAME（或 SINGLE_CLUSTER_NAME）指定目标业务集群"
        exit 1
    fi
    log_header "docs-test init：初始化业务集群 $SINGLE_CLUSTER_NAME"
    ./run.sh --project mesh --init-only --cluster "$SINGLE_CLUSTER_NAME" || exit 1
    # 地址池由 init 拥有：长期存在，供后续三个测试项复用，测试脚本不会清理它
    EXTERNAL_IP_POOL_OWNER=init setup_external_ip_pools "$SINGLE_CLUSTER_NAME" || exit 1
    log_success "docs-test init 完成: $SINGLE_CLUSTER_NAME"
    exit 0
fi

log_header "docs-test $MODE：CASE_TYPE='${CASE_TYPE:-<未设置，全选>}'"
"./run-${MODE}-all.sh"
exit $?
```

设为可执行：

```bash
chmod +x lynx/entrypoint.sh lynx/check-manifest.sh
```

- [ ] **Step 6: 语法检查与用法校验**

```bash
bash -n lynx/entrypoint.sh && bash -n lynx/env-adapter.sh && echo "语法 OK"
bash lynx/entrypoint.sh 2>&1 | tail -2
bash lynx/entrypoint.sh badmode 2>&1 | tail -2
```

预期：`语法 OK`；后两条都打印 `用法: docs-test <init|mesh|otel|tracing>`。

- [ ] **Step 7: 更新 README，新增 lynx 运行章节**

在 `README.md` 的「## 使用方法」章节之后插入：

```markdown
## 在 lynx / dailybuild 中运行

镜像 `build-harbor.alauda.cn/asm/docs-runme-tests:<tag>`，入口 `command: docs-test`，
参数 `args: [init|mesh|otel|tracing]`。

| lynx 内置变量 | 映射到框架变量 | 备注 |
| --- | --- | --- |
| `$API_URL` | `PLATFORM_ADDRESS` | |
| `$USERNAME` / `$PASSWORD` | `PLATFORM_USERNAME` / `PLATFORM_PASSWORD` | |
| `$REGION_NAME` | `SINGLE_CLUSTER_NAME` | 被测集群 |
| `$GLOBAL_EXTERNAL_IPPOOL` | `METALLB_EXTERNAL_ADDRESSES_JSON` | 按 region 取值，`init` 用它建地址池 |
| `TEST_RESULT_DIR` | 报告根目录 | 未注入时缺省 `/app/report` |
| `CASE_TYPE` | Case / DocTest 过滤表达式 | 仅支持 `and` / `not` 合取式 |
| `$TOKEN` | **忽略** | lynx 不替换它，框架用账号密码经 dex 换 token |

模板里需要写死的变量：`EAST_CLUSTER_NAME`、`WEST_CLUSTER_NAME`、`GLOBAL_CLUSTER_NAME=global`、
`ENABLE_METALLB`、`USE_MESH_V2_TEST_SUITE_PLUGIN=true`、`IS_DUAL_STACK`、`TRACING_ACP_ES_CLUSTER`、
`ACP_KUBECONFIG_MODE=direct`、`AUTO_GEN_BOOKINFO_TRAFFIC=true`、`ENABLE_GW_LINUX_KERNEL_COMPAT=false`、
`RESOURCE_PREFIX`。所有 `PKG_*_URL` **不设置**（verify-only，见上文）。

报告产物：`$TEST_RESULT_DIR/allure-result/` 与 `$TEST_RESULT_DIR/allure-report/`。
用例粒度为一篇文档的一次执行（DocTest），Case 作为 allure suite 分组。
```

- [ ] **Step 8: 跑一遍所有框架单测**

```bash
for t in framework/tests/*_test.sh; do echo "--- $t"; bash "$t" | tail -2; done
```

预期：每个都以 `失败: 0` 结束。

- [ ] **Step 9: 提交**

```bash
git add lynx/env-adapter.sh lynx/entrypoint.sh framework/tests/env_adapter_test.sh README.md
git commit -m "feat: lynx 镜像入口与环境变量适配

- lynx/env-adapter.sh：API_URL/USERNAME/PASSWORD/REGION_NAME 等映射为框架变量，
  GLOBAL_EXTERNAL_IPPOOL 组装成 METALLB_EXTERNAL_ADDRESSES_JSON，忽略不被替换的 TOKEN
- lynx/entrypoint.sh：docs-test <init|mesh|otel|tracing>，init 建 owner=init 地址池，
  trap EXIT 兜底产出 allure 报告避免 lynx summaryResult 变 NUL
- README 新增「在 lynx / dailybuild 中运行」章节"
```

---

### Task 9: 编排脚本打标签、egress 门控与 case_id 清单

**Files:**
- Create: `lynx/case-ids.tsv`
- Create: `lynx/check-case-ids.sh`
- Modify: `run-mesh-all.sh`（11 个 Case + 3 篇 egress DocTest）
- Modify: `run-otel-all.sh`（2 个 Case）
- Modify: `run-tracing-all.sh`（4 个 Case）
- Modify: `README.md`（新增 Case 标签表与首批 CASE_TYPE）

**Interfaces:**
- Consumes: `case_begin_if` / `doctest_selected`（Task 1）；`case_skip <id> <name> <reason> [category]`（Task 2）
- Produces: `lynx/case-ids.tsv`（三列 TSV，供 `lynx/allure.sh` 的 `_allure_case_id` 查表）

- [ ] **Step 1: 写 case_id 清单**

创建 `lynx/case-ids.tsv`（TAB 分隔，第一列项目、第二列文档名即 `runme-test_<doc>.sh` 的 `<doc>`、第三列编号）。编号一经分配永不复用；文档改名时保留原编号只改第二列。

```
# case_id 清单：<project><TAB><doc><TAB><case_id>
# 编号规则：mesh=ASM-DOC-NNN，otel=OTEL-DOC-NNN，tracing=TRACE-DOC-NNN
# 一经分配永不复用；文档改名保留原编号，只改 doc 列；新增文档追加最大编号 +1
mesh	install-mesh-in-dual-stack-mode	ASM-DOC-001
mesh	install-mesh	ASM-DOC-002
mesh	configuring-istio-ha-by-using-autoscaling	ASM-DOC-003
mesh	configuring-istio-ha-by-using-replica-count	ASM-DOC-004
mesh	metrics-and-mesh	ASM-DOC-005
mesh	config-with-service-mesh	ASM-DOC-006
mesh	kiali	ASM-DOC-007
mesh	deploying-the-bookinfo-application	ASM-DOC-008
mesh	mtls	ASM-DOC-009
mesh	exposing-a-service-via-istio-gateway	ASM-DOC-010
mesh	exposing-a-service-via-k8s-gateway-api-in-sidecar-mode	ASM-DOC-011
mesh	routing-egress-traffic-via-istio-apis	ASM-DOC-012
mesh	routing-egress-traffic-via-k8s-gateway-api-in-sidecar-mode	ASM-DOC-013
mesh	uninstalling-alauda-build-of-kiali	ASM-DOC-014
mesh	uninstalling-alauda-service-mesh	ASM-DOC-015
mesh	update-inplace	ASM-DOC-016
mesh	istio-cni	ASM-DOC-017
mesh	update-revisionbased	ASM-DOC-018
mesh	update-revisionbased-and-istiorevisiontag	ASM-DOC-019
mesh	installing-ambient-mode	ASM-DOC-020
mesh	deploying-ambient-bookinfo	ASM-DOC-021
mesh	waypoint-proxies	ASM-DOC-022
mesh	ambient-l7-features	ASM-DOC-023
mesh	exposing-a-service-via-k8s-gateway-api-in-ambient-mode	ASM-DOC-024
mesh	routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode	ASM-DOC-025
mesh	uninstalling-alauda-service-mesh-in-ambient-mode	ASM-DOC-026
mesh	updating-ambient-components	ASM-DOC-027
mesh	updating-waypoint-proxies	ASM-DOC-028
mesh	configuration-overview	ASM-DOC-029
mesh	install-multi-primary-multi-network	ASM-DOC-030
mesh	install-primary-remote-multi-network	ASM-DOC-031
otel	rbac-resources	OTEL-DOC-001
otel	install-opentelemetry	OTEL-DOC-002
otel	without-sidecar	OTEL-DOC-003
otel	uninstalling-opentelemetry	OTEL-DOC-004
otel	java-instrumentation	OTEL-DOC-005
tracing	installing-distributed-tracing-elasticsearch	TRACE-DOC-001
tracing	installing-distributed-tracing-opensearch	TRACE-DOC-002
tracing	uninstalling-distributed-tracing	TRACE-DOC-003
tracing	spm-ha-elasticsearch	TRACE-DOC-004
tracing	spm-ha-opensearch	TRACE-DOC-005
```

- [ ] **Step 2: 实现 `lynx/check-case-ids.sh` 并运行**

```bash
#!/usr/bin/env bash
# 校验 lynx/case-ids.tsv：格式合法、编号唯一、每个 runme-test_*.sh 都已登记
# 用法: bash lynx/check-case-ids.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IDS="$FRAMEWORK_ROOT/lynx/case-ids.tsv"

if [ ! -f "$IDS" ]; then
    printf '错误: 找不到 %s\n' "$IDS" >&2
    exit 1
fi

rc=0

# 1. 每条记录三列，且编号格式合法
bad_fmt="$(awk -F'\t' '!/^#/ && NF > 0 && (NF != 3 || $3 !~ /^(ASM|OTEL|TRACE)-DOC-[0-9]{3}$/) {print NR": "$0}' "$IDS")"
if [ -n "$bad_fmt" ]; then
    printf '错误: 以下行格式不合法（需三列 TAB 分隔，编号形如 ASM-DOC-001）：\n' >&2
    printf '%s\n' "$bad_fmt" | sed 's/^/  /' >&2
    rc=1
fi

# 2. 编号唯一
dup_id="$(awk -F'\t' '!/^#/ && NF == 3 {print $3}' "$IDS" | sort | uniq -d)"
if [ -n "$dup_id" ]; then
    printf '错误: 重复的 case_id：\n' >&2
    printf '%s\n' "$dup_id" | sed 's/^/  - /' >&2
    rc=1
fi

# 3. project+doc 组合唯一
dup_doc="$(awk -F'\t' '!/^#/ && NF == 3 {print $1"/"$2}' "$IDS" | sort | uniq -d)"
if [ -n "$dup_doc" ]; then
    printf '错误: 重复的 project/doc：\n' >&2
    printf '%s\n' "$dup_doc" | sed 's/^/  - /' >&2
    rc=1
fi

# 4. 每个已存在的 runme-test_*.sh 都已登记
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [ -n "$line" ] || continue
    name="${line%%:*}"
    path="${line#*:}"
    case "$path" in
        /*) repo="$path" ;;
        *)  repo="$FRAMEWORK_ROOT/$path" ;;
    esac
    [ -d "$repo/docs" ] || continue
    find "$repo/docs" -type f -name 'runme-test_*.sh' | while IFS= read -r f; do
        doc="$(basename "$f")"; doc="${doc#runme-test_}"; doc="${doc%.sh}"
        if ! awk -F'\t' -v p="$name" -v d="$doc" '!/^#/ && $1==p && $2==d {found=1} END {exit !found}' "$IDS"; then
            printf '错误: 未登记 case_id: %s/%s（%s）\n' "$name" "$doc" "$f" >&2
            printf 'x' >> "$FRAMEWORK_ROOT/.case-id-miss"
        fi
    done
done < "$FRAMEWORK_ROOT/repos.conf"

if [ -f "$FRAMEWORK_ROOT/.case-id-miss" ]; then
    rm -f "$FRAMEWORK_ROOT/.case-id-miss"
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    printf 'case_id 清单校验通过：%d 条记录\n' "$(awk -F'\t' '!/^#/ && NF == 3' "$IDS" | wc -l | tr -d ' ')"
fi
exit "$rc"
```

运行：

```bash
chmod +x lynx/check-case-ids.sh
bash lynx/check-case-ids.sh
```

预期：`case_id 清单校验通过：41 条记录`。若报「未登记」，把缺的文档按最大编号 +1 追加进清单再跑。

- [ ] **Step 3: 给 run-mesh-all.sh 的 11 个 Case 打标签**

把每个 `case_begin "<id>" "<name>"` + 后续 `if ( ... ); then case_end 0; else case_end 1; fi` 的结构，改成 `case_begin_if` 门控。按下表逐个改：

| Case | 标签 |
| --- | --- |
| 1 环境初始化 | `always install` |
| 2 双栈网格安装 | `dualstack install` |
| 3 单网格安装与应用测试 | `smoke install sidecar` |
| 4 Istio HA 配置测试 | `ha install` |
| 5 Ambient Mode 安装测试 | `smoke install ambient` |
| 6 多集群-多主多网络 | `multicluster` |
| 7 多集群-主远多网络 | `multicluster` |
| 8 InPlace 更新策略 | `update` |
| 9 RevisionBased 更新策略 | `update` |
| 10 RevisionBased + Tag 更新策略 | `update` |
| 11 Ambient 模式更新测试 | `update ambient` |

Case 1（致命前置）改为：

```bash
if case_begin_if "1" "环境初始化（默认 SINGLE_CLUSTER_NAME）" always install; then
    if (
        set -e
        ./run.sh --project mesh --init-only
    ); then
        case_end 0
    else
        case_end_fatal 1
    fi
fi
```

Case 2 原本用 `IS_DUAL_STACK` 判断，改为标签 + 环境判断并存（环境不支持要标 `env` 分类）：

```bash
if [ "${IS_DUAL_STACK:-false}" != "true" ]; then
    case_skip "2" "双栈网格安装测试" "IS_DUAL_STACK != true" env
elif case_begin_if "2" "双栈网格安装测试 (Dual Stack)" dualstack install; then
    if (
        set -e
        ./run.sh --project mesh --file install-mesh-in-dual-stack-mode --no-cleanup
        ./run.sh --project mesh --file install-mesh-in-dual-stack-mode --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi
```

Case 3 除了打标签，还要给两组 egress DocTest 加门控。把原来的四行 egress 调用替换为：

```bash
    # 出口网关 (sidecar 模式) 测试：需要集群侧访问外网（httpbingo.org），
    # 离线环境用 CASE_TYPE 的 `not egress` 排除
    if doctest_selected egress; then
        ./run.sh --project mesh --file routing-egress-traffic-via-istio-apis --no-cleanup
        ./run.sh --project mesh --file routing-egress-traffic-via-istio-apis --cleanup-only
        ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-sidecar-mode --no-cleanup
        ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-sidecar-mode --cleanup-only
    fi
```

Case 5 的 ambient egress 两行同理替换为：

```bash
    # 出口网关 (Egress Gateway) 测试：同上，需要集群侧外网
    if doctest_selected egress; then
        ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode --no-cleanup
        ./run.sh --project mesh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode --cleanup-only
    fi
```

Case 6/7 原本嵌在 `if [ -z "$EAST_CLUSTER_NAME" ] ... else ... fi` 里，改为环境判断用 `env` 分类、标签门控用 `case_begin_if`：

```bash
if [ -z "${EAST_CLUSTER_NAME:-}" ] || [ -z "${WEST_CLUSTER_NAME:-}" ]; then
    case_skip "6" "多集群-多主多网络拓扑" "未设置 EAST_CLUSTER_NAME / WEST_CLUSTER_NAME" env
    case_skip "7" "多集群-主-远多网络拓扑" "未设置 EAST_CLUSTER_NAME / WEST_CLUSTER_NAME" env
else
    if case_begin_if "6" "多集群 - 多主多网络拓扑 (Multi-Primary Multi-Network)" multicluster; then
        ... 原有子 shell 与 case_end ...
    fi
    if case_begin_if "7" "多集群 - 主-远多网络拓扑 (Primary-Remote Multi-Network)" multicluster; then
        ... 原有子 shell 与 case_end ...
    fi
fi
```

Case 4、8、9、10、11 按同一模式包一层 `if case_begin_if "<id>" "<原名称>" <标签...>; then ... fi`，子 shell 与 `case_end` 内容不变。

- [ ] **Step 4: 给 run-otel-all.sh 与 run-tracing-all.sh 打标签**

`run-otel-all.sh`：

```bash
if case_begin_if "1" "OpenTelemetry v2 安装与卸载测试" smoke install; then
    ... 原有子 shell 与 case_end ...
fi

if case_begin_if "2" "Java 自动注入示例服务 + 分布式调用链 (Java Instrumentation Demo)" smoke install java; then
    ... 原有子 shell 与 case_end ...
fi
```

`run-tracing-all.sh`：

```bash
if case_begin_if "1" "分布式调用链安装与卸载测试 (Elasticsearch)" smoke install elasticsearch; then ... fi
if case_begin_if "2" "分布式调用链安装与卸载测试 (OpenSearch)" install opensearch; then ... fi
if case_begin_if "3" "SPM 多副本（高可用）验证 (Elasticsearch)" smoke ha elasticsearch; then ... fi
if case_begin_if "4" "SPM 多副本（高可用）验证 (OpenSearch)" ha opensearch; then ... fi
```

> OpenSearch 两个 Case 故意不带 `smoke`——首批 `CASE_TYPE="smoke and not egress"` 会跳过它们。
> 将来 OpenSearch 就绪时给这两行补上 `smoke` 即可纳入，`CASE_TYPE` 不用动。

- [ ] **Step 5: 用 dry-run 验证门控生效**

三个编排脚本都会真跑集群，不能直接执行。改用「把 `./run.sh` 替换成回显桩」的方式验证选择逻辑：

```bash
mkdir -p /tmp/dryrun && cat > /tmp/dryrun/run.sh <<'EOF'
#!/usr/bin/env bash
echo "RUN: $*"
EOF
chmod +x /tmp/dryrun/run.sh

verify_selection() {
  local script="$1" case_type="$2"
  ( cd "$(mktemp -d)" && \
    cp "$OLDPWD/$script" . && \
    cp -r "$OLDPWD/framework" "$OLDPWD/lynx" . && \
    cp /tmp/dryrun/run.sh . && \
    CASE_TYPE="$case_type" bash "$script" 2>&1 | grep -E '^RUN:|SKIPPED|Case [0-9]+:' )
}

echo "=== CASE_TYPE='smoke and not egress' 下的 mesh ==="
verify_selection run-mesh-all.sh "smoke and not egress"
```

预期：输出里 Case 1/3/5 执行、Case 2/4/6/7/8/9/10/11 出现 `SKIPPED`，且三篇 `routing-egress-traffic-*` 不出现在 `RUN:` 行里。

同样验证 otel 与 tracing：

```bash
echo "=== otel ==="; verify_selection run-otel-all.sh "smoke and not egress"
echo "=== tracing ==="; verify_selection run-tracing-all.sh "smoke and not egress"
```

预期：otel 两个 Case 都执行；tracing Case 1/3 执行、Case 2/4 `SKIPPED`。

- [ ] **Step 6: 更新 README 的 Case 标签说明**

在 `README.md` 的「在 lynx / dailybuild 中运行」章节末尾追加：

```markdown
### Case 标签与 CASE_TYPE

`CASE_TYPE` 只支持 `and` 连接的合取式与 `not` 取反（`or` 与括号会报错退出）。
保留标签 `always` 恒被选中，用于环境初始化这类必须先跑的前置 Case。
`CASE_TYPE` 未设置时全部选中——本地手工跑行为不变。

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
| tracing | 1 安装与卸载（ES） | `smoke install elasticsearch` |
| tracing | 2 安装与卸载（OpenSearch） | `install opensearch` |
| tracing | 3 SPM 多副本（ES） | `smoke ha elasticsearch` |
| tracing | 4 SPM 多副本（OpenSearch） | `ha opensearch` |

DocTest 级标签只有 `egress`（mesh Case 3 / 5 中的三篇 `routing-egress-traffic-*`）。

首批 dailybuild 用 `CASE_TYPE="smoke and not egress"`。
OpenSearch 就绪后给 tracing Case 2/4 补 `smoke` 标签即可纳入，表达式不用改。
```

- [ ] **Step 7: 提交**

```bash
git add lynx/case-ids.tsv lynx/check-case-ids.sh run-mesh-all.sh run-otel-all.sh run-tracing-all.sh README.md
git commit -m "feat: 编排 Case 打标签、egress 门控与 case_id 清单

- 17 个 Case 全部改用 case_begin_if 按 CASE_TYPE 门控；环境不支持的跳过标 env 分类
- mesh Case 3/5 的三篇 egress DocTest 由 doctest_selected 门控
- 新增 lynx/case-ids.tsv（41 条）与 check-case-ids.sh 校验脚本
- README 补 Case 标签表与首批 CASE_TYPE"
```

---

### Task 10: Dockerfile 与镜像本地验证

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `lynx/release-matrix.tsv`
- Modify: `README.md`（新增「构建测试镜像」章节）

**Interfaces:**
- Consumes: `lynx/entrypoint.sh`、`lynx/assets-manifest.tsv`、`lynx/check-manifest.sh`（Task 4/8）
- Produces:
  - 镜像内 `/app/docs-runme-tests/.image-info`：`RUNME_VERSION` / `DOCS_TEST_IMAGE_TAG` / `MESH_DOCS_REF` / `OTEL_DOCS_REF` / `TRACING_DOCS_REF`
  - `/usr/local/bin/docs-test` → `lynx/entrypoint.sh` 的软链
  - `lynx/release-matrix.tsv`：两列 TSV，`<docs-runme-tests 分支><TAB><ACP 大版本>`

- [ ] **Step 1: 写 `.dockerignore`**

```
.git
.kubeconfig
.acp-auth
package
tmp
assets
bin
docs/superpowers
*.tgz
*.tar.gz
```

> 注意 `bin/` 与 `assets/` 必须排除：它们是本机产物（可能是 macOS 二进制），镜像内要重新下载 Linux 版。

- [ ] **Step 2: 写 `lynx/release-matrix.tsv`**

```
# docs-runme-tests 分支 → ACP 大版本，供构建流水线决定 release tag
# master 不在此表内，固定出 latest
release-mesh-2.2	4.5
release-mesh-2.1	4.4
```

- [ ] **Step 3: 写 `Dockerfile`**

```dockerfile
# 文档自动化测试镜像
#
# 交付给 lynx 的产物：入口 docs-test <init|mesh|otel|tracing>，报告写到 $TEST_RESULT_DIR。
# 运行时零外网依赖——runme / violet / istioctl 与文档引用的 sample YAML 全部构建期落盘。
#
# 不复用 automation/ares:base-api-latest：那是 python/pytest 栈，我们一行 Python 都不跑，
# 却会把镜像撑到 1G 以上。
FROM ubuntu:22.04

ARG MESH_DOCS_REF=master
ARG OTEL_DOCS_REF=master
ARG TRACING_DOCS_REF=master
ARG RUNME_VERSION=3.16.11
ARG ALLURE_VERSION=2.24.1
ARG KUBECTL_VERSION=v1.31.4
ARG IMAGE_TAG=dev
ARG TARGETARCH=amd64
# 文档仓库若为私有仓库，构建时传入只读 token（公开仓库留空即可）
ARG GIT_TOKEN=""

LABEL io.alauda.docs.mesh-ref="${MESH_DOCS_REF}" \
      io.alauda.docs.otel-ref="${OTEL_DOCS_REF}" \
      io.alauda.docs.tracing-ref="${TRACING_DOCS_REF}" \
      io.alauda.runme-version="${RUNME_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8

# 基础工具 + JRE（allure CLI 需要）
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git jq openssl tzdata bash coreutils gawk sed tar gzip \
        default-jre-headless; \
    rm -rf /var/lib/apt/lists/*

# kubectl
RUN set -eux; \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
        -o /usr/local/bin/kubectl; \
    chmod +x /usr/local/bin/kubectl; \
    kubectl version --client

# allure CLI（与 ares 基础镜像同版本）
RUN set -eux; \
    curl -fsSL "https://github.com/allure-framework/allure2/releases/download/${ALLURE_VERSION}/allure-${ALLURE_VERSION}.tgz" \
        -o /tmp/allure.tgz; \
    tar -xzf /tmp/allure.tgz -C /opt; \
    rm -f /tmp/allure.tgz; \
    ln -s "/opt/allure-${ALLURE_VERSION}/bin/allure" /usr/local/bin/allure; \
    allure --version

WORKDIR /app
COPY . /app/docs-runme-tests

# 三个文档仓库：按 ref 浅克隆，repos.conf 的相对路径 ../xxx-docs 在此布局下天然成立
RUN set -eux; \
    if [ -n "${GIT_TOKEN}" ]; then AUTH="oauth2:${GIT_TOKEN}@"; else AUTH=""; fi; \
    git clone --depth 1 --branch "${MESH_DOCS_REF}"    "https://${AUTH}github.com/alauda/servicemesh2-docs.git"        /app/servicemesh2-docs; \
    git clone --depth 1 --branch "${OTEL_DOCS_REF}"    "https://${AUTH}github.com/alauda/opentelemetry-docs.git"       /app/opentelemetry-docs; \
    git clone --depth 1 --branch "${TRACING_DOCS_REF}" "https://${AUTH}github.com/alauda/distributed-tracing-docs.git" /app/distributed-tracing-docs

# runme / violet：预置到 bin/，运行时 _install_tool 的版本校验会直接命中并跳过下载
RUN set -eux; \
    cd /app/docs-runme-tests; \
    case "${TARGETARCH}" in \
      amd64) RUNME_ARCH=x86_64; VIOLET_ARCH=amd64 ;; \
      arm64) RUNME_ARCH=arm64;  VIOLET_ARCH=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p bin; \
    curl -fsSL "https://downloads.runme.dev/runme/${RUNME_VERSION}/runme_linux_${RUNME_ARCH}.tar.gz" -o /tmp/runme.tgz; \
    tar -xzf /tmp/runme.tgz -C bin; \
    rm -f /tmp/runme.tgz; \
    chmod +x bin/runme; \
    curl -fsSL "http://package-minio.alauda.cn:9199/packages/violet/latest/violet_linux_${VIOLET_ARCH}" -o bin/violet; \
    chmod +x bin/violet; \
    bin/runme --version | grep -q "runme version ${RUNME_VERSION}"; \
    bin/violet version | grep -q "Version: v"

# istioctl：版本从 mesh 文档的 runme 块推导，保证与 install_istioctl 的校验一致
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ISTIO_ARCH=amd64 ;; \
      arm64) ISTIO_ARCH=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    cd /app/servicemesh2-docs; \
    ISTIO_VERSION="$(/app/docs-runme-tests/bin/runme print multi-primary-multi-network:set-istio-version \
        | grep -oE 'ISTIO_VERSION=[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | cut -d= -f2)"; \
    test -n "${ISTIO_VERSION}"; \
    echo "istioctl 目标版本: ${ISTIO_VERSION}"; \
    curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-linux-${ISTIO_ARCH}.tar.gz" \
        -o /tmp/istioctl.tgz; \
    tar -xzf /tmp/istioctl.tgz -C /app/docs-runme-tests/bin; \
    rm -f /tmp/istioctl.tgz; \
    chmod +x /app/docs-runme-tests/bin/istioctl; \
    /app/docs-runme-tests/bin/istioctl version --remote=false | grep -q "client version: ${ISTIO_VERSION}"

# 离线资产：先校验清单覆盖了文档里的每个外部 URL，再逐条下载。
# 任一条缺失或下载失败即构建失败——不允许产出「缺资产的镜像」。
RUN set -eux; \
    cd /app/docs-runme-tests; \
    bash lynx/check-manifest.sh; \
    while IFS="$(printf '\t')" read -r url rel; do \
      case "${url}" in ''|'#'*) continue ;; esac; \
      mkdir -p "assets/$(dirname "${rel}")"; \
      curl -fsSL "${url}" -o "assets/${rel}"; \
      test -s "assets/${rel}"; \
    done < lynx/assets-manifest.tsv; \
    echo "已预置资产: $(find assets -type f | wc -l) 个"

# case_id 清单自检
RUN set -eux; cd /app/docs-runme-tests; bash lynx/check-case-ids.sh

# 构建期信息：入口据此回填 RUNME_VERSION 等（RUNME_VERSION 是 run.sh check_env 的必需项）
RUN set -eux; \
    printf 'RUNME_VERSION=%s\nDOCS_TEST_IMAGE_TAG=%s\nMESH_DOCS_REF=%s\nOTEL_DOCS_REF=%s\nTRACING_DOCS_REF=%s\n' \
        "${RUNME_VERSION}" "${IMAGE_TAG}" "${MESH_DOCS_REF}" "${OTEL_DOCS_REF}" "${TRACING_DOCS_REF}" \
        > /app/docs-runme-tests/.image-info

RUN set -eux; \
    chmod +x /app/docs-runme-tests/lynx/entrypoint.sh; \
    ln -s /app/docs-runme-tests/lynx/entrypoint.sh /usr/local/bin/docs-test

WORKDIR /app/docs-runme-tests
ENTRYPOINT ["/app/docs-runme-tests/lynx/entrypoint.sh"]
```

- [ ] **Step 4: 本地构建镜像**

```bash
docker build \
  --build-arg MESH_DOCS_REF=master \
  --build-arg OTEL_DOCS_REF=master \
  --build-arg TRACING_DOCS_REF=master \
  --build-arg IMAGE_TAG=local-dev \
  -t docs-runme-tests:local-dev .
```

预期：构建成功，日志里能看到 `istioctl 目标版本: 1.x.y`、`资产清单校验通过：17 个 URL 全部已登记`、`已预置资产: 17 个`、`case_id 清单校验通过：41 条记录`。

> 若文档仓库是私有仓库，clone 会失败，加 `--build-arg GIT_TOKEN=<只读 token>` 重试。

- [ ] **Step 5: 验证镜像内的自包含性与入口**

```bash
# 用法提示
docker run --rm docs-runme-tests:local-dev 2>&1 | tail -2

# 工具与资产齐备
docker run --rm --entrypoint bash docs-runme-tests:local-dev -c '
  set -e
  cd /app/docs-runme-tests
  echo "--- 工具 ---"
  bin/runme --version; bin/violet version | head -1; bin/istioctl version --remote=false; kubectl version --client --output=yaml | head -3; allure --version
  echo "--- 文档仓库 ---"
  for d in ../servicemesh2-docs ../opentelemetry-docs ../distributed-tracing-docs; do
    printf "%s: %s 个测试脚本\n" "$d" "$(find $d/docs -name "runme-test_*.sh" | wc -l)"
  done
  echo "--- 预置资产 ---"
  find assets -type f | wc -l
  echo "--- image-info ---"
  cat .image-info
'

# 框架单测在镜像内也要全绿
docker run --rm --entrypoint bash docs-runme-tests:local-dev -c '
  cd /app/docs-runme-tests
  rc=0
  for t in framework/tests/*_test.sh; do
    if bash "$t" | tail -1 | grep -q "失败: 0"; then echo "PASS $t"; else echo "FAIL $t"; rc=1; fi
  done
  exit $rc
'
```

预期：用法提示正确；三个文档仓库各有测试脚本；资产 17 个；`.image-info` 五个字段齐全；所有单测 `PASS`。

- [ ] **Step 6: 验证离线运行（断网跑到「连不上平台」为止）**

```bash
docker run --rm --network none \
  -e API_URL=https://acp.invalid \
  -e USERNAME=admin -e PASSWORD=x \
  -e REGION_NAME=asm-1 \
  -e TEST_RESULT_DIR=/tmp/report \
  docs-runme-tests:local-dev tracing 2>&1 | tail -20
```

预期：**不出现任何工具下载失败**（runme / violet / istioctl 都命中预置），最终因连不上平台而失败；且 `/tmp/report` 下产出了占位 allure 报告（由 `trap _emergency_report` 兜底）。用下面这条确认：

```bash
docker run --rm --network none \
  -e API_URL=https://acp.invalid -e USERNAME=admin -e PASSWORD=x \
  -e REGION_NAME=asm-1 -e TEST_RESULT_DIR=/tmp/report \
  --entrypoint bash docs-runme-tests:local-dev -c '
    /usr/local/bin/docs-test tracing >/dev/null 2>&1
    ls /tmp/report/allure-report/index.html && grep -l broken /tmp/report/allure-result/*.json | head -1'
```

预期：打印出 `index.html` 路径与一个含 `broken` 的 result.json。

- [ ] **Step 7: 更新 README，新增构建章节**

在 `README.md` 的「在 lynx / dailybuild 中运行」章节之前插入：

```markdown
## 构建测试镜像

```bash
docker build \
  --build-arg MESH_DOCS_REF=master \
  --build-arg OTEL_DOCS_REF=master \
  --build-arg TRACING_DOCS_REF=master \
  --build-arg IMAGE_TAG=local-dev \
  -t docs-runme-tests:local-dev .
```

镜像自包含：三个文档仓库按 ref 浅克隆进 `/app/`，`runme` / `violet` / `istioctl` 预置到
`bin/`（`istioctl` 版本从 mesh 文档的 runme 块推导，与 `install_istioctl` 的校验一致），
文档引用的 17 个外部 sample YAML 按 `lynx/assets-manifest.tsv` 落到 `assets/`。
构建期会跑 `lynx/check-manifest.sh` 与 `lynx/check-case-ids.sh`，任一不通过即构建失败。

tag 规则：`master` → `latest` + `master-<短 commit>`；`release-mesh-2.x` → 按
`lynx/release-matrix.tsv` 映射到 `release-<ACP 大版本>` + `<branch>-<短 commit>`。

文档仓库若为私有仓库，构建时加 `--build-arg GIT_TOKEN=<只读 token>`。
```

- [ ] **Step 8: 提交**

```bash
git add Dockerfile .dockerignore lynx/release-matrix.tsv README.md
git commit -m "feat: 测试镜像 Dockerfile

- ubuntu:22.04 基础镜像 + kubectl / jq / openssl / JRE + allure CLI 2.24.1
- 三个文档仓库构建期按 ref 浅克隆；runme / violet 预置；istioctl 版本从文档块推导
- 17 个外部 sample YAML 构建期落盘，check-manifest / check-case-ids 作为构建门禁
- .image-info 回填 RUNME_VERSION 与各仓库 ref，入口据此免去运行时下载"
```

---

### Task 11: Tekton 构建流水线

**Files:**
- Create: `.tekton/image-build.yaml`
- Modify: `lynx/release-matrix.tsv`（补注释说明流水线怎么用它）

**Interfaces:**
- Consumes: `Dockerfile`、`lynx/release-matrix.tsv`（Task 10）
- Produces: 推送到 `build-harbor.alauda.cn/asm/docs-runme-tests` 的镜像

> 参照仓库：`../servicemesh2-docs/.tekton/doc-build.yaml` 是同一套 PaC 约定的现成样例，
> 先读它确认 `pipelineRef.resolver: hub` 的实际用法与本组织可用的 Task 名。

- [ ] **Step 1: 读现有流水线，确认可复用的 Pipeline 与参数**

```bash
cat ../servicemesh2-docs/.tekton/doc-build.yaml
```

记录三件事：`pipelineRef` 的 `resolver` / `params`（用哪个 hub pipeline）、PaC 注解写法、以及 secret 是怎么引用的。下一步的 YAML 要与之保持一致——本仓库不发明新的流水线约定。

- [ ] **Step 2: 写 `.tekton/image-build.yaml`**

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: docs-runme-tests-image-build
  annotations:
    pipelinesascode.tekton.dev/on-comment: "^(/image-build)$"
    pipelinesascode.tekton.dev/cancel-in-progress: "true"
    pipelinesascode.tekton.dev/max-keep-runs: "10"
    pipelinesascode.tekton.dev/on-cel-expression: |-
      (
        event == "push" &&
        !last_commit_title.contains("ci skip") &&
        source_branch.matches("^(master|release-mesh-[0-9]+([.][0-9]+)+)$")
      )
spec:
  timeouts:
    pipeline: 2h
    tasks: 1h

  params:
    - name: git-url
      value: "{{ repo_url }}"
    - name: git-revision
      value: "{{ source_branch }}"
    - name: git-commit
      value: "{{ revision }}"
    - name: image-repo
      value: build-harbor.alauda.cn/asm/docs-runme-tests
    - name: dockerfile
      value: Dockerfile
    - name: platforms
      value: linux/amd64

  pipelineRef:
    resolver: hub
    params:
      - name: catalog
        value: alauda
      - name: type
        value: tekton
      - name: kind
        value: pipeline
      - name: name
        value: buildah-build-push
```

> `pipelineRef` 的 catalog / name 必须换成 Step 1 中实测可用的值。若组织内没有现成的
> 镜像构建 pipeline，退回到内联 `pipelineSpec`，用一个 `buildah` Task 完成
> build + push，参数与 Step 3 的 tag 脚本对齐。

- [ ] **Step 3: 在流水线中计算镜像 tag**

在 PipelineRun 的 `params` 中补一个 `image-tags` 参数，其取值由下面这段脚本产出。把脚本存到 `lynx/compute-tags.sh` 并在流水线的构建前置步骤中调用：

```bash
#!/usr/bin/env bash
# 依据当前分支与 commit 计算镜像 tag 列表（逗号分隔），供构建流水线使用
# 用法: bash lynx/compute-tags.sh <branch> <full-commit-sha>
set -u

branch="${1:?用法: compute-tags.sh <branch> <commit>}"
commit="${2:?用法: compute-tags.sh <branch> <commit>}"
short="${commit:0:7}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATRIX="$SCRIPT_DIR/release-matrix.tsv"

if [ "$branch" = "master" ]; then
    printf 'latest,master-%s\n' "$short"
    exit 0
fi

acp_version="$(awk -F'\t' -v b="$branch" '!/^#/ && $1 == b {print $2; exit}' "$MATRIX")"
if [ -z "$acp_version" ]; then
    printf '错误: 分支 %s 未在 %s 中登记对应的 ACP 大版本\n' "$branch" "$MATRIX" >&2
    exit 1
fi
printf 'release-%s,%s-%s\n' "$acp_version" "$branch" "$short"
```

本地验证：

```bash
chmod +x lynx/compute-tags.sh
bash lynx/compute-tags.sh master abcdef1234567890
bash lynx/compute-tags.sh release-mesh-2.2 abcdef1234567890
bash lynx/compute-tags.sh release-mesh-9.9 abcdef1234567890; echo "rc=$?"
```

预期依次输出：`latest,master-abcdef1`、`release-4.5,release-mesh-2.2-abcdef1`、未登记分支报错且 `rc=1`。

- [ ] **Step 4: 触发一次构建并确认镜像可拉**

推分支后在 PR 里评论 `/image-build` 触发，或直接 push 到 `master`。构建完成后：

```bash
docker pull build-harbor.alauda.cn/asm/docs-runme-tests:latest
docker run --rm build-harbor.alauda.cn/asm/docs-runme-tests:latest 2>&1 | tail -2
docker inspect build-harbor.alauda.cn/asm/docs-runme-tests:latest \
  --format '{{json .Config.Labels}}' | jq
```

预期：能拉取；打印用法提示；labels 里有三个文档 ref 与 runme 版本。

> 若推送因权限失败，需要找发版/CI 同学在 build-harbor 的 `asm` 命名空间给流水线
> ServiceAccount 授予 push 权限，并确认 PaC 侧的 registry secret 已挂载。

- [ ] **Step 5: 提交**

```bash
git add .tekton/image-build.yaml lynx/compute-tags.sh lynx/release-matrix.tsv
git commit -m "ci: 新增镜像构建流水线

- .tekton/image-build.yaml：push master / release-mesh-* 或评论 /image-build 触发
- lynx/compute-tags.sh：master→latest，release-mesh-x.y→按 release-matrix 映射 release-<ACP>
- 镜像推送到 build-harbor.alauda.cn/asm/docs-runme-tests"
```

---

### Task 12: release-config 模板增量（MR 草稿）

**Files（均在 `/workspaces/pod-3/repo/apt-test/release-config`）:**
- Modify: `enviroments/4.5.0/dailybuild/dailybuild_mircos_g1.yaml`
- Modify: `tests/4.5.0/dailybuild/dailybuild_mircos_g1.yaml`
- Modify: `releases/4.5.0/4-5-0-s9.yaml`

**Interfaces:**
- Consumes: 镜像 `build-harbor.alauda.cn/asm/docs-runme-tests:<tag>`（Task 10/11）；入口契约 `docs-test <init|mesh|otel|tracing>`（Task 8）
- Produces: dailybuild MicroOS 基准场景中的两个 ASM 业务集群与三个测试项

> 这一步动的是别人的仓库。**只产出改动并自检，不直接推送**——最后交给需求方 review 后提 MR。

- [ ] **Step 1: 读现有基准，确认要深复制的「基础设施基准」**

```bash
cd /workspaces/pod-3/repo/apt-test/release-config
git log --oneline -3
sed -n '105,160p' enviroments/4.5.0/dailybuild/dailybuild_mircos_g1.yaml
```

记录已有业务集群 region 的完整字段：`cluster_type`、`contract_version`、`provider`、
`machine_default_attributes`（含 `os` / `architecture` / `iaas_type` / `network_devices` /
`ssh_*`）、`network`、`registry`、`monitor` 系列、`load_balancer`。这些属于 Confluence 规则里的
「基准 2：目标场景基础设施基准」，**必须整段深复制**，只覆盖下一步列出的允许项。

- [ ] **Step 2: 新增两个 ASM 业务集群 region**

在 `enviroments/4.5.0/dailybuild/dailybuild_mircos_g1.yaml` 的 `spec.template.spec.regions`
末尾追加两个 region。除下表列出的覆盖项外，其余字段深复制自 Step 1 记录的业务集群。

| 字段 | `dailybuild-mircos-g1-asm-1` | `dailybuild-mircos-g1-asm-2` |
| --- | --- | --- |
| `name` | `dailybuild-mircos-g1-asm-1` | `dailybuild-mircos-g1-asm-2` |
| `display_name` | `DailyBuild 天翼云 MicroOS x86 ASM 文档测试主集群` | `DailyBuild 天翼云 MicroOS x86 ASM 文档测试第二集群` |
| `master_as_node` | `true` | `true` |
| `machine_default_attributes.cpu` | `16` | `8` |
| `machine_default_attributes.memory` | `32` | `16` |
| `machine_default_attributes.root_disk` | `300` | `100` |
| `nodes` | 3 × `role: master`（`master-0/1/2`） | 3 × `role: master`（`master-0/1/2`） |
| `log_storage` | `{component: es, scale: single}` | 不设置 |
| `other_vips` | `{ip_type: ipv4, number: 1}` | `{ip_type: ipv4, number: 1}` |
| `monitor` | 同基准业务集群（`victoriametrics-agent`） | 同基准业务集群 |
| `monitor_scale` | `Small` | `Small` |

两处偏离要在 MR 描述里写明：

1. asm-1 系统盘 300G 而非基准业务集群的 100G——`log_storage` 的硬要求（lynx 基线：业务集群部署 log_storage 时系统盘扩到 300G）。
2. asm-2 用 8C/16G 而非 `master_as_node` 基线的 16C/32G——它只承载 istiod、东西向网关与 helloworld/sleep，负载很轻；实测吃紧再上调。

- [ ] **Step 3: 新增 initials 与三个测试项**

在 `tests/4.5.0/dailybuild/dailybuild_mircos_g1.yaml` 的 `spec.template.spec.initials`
末尾追加两步（用 `run_after` 显式串联——不写 `run_after` 的 initials 是并发执行的）：

```yaml
      - name: asm-init-c1
        image: build-harbor.alauda.cn/asm/docs-runme-tests:latest
        region_name: dailybuild-mircos-g1-asm-1
        command: docs-test
        args:
          - init
        continue_on_error: false
        timeout: 1
        envs:
          - name: API_URL
            value: $API_URL
          - name: USERNAME
            value: $USERNAME
          - name: PASSWORD
            value: $PASSWORD
          - name: REGION_NAME
            value: dailybuild-mircos-g1-asm-1
          - name: GLOBAL_EXTERNAL_IPPOOL
            value: $GLOBAL_EXTERNAL_IPPOOL
          - name: GLOBAL_CLUSTER_NAME
            value: global
          - name: ENABLE_METALLB
            value: 'true'
          - name: USE_MESH_V2_TEST_SUITE_PLUGIN
            value: 'true'
      - name: asm-init-c2
        image: build-harbor.alauda.cn/asm/docs-runme-tests:latest
        region_name: dailybuild-mircos-g1-asm-2
        command: docs-test
        args:
          - init
        continue_on_error: false
        timeout: 1
        run_after:
          - asm-init-c1
        envs:
          - name: API_URL
            value: $API_URL
          - name: USERNAME
            value: $USERNAME
          - name: PASSWORD
            value: $PASSWORD
          - name: REGION_NAME
            value: dailybuild-mircos-g1-asm-2
          - name: GLOBAL_EXTERNAL_IPPOOL
            value: $GLOBAL_EXTERNAL_IPPOOL
          - name: GLOBAL_CLUSTER_NAME
            value: global
          - name: ENABLE_METALLB
            value: 'true'
          - name: USE_MESH_V2_TEST_SUITE_PLUGIN
            value: 'true'
```

在 `spec.template.spec.tests` 末尾追加三项。三项 `envs` 完全相同（lynx 只传该步骤自己声明过的变量，必须逐项重复），只有 `name` / `args` / `order` / `timeout` 不同：

```yaml
      - category: api
        name: docs-mesh
        image: build-harbor.alauda.cn/asm/docs-runme-tests:latest
        command: docs-test
        args:
          - mesh
        order: 0
        priority: 190
        timeout: 6
        region_name: dailybuild-mircos-g1-asm-1
        team: containerplatform
        envs: &asm-docs-envs
          - name: API_URL
            value: $API_URL
          - name: USERNAME
            value: $USERNAME
          - name: PASSWORD
            value: $PASSWORD
          - name: REGION_NAME
            value: dailybuild-mircos-g1-asm-1
          - name: EAST_CLUSTER_NAME
            value: dailybuild-mircos-g1-asm-1
          - name: WEST_CLUSTER_NAME
            value: dailybuild-mircos-g1-asm-2
          - name: GLOBAL_CLUSTER_NAME
            value: global
          - name: TRACING_ACP_ES_CLUSTER
            value: dailybuild-mircos-g1-asm-1
          - name: ACP_KUBECONFIG_MODE
            value: direct
          - name: ENABLE_METALLB
            value: 'true'
          - name: USE_MESH_V2_TEST_SUITE_PLUGIN
            value: 'true'
          - name: IS_DUAL_STACK
            value: 'false'
          - name: ENABLE_GW_LINUX_KERNEL_COMPAT
            value: 'false'
          - name: AUTO_GEN_BOOKINFO_TRAFFIC
            value: 'true'
          - name: CASE_TYPE
            value: smoke and not egress
          - name: RESOURCE_PREFIX
            value: asmdoc
          - name: WORKER_NUM
            value: '1'
      - category: api
        name: docs-otel
        image: build-harbor.alauda.cn/asm/docs-runme-tests:latest
        command: docs-test
        args:
          - otel
        order: 1
        priority: 190
        timeout: 2
        region_name: dailybuild-mircos-g1-asm-1
        team: containerplatform
        envs: *asm-docs-envs
      - category: api
        name: docs-tracing
        image: build-harbor.alauda.cn/asm/docs-runme-tests:latest
        command: docs-test
        args:
          - tracing
        order: 2
        priority: 190
        timeout: 2
        region_name: dailybuild-mircos-g1-asm-1
        team: containerplatform
        envs: *asm-docs-envs
```

> 若该仓库的 lint / kustomize 不接受 YAML 锚点（`&` / `*`），把 `envs` 三份展开写全。
> 用下一步的 `kustomize build` 确认。

- [ ] **Step 4: Release YAML 追加 L5 插件包**

在 `releases/4.5.0/4-5-0-s9.yaml` 中找到 `scene_number: db-mos-g1` 的 test_plan，在其
`release.initial.l5_plugin_packages` 追加以下条目（包地址取**正式发布版本**，且必须在
`https://package-minio-ctyun.alauda.cn:9002/` 可下载）：

| name | clusters | upload_stage |
| --- | --- | --- |
| `servicemesh-operator2` | `[dailybuild-mircos-g1-asm-1, dailybuild-mircos-g1-asm-2]` | `after-platform-deploy` |
| `kiali-operator` | 同上 | `after-platform-deploy` |
| `opentelemetry-operator2` | 同上 | `after-platform-deploy` |
| `jaeger` | `[global]`（集群插件包上架到 Global） | `after-platform-deploy` |
| `mesh-v2-test-suite` | `[global]`（同上） | `after-platform-deploy` |

`multus` / `metallb` / `metallb-operator` 按其插件层级走环境模板的 `plugin_packages` 或环境自带——
先确认基准 MicroOS 环境是否已带，已带则不重复声明。

- [ ] **Step 5: 自检**

```bash
cd /workspaces/pod-3/repo/apt-test/release-config
# 结构校验（该仓库的既有校验入口）
python3 script/sync_dailybuild_l5_lanes.py --check
# 若使用 kustomize 组织
kustomize build enviroments/4.5.0/dailybuild >/dev/null && echo "env kustomize OK"
kustomize build tests/4.5.0/dailybuild      >/dev/null && echo "tests kustomize OK"
# 测试项名唯一且命名合法 ^[0-9a-z][0-9a-z-]{0,30}[0-9a-z]$
grep -E '^\s+- name: ' tests/4.5.0/dailybuild/dailybuild_mircos_g1.yaml | sort | uniq -d
# tests[*].region_name 都能在环境模板里找到
grep -E 'region_name:' tests/4.5.0/dailybuild/dailybuild_mircos_g1.yaml | awk '{print $2}' | sort -u
grep -E '^\s+name: dailybuild-' enviroments/4.5.0/dailybuild/dailybuild_mircos_g1.yaml | awk '{print $2}' | sort -u
```

预期：`--check` 通过；kustomize 两条都 OK；测试项名无重复；测试项引用的 region 都在环境模板里存在。

- [ ] **Step 6: 产出 MR 描述草稿**

写到 `/workspaces/pod-3/repo/apt-test/release-config/.mr-draft-asm-docs.md`（不提交，仅供 review）：

```markdown
# dailybuild MicroOS 场景新增 ASM 文档自动化测试

## 改动
- 环境模板 `dailybuild_mircos_g1.yaml` 新增两个 ASM 专用业务集群：
  - `dailybuild-mircos-g1-asm-1`：3 节点 master_as_node，16C/32G/300G，
    `log_storage: {component: es, scale: single}`，`other_vips: {ipv4, number: 1}`
  - `dailybuild-mircos-g1-asm-2`：3 节点 master_as_node，8C/16G/100G，
    `other_vips: {ipv4, number: 1}`
- 测试模板新增 `initials`（asm-init-c1 → asm-init-c2）与三个测试项
  `docs-mesh` / `docs-otel` / `docs-tracing`（order 0/1/2 串行，共享 asm-1）
- Release YAML `db-mos-g1` scene 追加 5 个 L5 插件包

## 说明
- 测试镜像 `build-harbor.alauda.cn/asm/docs-runme-tests`，非 ares，
  产出 allure 到 `$TEST_RESULT_DIR`，符合自动化代码规范
- 首批只跑 `CASE_TYPE="smoke and not egress"`（单网格 + Ambient + otel + tracing ES 链），
  升级类与多集群类稳定后再放开，届时只改 `CASE_TYPE` 与 `timeout`
- 出口网关测试需要集群侧访问 httpbingo.org，离线环境下永久排除

## 两处基线偏离
1. asm-1 系统盘 300G（基准业务集群为 100G）——`log_storage` 的硬要求
2. asm-2 用 8C/16G（`master_as_node` 基线为 16C/32G）——只承载 istiod +
   东西向网关 + helloworld/sleep，负载很轻

## 两处自动化规范偏离（已在设计文档中记录）
1. `RESOURCE_PREFIX` 无法生效：文档测试用的是文档里写死的命名空间
   （bookinfo / istio-system / curl / jaeger-system），加前缀就不是在测文档了。
   隔离靠「ASM 专用集群 + 每个 Case 自带 cleanup」保证
2. `WORKER_NUM` 恒为 1：编排是有状态串行链，无法并行

## 待确认
- 天翼云 MicroOS provider 是否支持 `other_vips`（MicroOS 基准里从未用过）。
  若不支持，把两个测试项的 `ENABLE_METALLB` 改为 `false`，MetalLB / LoadBalancer
  网关 / 多集群东西向网关相关断言降级跳过，其余照常
```

- [ ] **Step 7: 交付 review，不推送**

```bash
cd /workspaces/pod-3/repo/apt-test/release-config
git status --short
git diff --stat
```

把 `git diff` 与 `.mr-draft-asm-docs.md` 一起交给需求方 review。**本任务不执行 `git commit` / `git push`**——该仓库归发版团队所有，由需求方确认后提 MR。

---

## 计划自检

**1. Spec 覆盖**

| 设计文档章节 | 对应任务 |
| --- | --- |
| §5.1 镜像与目录结构、基础镜像、构建流水线 | Task 10、11 |
| §5.2.1 入口契约 | Task 8 |
| §5.2.2 环境变量映射 | Task 8 |
| §5.2.3 CASE_TYPE 与标签 | Task 1、9 |
| §5.3 allure 报告后端 | Task 3 |
| §5.4 插件包 verify-only | Task 6 |
| §5.5 离线资产 | Task 4、5 |
| §5.6 MetalLB 地址池所有权 | Task 7 |
| §5.7 skip 二分类 | Task 2 |
| §6.1 EnvironmentTemplate 增量 | Task 12 Step 2 |
| §6.2 TestTemplate 增量 | Task 12 Step 3 |
| §6.3 Release YAML 增量 | Task 12 Step 4 |
| §7.3 退出码 / `EXIT_ON_TEST_FAILURE` | Task 3 Step 5、Task 8 Step 3 |
| §7.4 报告缺失的防御 | Task 8 Step 5（`trap _emergency_report`）、Task 10 Step 6（实测） |
| §8.1 规范偏离说明 | Task 12 Step 6（写进 MR 描述） |
| §9 case_id 编号规则 | Task 9 Step 1、2 |
| §10 交付阶段 1–4 | Task 1–9 / 10 / 11 / 12 |

设计文档 §10 的阶段 5（观察 2 周后放开 `update` / `multicluster`）不构成实施任务——它只改
`CASE_TYPE` 与 `timeout` 两个模板字段，架构已支持（Task 9 已把全部 Case 打好标签）。

**2. 占位符扫描**：无 TBD / TODO / "类似 Task N" / "适当处理错误"。Task 11 Step 2 的
`pipelineRef` 需按 Step 1 实测结果替换 catalog/name，已在该步骤显式写明替换来源与
退路（内联 `pipelineSpec`），不是留白。

**3. 类型一致性**

- `_case_type_matches` 返回码 0/1/2 → Task 1 定义、Task 1 Step 5 的 `case_selected` 消费，一致。
- `case_begin <id> <name> [tags]` → Task 1 定义，Task 9 全部调用点经 `case_begin_if` 传标签，一致。
- `case_skip <id> <name> <reason> [category]` → Task 2 定义，Task 1 的 `case_begin_if` 用 3 参形式（走默认 `expected`），Task 9 的环境跳过用 4 参形式传 `env`，一致。
- `_render_external_ip_pool <pool> <ns> <owner> <addr>...` 与 `create_external_ip_pool <cluster> <pool> <owner> <addr>...` → Task 7 内部一致，唯一调用点在 `setup_external_ip_pools`，同任务内已同步。
- `allure_emit_results` / `allure_emit_broken` / `allure_write_environment` / `allure_write_categories` / `allure_generate` / `allure_finalize` → Task 3 定义，Task 8 的 `_emergency_report` 消费其中四个，名称一致。
- `fetch_url_content` / `rewrite_urls_to_assets` / `runme_run_with_assets` → Task 4 定义，Task 4 Step 6（`kubectl_apply_with_mirror`）与 Task 5（9 处调用点）消费，一致。
- `_operator_csv_from_packagemanifest` → Task 6 定义并在同任务的 `install_operator` 中消费，一致。
- `.image-info` 的五个变量名 → Task 10 Step 3 写入、Task 8 Step 3 读取，一致。

