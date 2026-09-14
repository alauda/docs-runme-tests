# 测试结果统计完全重构 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用三层模型（Run → Case → DocTest）重构 docs-runme-tests 的测试结果统计子系统，跑完全部再汇总，产出美化终端摘要 + `summary.json` + `junit.xml`。

**Architecture:** 文件 Sink（`results.jsonl`，JSON Lines）+ jq 聚合。新增 `framework/report.sh` 承载全部统计逻辑：引擎 `run.sh` 写 doctest 记录，编排 `run-*-all.sh` 用 `case_*` 控边界，`report_finalize` 末尾聚合出三种输出。普通文档测试脚本零改动。

**Tech Stack:** Bash 3.2+、jq 1.7、coreutils（BSD/GNU 通用子集）。

## Global Constraints

每个 Task 的实现都隐含遵守以下约束（逐字取自 spec §2.2）：

- **同时支持 Linux + macOS**。
- **Bash 3.2 兼容**：禁用 `declare -A`、`mapfile`/`readarray`、`${var^^}`/`${var,,}`、`&>>`、`local -n`。
- **BSD/GNU 通用命令子集**：`date` 仅用 `date +%s` 与 `date +%Y%m%d-%H%M%S`，耗时用 Bash 算术 `$((end-start))`；禁用 `date -d`/`date -r`、`readlink -f`/`realpath`、`sed -i`、`grep -P`、`stat`。软链用 `ln -sfn`，临时目录用 `mktemp -d`。
- **JSON 一律用 jq 构造**（`--arg`/`--argjson` 自动转义），禁止手工拼接 JSON 字符串。
- **JUnit XML** 用 jq 的 `@html` 转义，`time` 用整数秒。
- 产物路径：`$FRAMEWORK_ROOT/tmp/runs/<run-id>/`（`tmp/` 已 gitignore）。
- **Git 提交**：commit message 用中文，**不用 amend，每次新 commit**（用户全局规则）；结尾加 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。

---

## File Structure

| 文件 | 动作 | 职责 |
| --- | --- | --- |
| `framework/report.sh` | Create | 统计与报告核心：`report_init`/`report_record_doctest`/`case_begin`/`case_end`/`case_end_fatal`/`case_skip`/`report_finalize` + 内部辅助 |
| `framework/tests/report_test.sh` | Create | report.sh 纯 bash 单元测试，可独立运行，不依赖集群 |
| `framework/common.sh` | Modify | 删除 `record_test_result`/`print_test_summary`/`TESTS_*`；新增 `skip_test` |
| `run.sh` | Modify | source report.sh；`run_test_script` 三态捕获 + 写记录；`main` 模式区分 + finalize |
| `run-mesh-all.sh` | Modify | 改用 `case_begin`/`case_end`/`case_end_fatal`/`case_skip` |
| `run-otel-all.sh` | Modify | 同上 |
| `run-tracing-all.sh` | Modify | 同上 |
| `opentelemetry-docs/docs/en/configuration/instrumentation/runme-test_java-instrumentation.sh` | Modify | `log_warn SKIPPED;return 0` → `skip_test` |
| `distributed-tracing-docs/docs/en/installing/runme-test_installing-distributed-tracing-opensearch.sh` | Modify | 同上 |
| `distributed-tracing-docs/docs/en/installing/runme-test_installing-distributed-tracing-elasticsearch.sh` | Modify | 同上 |
| `distributed-tracing-docs/docs/en/uninstalling/runme-test_uninstalling-distributed-tracing.sh` | Modify | 同上 |
| `README.md` | Modify | 更新「测试结果统计」章节 |

---

## Task 1: report.sh 骨架（生命周期 + 写入函数 + Case 边界 + 最小 finalize）

交付一个可加载、可跑通最小闭环的报告模块：能初始化 Run、写三类记录、给出最小汇总与正确退出码。同时建立单元测试框架。

**Files:**
- Create: `framework/report.sh`
- Create: `framework/tests/report_test.sh`

**Interfaces:**
- Consumes: `framework/common.sh` 的 `log_info/log_warn/log_error/log_success/log_header`；`framework/verify.sh` 的 `__cmp_contains/__cmp_same`（测试用）。
- Produces（供后续 Task 与 run.sh/编排使用）：
  - `report_init <project>` → 设置并导出 `RUNME_TEST_RUN_ID/RUNME_TEST_RUN_DIR/RUNME_TEST_PROJECT/RUNME_TEST_RUN_START`，建产物目录与空 `results.jsonl`。已初始化则幂等跳过。
  - `report_record_doctest <project> <file> <script> <phase> <status> <skip_reason> <fail_reason> <start_ts> <end_ts>` → 追加一行 `type=doctest`。
  - `case_begin <case_id> <case_name>` → 导出 `RUNME_TEST_CASE_ID/NAME`，记 `__CASE_START_TS`，`log_header`。
  - `case_end <rc>` → 写 `type=case`（rc=0→passed，否则 failed），失败不退出，清 case 上下文。
  - `case_end_fatal <rc>` → 同 case_end，但 rc≠0 时 `report_finalize` 后 `exit 1`。
  - `case_skip <case_id> <case_name> <reason>` → 写 `type=case_skip`。
  - `_doctest_name_from_script <path>` → `runme-test_<x>.sh` 解析出 `<x>`。
  - `report_finalize` → 读 `results.jsonl`，最小汇总，退出码：有 failed→1，否则 0。

- [ ] **Step 1: 写失败测试 — 创建 `framework/tests/report_test.sh`**

```bash
#!/usr/bin/env bash
# report.sh 单元测试（纯 bash，可独立运行，不依赖集群）
# 用法: bash framework/tests/report_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/report.sh"

T_PASS=0
T_FAIL=0

# check_contains <描述> <实际> <期望子串>
check_contains() {
    if __cmp_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# check_eq <描述> <实际> <期望>
check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 每个用例用独立的临时 RUN_DIR
new_sandbox() {
    unset RUNME_TEST_RUN_DIR RUNME_TEST_RUN_ID RUNME_TEST_CASE_ID RUNME_TEST_CASE_NAME
    RUNME_TEST_RUN_DIR="$(mktemp -d)"
    export RUNME_TEST_RUN_DIR
    : > "$RUNME_TEST_RUN_DIR/results.jsonl"
}

# ── 测试：_doctest_name_from_script 解析 ──
test_name_parse() {
    printf '\n== _doctest_name_from_script ==\n'
    check_eq "去前缀去后缀" "$(_doctest_name_from_script /a/b/runme-test_kiali.sh)" "kiali"
    check_eq "多段连字符" "$(_doctest_name_from_script runme-test_install-mesh.sh)" "install-mesh"
}

# ── 测试：写入 doctest 记录 ──
test_record_doctest() {
    printf '\n== report_record_doctest ==\n'
    new_sandbox
    report_record_doctest mesh kiali runme-test_kiali.sh test failed "" "pod 未就绪" 100 160
    local line; line="$(cat "$RUNME_TEST_RUN_DIR/results.jsonl")"
    check_contains "type=doctest" "$line" '"type":"doctest"'
    check_contains "file=kiali" "$line" '"file":"kiali"'
    check_contains "status=failed" "$line" '"status":"failed"'
    check_contains "duration=60" "$line" '"duration_s":60'
    rm -rf "$RUNME_TEST_RUN_DIR"
}

# ── 测试：case_skip 记录 ──
test_case_skip() {
    printf '\n== case_skip ==\n'
    new_sandbox
    case_skip 2 "双栈网格安装" "IS_DUAL_STACK != true" >/dev/null
    local line; line="$(cat "$RUNME_TEST_RUN_DIR/results.jsonl")"
    check_contains "type=case_skip" "$line" '"type":"case_skip"'
    check_contains "reason" "$line" '"skip_reason":"IS_DUAL_STACK != true"'
    rm -rf "$RUNME_TEST_RUN_DIR"
}

# ── 测试：最小 finalize 退出码 ──
test_finalize_exit() {
    printf '\n== report_finalize 退出码 ==\n'
    new_sandbox
    report_record_doctest mesh a x.sh test passed "" "" 1 2
    report_finalize >/dev/null 2>&1; check_eq "全通过→0" "$?" "0"
    new_sandbox
    report_record_doctest mesh a x.sh test failed "" "boom" 1 2
    report_finalize >/dev/null 2>&1; check_eq "有失败→1" "$?" "1"
    new_sandbox
    report_finalize >/dev/null 2>&1; check_eq "空结果→0" "$?" "0"
    rm -rf "$RUNME_TEST_RUN_DIR"
}

main() {
    test_name_parse
    test_record_doctest
    test_case_skip
    test_finalize_exit
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash framework/tests/report_test.sh`
Expected: FAIL —— 报错 `framework/report.sh: No such file or directory`（report.sh 尚未创建）。

- [ ] **Step 3: 创建 `framework/report.sh`（最小可用版）**

```bash
#!/usr/bin/env bash
# 测试结果统计与报告核心模块（三层：Run → Case → DocTest）
#
# 跨平台：Linux + macOS（Bash 3.2 / BSD 工具子集，见 spec §2.2）
# 数据流：引擎/编排向 results.jsonl 追加 JSON 行 → report_finalize 用 jq 聚合
#         产出 终端摘要 + summary.json + junit.xml。
#
# 依赖：framework/common.sh 的 log_* 函数（调用方须先 source common.sh）。

# ── 内部：向 results.jsonl 追加一行 ──
_report_append() {
    if [ -z "${RUNME_TEST_RUN_DIR:-}" ]; then
        log_warn "RUNME_TEST_RUN_DIR 未设置，结果记录被丢弃"
        return 0
    fi
    printf '%s\n' "$1" >> "$RUNME_TEST_RUN_DIR/results.jsonl"
}

# ── 内部：runme-test_<x>.sh -> <x> ──
_doctest_name_from_script() {
    local name
    name="$(basename "$1")"
    name="${name#runme-test_}"
    name="${name%.sh}"
    printf '%s' "$name"
}

# ── report_init <project> ──
report_init() {
    local project="$1"
    : "${project:?report_init 需要 project 参数}"

    # 幂等：编排模式下父进程已 init 并导出 RUNME_TEST_RUN_DIR，子进程继承后跳过
    if [ -n "${RUNME_TEST_RUN_DIR:-}" ] && [ -d "${RUNME_TEST_RUN_DIR:-/nonexistent}" ]; then
        return 0
    fi

    local runs_root="${FRAMEWORK_ROOT:-$(pwd)}/tmp/runs"
    local run_id
    run_id="$(date +%Y%m%d-%H%M%S)"
    if [ -d "$runs_root/$run_id" ]; then
        run_id="${run_id}-$$"
    fi

    local run_dir="$runs_root/$run_id"
    mkdir -p "$run_dir" || { log_error "无法创建报告目录: $run_dir"; return 1; }
    ln -sfn "$run_id" "$runs_root/latest" 2>/dev/null || true
    : > "$run_dir/results.jsonl"

    RUNME_TEST_RUN_ID="$run_id"
    RUNME_TEST_RUN_DIR="$run_dir"
    RUNME_TEST_PROJECT="$project"
    RUNME_TEST_RUN_START="$(date +%s)"
    export RUNME_TEST_RUN_ID RUNME_TEST_RUN_DIR RUNME_TEST_PROJECT RUNME_TEST_RUN_START
    log_info "报告目录: $run_dir"
    return 0
}

# ── report_record_doctest <project> <file> <script> <phase> <status> <skip_reason> <fail_reason> <start_ts> <end_ts> ──
report_record_doctest() {
    local project="$1" file="$2" script="$3" phase="$4" status="$5"
    local skip_reason="$6" fail_reason="$7" start_ts="$8" end_ts="$9"
    local duration=$(( end_ts - start_ts ))
    _report_append "$(jq -nc \
        --arg type "doctest" --arg project "$project" --arg file "$file" \
        --arg script "$script" --arg case_id "${RUNME_TEST_CASE_ID:-}" \
        --arg case_name "${RUNME_TEST_CASE_NAME:-}" --arg phase "$phase" \
        --arg status "$status" --arg skip_reason "$skip_reason" --arg fail_reason "$fail_reason" \
        --argjson start_ts "$start_ts" --argjson end_ts "$end_ts" --argjson duration_s "$duration" \
        '{type:$type,project:$project,file:$file,script:$script,case_id:$case_id,case_name:$case_name,phase:$phase,status:$status,skip_reason:$skip_reason,fail_reason:$fail_reason,start_ts:$start_ts,end_ts:$end_ts,duration_s:$duration_s}')"
}

# ── case_begin <case_id> <case_name> ──
case_begin() {
    RUNME_TEST_CASE_ID="$1"
    RUNME_TEST_CASE_NAME="$2"
    export RUNME_TEST_CASE_ID RUNME_TEST_CASE_NAME
    __CASE_START_TS="$(date +%s)"
    log_header "Case $1: $2"
}

# ── 内部：写 type=case 记录 ──
_case_record() {
    local status="$1" end_ts duration
    end_ts="$(date +%s)"
    duration=$(( end_ts - ${__CASE_START_TS:-$end_ts} ))
    _report_append "$(jq -nc \
        --arg type "case" --arg case_id "${RUNME_TEST_CASE_ID:-}" \
        --arg case_name "${RUNME_TEST_CASE_NAME:-}" --arg status "$status" \
        --argjson duration_s "$duration" \
        '{type:$type,case_id:$case_id,case_name:$case_name,status:$status,duration_s:$duration_s}')"
}

# ── case_end <rc>：普通 Case，失败仅记录、不退出 ──
case_end() {
    if [ "$1" -eq 0 ]; then
        _case_record "passed"
        log_success "Case ${RUNME_TEST_CASE_ID:-?}: ${RUNME_TEST_CASE_NAME:-} 通过"
    else
        _case_record "failed"
        log_error "Case ${RUNME_TEST_CASE_ID:-?}: ${RUNME_TEST_CASE_NAME:-} 失败（继续后续 Case）"
    fi
    unset RUNME_TEST_CASE_ID RUNME_TEST_CASE_NAME
    return 0
}

# ── case_end_fatal <rc>：致命前置 Case，失败则 finalize + exit ──
case_end_fatal() {
    if [ "$1" -eq 0 ]; then
        _case_record "passed"
        log_success "Case ${RUNME_TEST_CASE_ID:-?}: ${RUNME_TEST_CASE_NAME:-} 通过"
        unset RUNME_TEST_CASE_ID RUNME_TEST_CASE_NAME
        return 0
    fi
    _case_record "failed"
    log_error "致命前置 Case ${RUNME_TEST_CASE_ID:-?}: ${RUNME_TEST_CASE_NAME:-} 失败，中止整个 Run"
    report_finalize
    exit 1
}

# ── case_skip <case_id> <case_name> <reason> ──
case_skip() {
    _report_append "$(jq -nc \
        --arg type "case_skip" --arg case_id "$1" --arg case_name "$2" --arg skip_reason "$3" \
        '{type:$type,case_id:$case_id,case_name:$case_name,skip_reason:$skip_reason}')"
    log_warn "Case $1: $2 —— SKIPPED（$3）"
}

# ── report_finalize（最小版；Task 2/3/4 增强）──
report_finalize() {
    local results="${RUNME_TEST_RUN_DIR:-}/results.jsonl"
    if [ -z "${RUNME_TEST_RUN_DIR:-}" ] || [ ! -f "$results" ]; then
        log_warn "无结果数据，跳过汇总"; return 0
    fi
    if [ ! -s "$results" ]; then
        log_warn "未执行任何测试（results.jsonl 为空）"; return 0
    fi

    local dt_total dt_failed case_failed
    dt_total=$(jq -s 'map(select(.type=="doctest"))|length' "$results")
    dt_failed=$(jq -s 'map(select(.type=="doctest" and .status=="failed"))|length' "$results")
    case_failed=$(jq -s 'map(select(.type=="case" and .status=="failed"))|length' "$results")

    echo ""
    echo "测试汇总：DocTest 共 $dt_total，失败 $dt_failed"
    echo "报告目录：$RUNME_TEST_RUN_DIR"

    if [ "$dt_failed" -gt 0 ] || [ "$case_failed" -gt 0 ]; then
        return 1
    fi
    return 0
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash framework/tests/report_test.sh`
Expected: PASS —— 末尾 `通过: N  失败: 0`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add framework/report.sh framework/tests/report_test.sh
git commit -m "feat(report): 新增 report.sh 骨架与单元测试框架

report_init/写入函数/case_* 边界/最小 finalize，跨平台 Bash 3.2 兼容。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: report_finalize 三层聚合 + summary.json

把 `report_finalize` 升级为完整三层聚合，写出 `summary.json`。聚合 jq 已实测验证。

**Files:**
- Modify: `framework/report.sh`（新增 `_report_aggregate`，重写 `report_finalize`）
- Modify: `framework/tests/report_test.sh`（新增 summary.json 断言）

**Interfaces:**
- Consumes: Task 1 的 `results.jsonl` 三类记录、`RUNME_TEST_RUN_ID/PROJECT/RUN_START`。
- Produces: `_report_aggregate <results-file>` → stdout 打印 summary JSON（三层结构，字段见下）；`report_finalize` 写 `$RUNME_TEST_RUN_DIR/summary.json`。

- [ ] **Step 1: 写失败测试 — 在 `report_test.sh` 的 `main()` 调用前新增 `test_aggregate`，并加入 `main`**

在 `main()` 定义上方插入：

```bash
# ── 测试：三层聚合 summary.json ──
test_aggregate() {
    printf '\n== _report_aggregate / summary.json ==\n'
    new_sandbox
    RUNME_TEST_RUN_ID="testrun"; RUNME_TEST_PROJECT="mesh"; RUNME_TEST_RUN_START=100
    export RUNME_TEST_RUN_ID RUNME_TEST_PROJECT RUNME_TEST_RUN_START
    # 构造：init case(passed,无doctest) / case_skip / 普通case(passed+skipped+failed)
    printf '%s\n' \
      '{"type":"case","case_id":"1","case_name":"初始化","status":"passed","duration_s":130}' \
      '{"type":"case_skip","case_id":"2","case_name":"双栈","skip_reason":"IS_DUAL_STACK != true"}' \
      '{"type":"doctest","project":"mesh","file":"install-mesh","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"passed","skip_reason":"","fail_reason":"","start_ts":100,"end_ts":280,"duration_s":180}' \
      '{"type":"doctest","project":"tracing","file":"es","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"skipped","skip_reason":"未配置 ES","fail_reason":"","start_ts":280,"end_ts":281,"duration_s":1}' \
      '{"type":"doctest","project":"mesh","file":"kiali","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"failed","skip_reason":"","fail_reason":"pod 未就绪","start_ts":281,"end_ts":791,"duration_s":510}' \
      '{"type":"case","case_id":"3","case_name":"单网格","status":"failed","duration_s":691}' \
      > "$RUNME_TEST_RUN_DIR/results.jsonl"

    report_finalize >/dev/null 2>&1
    local s; s="$(cat "$RUNME_TEST_RUN_DIR/summary.json")"
    check_eq "doctests.total"   "$(printf '%s' "$s" | jq -r '.totals.doctests.total')"   "3"
    check_eq "doctests.failed"  "$(printf '%s' "$s" | jq -r '.totals.doctests.failed')"  "1"
    check_eq "doctests.skipped" "$(printf '%s' "$s" | jq -r '.totals.doctests.skipped')" "1"
    check_eq "cases.total"      "$(printf '%s' "$s" | jq -r '.totals.cases.total')"      "3"
    check_eq "cases.skipped"    "$(printf '%s' "$s" | jq -r '.totals.cases.skipped')"    "1"
    check_eq "result"           "$(printf '%s' "$s" | jq -r '.result')"                  "failed"
    check_eq "case3 明细数"     "$(printf '%s' "$s" | jq -r '.cases[] | select(.case_id=="3") | .doctests | length')" "3"
    check_eq "case2 跳过原因"   "$(printf '%s' "$s" | jq -r '.cases[] | select(.case_id=="2") | .skip_reason')" "IS_DUAL_STACK != true"
    rm -rf "$RUNME_TEST_RUN_DIR"
}
```

并在 `main()` 中 `test_finalize_exit` 之后加一行 `test_aggregate`。

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash framework/tests/report_test.sh`
Expected: FAIL —— `summary.json` 不存在 / 字段为空（最小 finalize 未写 summary.json）。

- [ ] **Step 3: 在 `framework/report.sh` 新增 `_report_aggregate`（放在 `report_finalize` 之前）**

```bash
# ── 内部：三层聚合，stdout 输出 summary JSON ──
# 用法: _report_aggregate <results.jsonl>
_report_aggregate() {
    local results="$1"
    local prog
    prog=$(cat <<'JQ'
. as $rows
| (reduce $rows[] as $r ([];
    if ($r.type=="case" or $r.type=="case_skip")
    then . + [{case_id:$r.case_id, case_name:$r.case_name,
               status:(if $r.type=="case_skip" then "skipped" else $r.status end),
               duration_s:($r.duration_s // 0), is_skip:($r.type=="case_skip"),
               skip_reason:($r.skip_reason // "")}]
    else . end)) as $cases0
| ([$cases0[].case_id]) as $known
| (reduce $rows[] as $r ([];
    if ($r.type=="doctest" and (($known|index($r.case_id))==null) and ((index($r.case_id))==null))
    then . + [$r.case_id] else . end)) as $orphan_ids
| ($cases0 + ($orphan_ids | map({case_id:., case_name:(if .=="" then "（无 Case）" else . end),
                                 status:"pending", duration_s:0, is_skip:false, skip_reason:""}))) as $cases1
| ($cases1 | map(
    .case_id as $cid | .is_skip as $isskip
    | ([$rows[] | select(.type=="doctest" and .case_id==$cid)
        | {project,file,status,duration_s,fail_reason,skip_reason}]) as $dts
    | . + {doctests:$dts}
    | .status = (if $isskip then "skipped"
                 elif .status=="pending" then
                   (if ($dts|map(select(.status=="failed"))|length)>0 then "failed"
                    elif ($dts|map(select(.status=="passed"))|length)>0 then "passed"
                    else "skipped" end)
                 else .status end)
  )) as $cases
| {run_id:$run_id, project:$project, started_at:$started_at, duration_s:$duration_s,
   totals:{
     cases:{total:($cases|length),
            passed:($cases|map(select(.status=="passed"))|length),
            failed:($cases|map(select(.status=="failed"))|length),
            skipped:($cases|map(select(.status=="skipped"))|length)},
     doctests:{total:($rows|map(select(.type=="doctest"))|length),
               passed:($rows|map(select(.type=="doctest" and .status=="passed"))|length),
               failed:($rows|map(select(.type=="doctest" and .status=="failed"))|length),
               skipped:($rows|map(select(.type=="doctest" and .status=="skipped"))|length)}},
   result:(if ($cases|map(select(.status=="failed"))|length)>0
              or ($rows|map(select(.type=="doctest" and .status=="failed"))|length)>0
           then "failed" else "passed" end),
   cases:($cases|map(del(.is_skip)))}
JQ
)
    local now started dur
    now="$(date +%s)"
    started="${RUNME_TEST_RUN_START:-$now}"
    dur=$(( now - started ))
    jq -s \
        --arg run_id "${RUNME_TEST_RUN_ID:-unknown}" \
        --arg project "${RUNME_TEST_PROJECT:-unknown}" \
        --argjson started_at "$started" \
        --argjson duration_s "$dur" \
        "$prog" "$results"
}
```

- [ ] **Step 4: 重写 `framework/report.sh` 的 `report_finalize`（替换 Task 1 的最小版）**

```bash
# ── report_finalize（聚合 + 写 summary.json；Task 3/4 继续增强）──
report_finalize() {
    local results="${RUNME_TEST_RUN_DIR:-}/results.jsonl"
    if [ -z "${RUNME_TEST_RUN_DIR:-}" ] || [ ! -f "$results" ]; then
        log_warn "无结果数据，跳过汇总"; return 0
    fi
    if [ ! -s "$results" ]; then
        log_warn "未执行任何测试（results.jsonl 为空）"; return 0
    fi

    local summary
    summary="$(_report_aggregate "$results")"
    printf '%s\n' "$summary" > "$RUNME_TEST_RUN_DIR/summary.json"

    local dt_total dt_failed result
    dt_total="$(printf '%s' "$summary" | jq -r '.totals.doctests.total')"
    dt_failed="$(printf '%s' "$summary" | jq -r '.totals.doctests.failed')"
    result="$(printf '%s' "$summary" | jq -r '.result')"

    echo ""
    echo "测试汇总：DocTest 共 $dt_total，失败 $dt_failed（result=$result）"
    echo "报告目录：$RUNME_TEST_RUN_DIR"

    [ "$result" = "failed" ] && return 1
    return 0
}
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash framework/tests/report_test.sh`
Expected: PASS —— 含 `test_aggregate` 全部断言，`失败: 0`。

- [ ] **Step 6: 提交**

```bash
git add framework/report.sh framework/tests/report_test.sh
git commit -m "feat(report): report_finalize 三层聚合并写出 summary.json

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: report_finalize 生成 junit.xml

从 summary JSON 生成标准 JUnit XML。生成 jq 已实测（含 `@html` 转义）。

**Files:**
- Modify: `framework/report.sh`（新增 `_report_write_junit`，`report_finalize` 增一步）
- Modify: `framework/tests/report_test.sh`（新增 junit.xml 断言）

**Interfaces:**
- Consumes: Task 2 的 summary JSON 结构。
- Produces: `_report_write_junit <summary-json-string>` → stdout 打印 JUnit XML；`report_finalize` 写 `$RUNME_TEST_RUN_DIR/junit.xml`。

- [ ] **Step 1: 写失败测试 — 在 `report_test.sh` 新增 `test_junit`，加入 `main`**

在 `main()` 上方插入：

```bash
# ── 测试：junit.xml 生成与转义 ──
test_junit() {
    printf '\n== junit.xml ==\n'
    new_sandbox
    RUNME_TEST_RUN_ID="testrun"; RUNME_TEST_PROJECT="mesh"; RUNME_TEST_RUN_START=100
    export RUNME_TEST_RUN_ID RUNME_TEST_PROJECT RUNME_TEST_RUN_START
    printf '%s\n' \
      '{"type":"case_skip","case_id":"2","case_name":"双栈","skip_reason":"IS_DUAL_STACK != true"}' \
      '{"type":"doctest","project":"mesh","file":"kiali","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"failed","skip_reason":"","fail_reason":"pod <a & b>","start_ts":1,"end_ts":3,"duration_s":2}' \
      '{"type":"case","case_id":"3","case_name":"单网格","status":"failed","duration_s":2}' \
      > "$RUNME_TEST_RUN_DIR/results.jsonl"

    report_finalize >/dev/null 2>&1
    local x; x="$(cat "$RUNME_TEST_RUN_DIR/junit.xml")"
    check_contains "XML 头" "$x" '<?xml version="1.0" encoding="UTF-8"?>'
    check_contains "testsuites" "$x" '<testsuites name="mesh"'
    check_contains "testcase 命名" "$x" 'name="mesh/kiali"'
    check_contains "failure 元素" "$x" '<failure message='
    check_contains "XML 转义" "$x" 'pod &lt;a &amp; b&gt;'
    check_contains "skipped 占位" "$x" '<skipped message="IS_DUAL_STACK != true">'
    rm -rf "$RUNME_TEST_RUN_DIR"
}
```

并在 `main()` 的 `test_aggregate` 之后加一行 `test_junit`。

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash framework/tests/report_test.sh`
Expected: FAIL —— `junit.xml` 不存在。

- [ ] **Step 3: 在 `framework/report.sh` 新增 `_report_write_junit`（放在 `report_finalize` 之前）**

```bash
# ── 内部：从 summary JSON 生成 JUnit XML，stdout 输出 ──
# 用法: _report_write_junit <summary-json-string>
_report_write_junit() {
    local prog
    prog=$(cat <<'JQ'
"<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
"<testsuites name=\"\(.project|@html)\" tests=\"\(.totals.doctests.total)\" failures=\"\(.totals.doctests.failed)\" skipped=\"\(.totals.doctests.skipped)\" time=\"\(.duration_s)\">",
(.cases[] |
  .case_id as $cid | .case_name as $cname | .status as $cstatus | .duration_s as $cdur | (.skip_reason // "") as $creason |
  .doctests as $dts |
  (if ($dts|length)>0 then ($dts|length) else 1 end) as $tests |
  (if ($dts|length)>0 then ($dts|map(select(.status=="failed"))|length) else (if $cstatus=="failed" then 1 else 0 end) end) as $fails |
  (if ($dts|length)>0 then ($dts|map(select(.status=="skipped"))|length) else (if $cstatus=="skipped" then 1 else 0 end) end) as $skips |
  "  <testsuite name=\"Case \($cid): \($cname|@html)\" tests=\"\($tests)\" failures=\"\($fails)\" skipped=\"\($skips)\" time=\"\($cdur)\">",
  (if ($dts|length)>0 then
    ($dts[] |
      "    <testcase name=\"\(.project)/\(.file|@html)\" classname=\"Case\($cid)\" time=\"\(.duration_s)\">",
      (if .status=="failed" then "      <failure message=\"\((.fail_reason//"")|@html)\"></failure>"
       elif .status=="skipped" then "      <skipped message=\"\((.skip_reason//"")|@html)\"></skipped>"
       else empty end),
      "    </testcase>")
   else
    "    <testcase name=\"\($cname|@html)\" classname=\"Case\($cid)\" time=\"\($cdur)\">",
    (if $cstatus=="failed" then "      <failure message=\"Case failed\"></failure>"
     elif $cstatus=="skipped" then "      <skipped message=\"\($creason|@html)\"></skipped>"
     else empty end),
    "    </testcase>"
   end),
  "  </testsuite>"
),
"</testsuites>"
JQ
)
    printf '%s' "$1" | jq -r "$prog"
}
```

- [ ] **Step 4: 在 `report_finalize` 写完 summary.json 后增加一步生成 junit.xml**

在 `report_finalize` 中 `printf '%s\n' "$summary" > "$RUNME_TEST_RUN_DIR/summary.json"` 这一行之后，紧接着插入：

```bash
    _report_write_junit "$summary" > "$RUNME_TEST_RUN_DIR/junit.xml"
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash framework/tests/report_test.sh`
Expected: PASS —— 含 `test_junit` 全部断言，`失败: 0`。

- [ ] **Step 6: 提交**

```bash
git add framework/report.sh framework/tests/report_test.sh
git commit -m "feat(report): report_finalize 生成标准 junit.xml（含 XML 转义）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 美化终端摘要

把终端输出从「一行汇总」升级为三层美化摘要（两套计数 + 每 Case 一行 + 失败/跳过明细）。

**Files:**
- Modify: `framework/report.sh`（新增 `_report_print_terminal`，`report_finalize` 增一步）
- Modify: `framework/tests/report_test.sh`（新增终端输出断言）

**Interfaces:**
- Consumes: Task 2 的 summary JSON。
- Produces: `_report_print_terminal <summary-json-string>` → stdout 打印美化摘要。

- [ ] **Step 1: 写失败测试 — 在 `report_test.sh` 新增 `test_terminal`，加入 `main`**

在 `main()` 上方插入：

```bash
# ── 测试：终端摘要 ──
test_terminal() {
    printf '\n== 终端摘要 ==\n'
    new_sandbox
    RUNME_TEST_RUN_ID="testrun"; RUNME_TEST_PROJECT="mesh"; RUNME_TEST_RUN_START=100
    export RUNME_TEST_RUN_ID RUNME_TEST_PROJECT RUNME_TEST_RUN_START
    printf '%s\n' \
      '{"type":"case_skip","case_id":"2","case_name":"双栈","skip_reason":"IS_DUAL_STACK != true"}' \
      '{"type":"doctest","project":"mesh","file":"kiali","script":"x.sh","case_id":"3","case_name":"单网格","phase":"test","status":"failed","skip_reason":"","fail_reason":"pod 未就绪","start_ts":1,"end_ts":131,"duration_s":130}' \
      '{"type":"case","case_id":"3","case_name":"单网格","status":"failed","duration_s":130}' \
      > "$RUNME_TEST_RUN_DIR/results.jsonl"

    local out; out="$(report_finalize 2>&1)"
    check_contains "标题" "$out" "测试运行汇总"
    check_contains "Case 计数行" "$out" "Case"
    check_contains "文档测试计数行" "$out" "文档测试"
    check_contains "失败明细含文件" "$out" "mesh/kiali"
    check_contains "失败原因" "$out" "pod 未就绪"
    check_contains "跳过明细" "$out" "双栈"
    check_contains "耗时格式" "$out" "2m10s"
    rm -rf "$RUNME_TEST_RUN_DIR"
}
```

并在 `main()` 的 `test_junit` 之后加一行 `test_terminal`。

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash framework/tests/report_test.sh`
Expected: FAIL —— 输出仅含 Task 2 的「测试汇总：DocTest 共 ...」，不含「测试运行汇总」标题与明细。

- [ ] **Step 3: 在 `framework/report.sh` 新增 `_report_print_terminal`（放在 `report_finalize` 之前）**

```bash
# ── 内部：从 summary JSON 渲染美化终端摘要，stdout 输出 ──
# 用法: _report_print_terminal <summary-json-string>
_report_print_terminal() {
    local prog
    prog=$(cat <<'JQ'
def fmtdur: . as $t | ($t/60|floor) as $m | ($t%60) as $s | (if $m>0 then "\($m)m\($s)s" else "\($s)s" end);
def icon: if .=="passed" then "PASS" elif .=="failed" then "FAIL" else "SKIP" end;
"================================================================",
"  测试运行汇总   run-id: \(.run_id)   项目: \(.project)",
"================================================================",
"  总耗时 \(.duration_s|fmtdur)",
"  Case      \(.totals.cases.total)   ✓\(.totals.cases.passed)  ✗\(.totals.cases.failed)  ⊘\(.totals.cases.skipped)",
"  文档测试  \(.totals.doctests.total)   ✓\(.totals.doctests.passed)  ✗\(.totals.doctests.failed)  ⊘\(.totals.doctests.skipped)",
"----------------------------------------------------------------",
(.cases[] |
  (.doctests|map(select(.status=="passed"))|length) as $p |
  (.doctests|map(select(.status=="failed"))|length) as $f |
  (.doctests|map(select(.status=="skipped"))|length) as $s |
  "  [\(.status|icon)] Case \(.case_id): \(.case_name)   ✓\($p) ✗\($f) ⊘\($s)   \(.duration_s|fmtdur)"
),
"----------------------------------------------------------------",
"  ✗ 失败明细",
(([.cases[] | .case_id as $cid | .doctests[] | select(.status=="failed")
   | "    [Case\($cid)] \(.project)/\(.file)   \(.duration_s|fmtdur)   \(.fail_reason)"]) as $f
 | if ($f|length)==0 then "    （无）" else $f[] end),
"  ⊘ 跳过明细",
(([.cases[] | select(.status=="skipped") | "    [Case\(.case_id)] \(.case_name)   \(.skip_reason)"]
  + [.cases[] | .case_id as $cid | .doctests[] | select(.status=="skipped")
     | "    [Case\($cid)] \(.project)/\(.file)   \(.skip_reason)"]) as $s
 | if ($s|length)==0 then "    （无）" else $s[] end),
"================================================================",
"  结果: \(.result)",
"================================================================"
JQ
)
    printf '%s' "$1" | jq -r "$prog"
}
```

- [ ] **Step 4: 重写 `report_finalize` 的输出部分**

把 `report_finalize` 中从 `local dt_total dt_failed result` 起、到函数末尾 `return 0` 之前的输出块，替换为：

```bash
    local result
    result="$(printf '%s' "$summary" | jq -r '.result')"

    echo ""
    _report_print_terminal "$summary"
    echo "  报告目录: $RUNME_TEST_RUN_DIR"

    [ "$result" = "failed" ] && return 1
    return 0
```

（即 `report_finalize` 最终形态：守卫 → 聚合写 summary.json → 写 junit.xml → 渲染终端 → 退出码。）

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash framework/tests/report_test.sh`
Expected: PASS —— 含 `test_terminal` 全部断言，`失败: 0`。

- [ ] **Step 6: 提交**

```bash
git add framework/report.sh framework/tests/report_test.sh
git commit -m "feat(report): 美化三层终端摘要（两套计数 + 每 Case 一行 + 失败/跳过明细）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: common.sh —— 删除旧三件套，新增 skip_test

**Files:**
- Modify: `framework/common.sh:103-140`（删除旧统计）；新增 `skip_test`

**Interfaces:**
- Produces: `skip_test <reason>` → 设置 `__TEST_SKIPPED=1` 与 `__TEST_SKIP_REASON`，`log_warn "SKIPPED: <reason>"`，`return 0`。供文档测试脚本与 run.sh 使用。
- Removes: `record_test_result`、`print_test_summary`、`TESTS_TOTAL/PASSED/FAILED`（由 report.sh 取代）。

- [ ] **Step 1: 写失败测试 — 在 `report_test.sh` 新增 `test_skip_test`，加入 `main`**

在 `main()` 上方插入：

```bash
# ── 测试：skip_test 设置跳过标记 ──
test_skip_test() {
    printf '\n== skip_test ==\n'
    __TEST_SKIPPED=0; __TEST_SKIP_REASON=""
    skip_test "缺少 FOO 环境变量" >/dev/null 2>&1
    check_eq "标记置位" "$__TEST_SKIPPED" "1"
    check_eq "原因记录" "$__TEST_SKIP_REASON" "缺少 FOO 环境变量"
}
```

并在 `main()` 起始处加一行 `test_skip_test`。

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash framework/tests/report_test.sh`
Expected: FAIL —— `skip_test: command not found`（尚未定义）。

- [ ] **Step 3: 删除 `framework/common.sh` 的旧统计块**

删除第 103-140 行整块（从注释 `# 测试结果统计` 到 `print_test_summary` 函数结束的 `}`），即变量 `TESTS_TOTAL/PASSED/FAILED`、函数 `record_test_result`、`print_test_summary`。

- [ ] **Step 4: 在 `framework/common.sh` 原位置新增 `skip_test`**

在删除处插入：

```bash
# 文档测试脚本主动声明「跳过」：设置标记后 return 0；
# 引擎 run.sh 检测 __TEST_SKIPPED 后将该 DocTest 记为 status=skipped。
skip_test() {
    __TEST_SKIPPED=1
    __TEST_SKIP_REASON="$1"
    log_warn "SKIPPED: $1"
    return 0
}
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash framework/tests/report_test.sh`
Expected: PASS —— 含 `test_skip_test`，`失败: 0`。

- [ ] **Step 6: 确认无残留引用**

Run: `grep -rn "record_test_result\|print_test_summary\|TESTS_TOTAL" framework/ run.sh`
Expected: 仅 `run.sh` 仍有引用（将在 Task 6 清理）；`framework/` 下无残留。

- [ ] **Step 7: 提交**

```bash
git add framework/common.sh framework/tests/report_test.sh
git commit -m "refactor(common): 移除旧统计三件套，新增 skip_test 第三态辅助

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: run.sh 引擎改造

引擎计时、捕获三态（passed/failed/skipped）、写 doctest 记录；`main` 区分编排/单跑模式，单跑自行 init+finalize，退出码反映成败。

**Files:**
- Modify: `run.sh:17-21`（source report.sh）、`run.sh:279-347`（`run_test_script`）、`run.sh:454-466`（`main` 结尾）

**Interfaces:**
- Consumes: report.sh 的 `report_init`/`report_record_doctest`/`report_finalize`、`_doctest_name_from_script`；common.sh 的 `skip_test` 设置的 `__TEST_SKIPPED`/`__TEST_SKIP_REASON`。
- Produces: 每个 `./run.sh --file` 向 `results.jsonl` 追加一条 doctest 记录；编排模式退出码 = 该 DocTest 成败（skip 视为成功，退出 0）。

- [ ] **Step 1: source report.sh**

在 `run.sh` 第 19 行 `source "$FRAMEWORK_DIR/verify.sh"` 之后插入：

```bash
source "$FRAMEWORK_DIR/report.sh"
```

- [ ] **Step 2: 改造 `run_test_script`（第 279-347 行整体替换）**

```bash
# 执行单个测试脚本，捕获三态并写入结果记录
run_test_script() {
    local test_script="$1"
    local script_name file phase
    script_name=$(basename "$test_script")
    file="$(_doctest_name_from_script "$test_script")"
    if [ "$CLEANUP_ONLY" = true ]; then phase="cleanup-only"; else phase="test"; fi

    log_header "执行测试: $script_name"

    # 清除上一个脚本残留的 test_/cleanup_ 函数
    local stale
    for stale in $(declare -F | awk '$3 ~ /^(test|cleanup)_[a-z0-9_]+$/ {print $3}'); do
        unset -f "$stale"
    done

    # 重置三态标记
    __TEST_SKIPPED=0
    __TEST_SKIP_REASON=""

    # shellcheck disable=SC1090
    source "$test_script"

    local test_func cleanup_func
    test_func=$(declare -F | awk '$3 ~ /^test_[a-z0-9_]+$/ {print $3; exit}')
    cleanup_func=$(declare -F | awk '$3 ~ /^cleanup_[a-z0-9_]+$/ {print $3; exit}')

    local start_ts end_ts status="passed" skip_reason="" fail_reason=""
    start_ts=$(date +%s)

    if [ -z "$test_func" ]; then
        end_ts=$(date +%s)
        log_error "在 $script_name 中未找到测试函数 (test_*)"
        report_record_doctest "$PROJECT" "$file" "$script_name" "$phase" \
            "failed" "" "未找到测试函数 test_*" "$start_ts" "$end_ts"
        return 1
    fi

    # 只执行 cleanup
    if [ "$CLEANUP_ONLY" = true ]; then
        if [ -n "$cleanup_func" ]; then
            log_info "执行 cleanup: $cleanup_func"
            if $cleanup_func; then status="passed"; else status="failed"; fail_reason="cleanup 失败"; fi
        else
            log_warn "未找到 cleanup 函数"; status="skipped"; skip_reason="无 cleanup 函数"
        fi
        end_ts=$(date +%s)
        report_record_doctest "$PROJECT" "$file" "$script_name" "$phase" \
            "$status" "$skip_reason" "$fail_reason" "$start_ts" "$end_ts"
        [ "$status" = "failed" ] && return 1
        return 0
    fi

    # 执行测试
    log_info "执行测试函数: $test_func"
    if $test_func; then
        if [ "${__TEST_SKIPPED:-0}" = "1" ]; then
            status="skipped"; skip_reason="$__TEST_SKIP_REASON"
            log_warn "测试跳过: $test_func"
        else
            status="passed"; log_success "测试通过: $test_func"
        fi
    else
        status="failed"; fail_reason="测试函数 $test_func 返回非 0"
        log_error "测试失败: $test_func"
    fi

    # 执行 cleanup（跳过的测试也尝试清理，幂等无害）
    if [ "$NO_CLEANUP" = false ] && [ -n "$cleanup_func" ]; then
        log_info "执行 cleanup: $cleanup_func"
        if ! $cleanup_func; then log_warn "Cleanup 失败，但不影响测试结果"; fi
    fi

    end_ts=$(date +%s)
    report_record_doctest "$PROJECT" "$file" "$script_name" "$phase" \
        "$status" "$skip_reason" "$fail_reason" "$start_ts" "$end_ts"

    [ "$status" = "failed" ] && return 1
    return 0
}
```

- [ ] **Step 3: 改造 `main` 结尾（执行测试循环 + finalize）**

将 `main` 中「执行测试」段（从 `local script` 的 for 循环到结尾 `print_test_summary`）替换为：

```bash
    # ── 单跑模式自行 init（编排模式下父进程已 init 并导出，report_init 幂等跳过）──
    report_init "$PROJECT"

    local script overall_rc=0
    for script in "${test_scripts[@]}"; do
        run_test_script "$script" || overall_rc=1
        echo ""
    done

    # 编排模式（RUNME_TEST_ORCHESTRATED=1）由父进程 trap report_finalize 汇总；
    # 单跑模式由引擎自行 finalize。
    if [ -z "${RUNME_TEST_ORCHESTRATED:-}" ]; then
        report_finalize || overall_rc=1
    fi
    exit "$overall_rc"
```

- [ ] **Step 4: 集成验证 — 单跑模式产出报告（用最小 dummy 测试脚本）**

> 说明：`run_test_script` 整体依赖 `source run.sh` 后的全局状态，难以纯单元测试；此处用一个不依赖集群的临时 dummy 脚本做集成冒烟，验证三态捕获与单跑 finalize。

Run:

```bash
cd /home/vscode/repo/docs-runme-tests
mkdir -p /tmp/xpdoc/docs
cat > /tmp/xpdoc/docs/runme-test_xpdemo.sh <<'EOF'
test_xpdemo() { log_info "dummy 测试"; return 0; }
EOF
MESH_REPO_ROOT=/tmp/xpdoc \
RUNME_VERSION=x PLATFORM_ADDRESS=x ACP_API_TOKEN=x PLATFORM_USERNAME=x PLATFORM_PASSWORD=x \
  bash run.sh --project mesh --file xpdemo --no-cleanup; echo "退出码=$?"
cat tmp/runs/latest/results.jsonl
```

Expected: 终端出现「测试运行汇总」摘要；`results.jsonl` 含一行 `"file":"xpdemo"`、`"status":"passed"`；退出码 0。

> 注：`project_check_env`/`project_prepare` 可能因缺少真实环境而失败；若该 dummy 冒烟受阻于项目钩子，改为运行 `bash framework/tests/report_test.sh` 确认 report 层无回归，并将 run.sh 改造留待真实环境冒烟。清理：`rm -rf /tmp/xpdoc`。

- [ ] **Step 5: 确认 run.sh 无旧统计残留**

Run: `grep -n "record_test_result\|print_test_summary" run.sh`
Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add run.sh
git commit -m "refactor(run): 引擎计时与三态捕获，写 doctest 记录，区分编排/单跑模式

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: 编排脚本改造（mesh / otel / tracing）

把三个 `run-*-all.sh` 从 `record_test_result + 手动 exit` 改为 `case_*` 编排；顶部 source report.sh + report_init + trap report_finalize + 导出 `RUNME_TEST_ORCHESTRATED`。

**Files:**
- Modify: `run-mesh-all.sh`、`run-otel-all.sh`、`run-tracing-all.sh`

**Interfaces:**
- Consumes: report.sh 的 `report_init`/`report_finalize`/`case_begin`/`case_end`/`case_end_fatal`/`case_skip`。

- [ ] **Step 1: 改造三个脚本的公共头部**

对每个 `run-<p>-all.sh`，将顶部
```bash
source "$SCRIPT_DIR/framework/common.sh"
cd "$SCRIPT_DIR"
trap print_test_summary EXIT
```
替换为：
```bash
export FRAMEWORK_ROOT="$SCRIPT_DIR"
source "$SCRIPT_DIR/framework/common.sh"
source "$SCRIPT_DIR/framework/report.sh"
cd "$SCRIPT_DIR"

export RUNME_TEST_ORCHESTRATED=1
report_init <p>          # mesh / otel / tracing，按脚本填具体项目名
trap report_finalize EXIT
```

- [ ] **Step 2: 改造致命前置 Case（仅 mesh 的 Case 1）**

`run-mesh-all.sh` 的 Case 1 块替换为：
```bash
case_begin "1" "环境初始化（默认 SINGLE_CLUSTER_NAME）"
if (
    set -e
    ./run.sh --project mesh --init-only
); then
    case_end 0
else
    case_end_fatal 1
fi
```

- [ ] **Step 3: 改造普通 Case（所有 `record_test_result` 模式）**

将每处
```bash
log_header "Case N: ..."
if (
    set -e
    ...commands...
); then
    record_test_result 0
else
    record_test_result 1
    exit 1
fi
```
改为
```bash
case_begin "N" "..."
if (
    set -e
    ...commands...
); then
    case_end 0
else
    case_end 1
fi
```
（`case_begin` 取代 `log_header`；去掉 `exit 1`，由 `case_end 1` 记录后继续。三个脚本所有普通 Case 同此处理。）

具体锚点示例（`run-mesh-all.sh` Case 8，原样替换）：

before：
```bash
log_header "Case 8: InPlace 更新策略测试（含 Istio CNI 升级）(Update InPlace + Istio CNI)"
if (
    set -e
    ./run.sh --project mesh --file update-inplace --no-cleanup --force-init
    ./run.sh --project mesh --file update-inplace --cleanup-only
); then
    record_test_result 0
else
    record_test_result 1
    exit 1
fi
```

after：
```bash
case_begin "8" "InPlace 更新策略测试（含 Istio CNI 升级）(Update InPlace + Istio CNI)"
if (
    set -e
    ./run.sh --project mesh --file update-inplace --no-cleanup --force-init
    ./run.sh --project mesh --file update-inplace --cleanup-only
); then
    case_end 0
else
    case_end 1
fi
```

- [ ] **Step 4: 改造条件跳过 Case**

将形如
```bash
if [ "$IS_DUAL_STACK" == "true" ]; then
    log_header "Case 2: 双栈网格安装测试 (Dual Stack)"
    if ( set -e; ...; ); then record_test_result 0; else record_test_result 1; exit 1; fi
else
    log_header "Case 2: 跳过双栈网格安装测试 (IS_DUAL_STACK != true)"
fi
```
改为
```bash
if [ "$IS_DUAL_STACK" == "true" ]; then
    case_begin "2" "双栈网格安装测试 (Dual Stack)"
    if ( set -e; ...; ); then case_end 0; else case_end 1; fi
else
    case_skip "2" "双栈网格安装测试" "IS_DUAL_STACK != true"
fi
```
对 mesh 的多集群 Case 6/7（`EAST_CLUSTER_NAME`/`WEST_CLUSTER_NAME` 未设置）、tracing 的 Case 2（OpenSearch 未配置时编排层已交由文档脚本 skip_test，保留原结构但把 `record_test_result` 改 `case_end`）同样处理：缺少集群变量时用 `case_skip "6" "多集群-多主多网络" "未设置 EAST_CLUSTER_NAME / WEST_CLUSTER_NAME"` 等。

- [ ] **Step 5: 删除结尾注释里对 print_test_summary 的引用**

将三个脚本结尾的
```bash
# 注意：print_test_summary 已通过 trap 注册，脚本退出时会自动执行，此处无需再次调用
```
改为
```bash
# 注意：report_finalize 已通过 trap 注册，脚本退出时自动汇总三层报告，此处无需再次调用
```

- [ ] **Step 6: 语法校验**

Run: `bash -n run-mesh-all.sh && bash -n run-otel-all.sh && bash -n run-tracing-all.sh && echo OK`
Expected: `OK`（无语法错误）。

- [ ] **Step 7: 确认无旧统计残留**

Run: `grep -rn "record_test_result\|print_test_summary" run-*-all.sh`
Expected: 无输出。

- [ ] **Step 8: 提交**

```bash
git add run-mesh-all.sh run-otel-all.sh run-tracing-all.sh
git commit -m "refactor(orchestration): 三个编排脚本改用 case_* 三层统计，跑完全部再汇总

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: 文档测试脚本 SKIPPED 真态化

把约 5 个用「`log_warn "SKIPPED: ..."` + `return 0`」伪装跳过的脚本改为调用 `skip_test`，使引擎记为真 skipped。

**Files:**
- Modify: `opentelemetry-docs/docs/en/configuration/instrumentation/runme-test_java-instrumentation.sh`
- Modify: `distributed-tracing-docs/docs/en/installing/runme-test_installing-distributed-tracing-opensearch.sh`
- Modify: `distributed-tracing-docs/docs/en/installing/runme-test_installing-distributed-tracing-elasticsearch.sh`
- Modify: `distributed-tracing-docs/docs/en/uninstalling/runme-test_uninstalling-distributed-tracing.sh`

**Interfaces:**
- Consumes: common.sh 的 `skip_test`（这些脚本已 `source common.sh`，无需额外 source）。

- [ ] **Step 1: 定位所有伪 SKIPPED 点**

Run:
```bash
grep -rn 'log_warn "SKIPPED' \
  /home/vscode/repo/opentelemetry-docs/docs \
  /home/vscode/repo/distributed-tracing-docs/docs
```
Expected: 列出待改的若干行（test 函数内的跳过分支；cleanup 函数内的跳过保持原样不改）。

- [ ] **Step 2: 逐处替换（仅 test 函数内的跳过分支）**

把每处形如
```bash
        log_warn "SKIPPED: 未设置 XXX，跳过 YYY 测试"
        return 0
```
替换为
```bash
        skip_test "未设置 XXX，跳过 YYY 测试"
        return 0
```
保持 `return 0` 不变（`skip_test` 设标记后由其后的 `return 0` 退出 test 函数；引擎据 `__TEST_SKIPPED` 记为 skipped）。

具体锚点示例（`runme-test_java-instrumentation.sh` 第 66 行）：

before：
```bash
        log_warn "SKIPPED: 未设置 USE_MESH_V2_TEST_SUITE_PLUGIN=true，跳过 Java OTel demo 测试"
        return 0
```

after：
```bash
        skip_test "未设置 USE_MESH_V2_TEST_SUITE_PLUGIN=true，跳过 Java OTel demo 测试"
        return 0
```

> 注意：`cleanup_*` 函数内的 `log_warn "SKIPPED..."` **不改**（cleanup 不参与 DocTest 三态判定，按 cleanup-only 阶段单独处理）。仅改 `test_*` 函数内的跳过分支。

- [ ] **Step 3: 语法校验**

Run:
```bash
for f in \
  /home/vscode/repo/opentelemetry-docs/docs/en/configuration/instrumentation/runme-test_java-instrumentation.sh \
  /home/vscode/repo/distributed-tracing-docs/docs/en/installing/runme-test_installing-distributed-tracing-opensearch.sh \
  /home/vscode/repo/distributed-tracing-docs/docs/en/installing/runme-test_installing-distributed-tracing-elasticsearch.sh \
  /home/vscode/repo/distributed-tracing-docs/docs/en/uninstalling/runme-test_uninstalling-distributed-tracing.sh; do
  bash -n "$f" && echo "OK $f"
done
```
Expected: 每个文件 `OK`。

- [ ] **Step 4: 提交（这些文件在各自独立仓库，分别提交）**

> 这些脚本位于 `opentelemetry-docs` / `distributed-tracing-docs` 仓库，不在 docs-runme-tests 仓库内。分别进入对应仓库提交：

```bash
cd /home/vscode/repo/opentelemetry-docs && git add docs/en/configuration/instrumentation/runme-test_java-instrumentation.sh \
  && git commit -m "test: java-instrumentation 用 skip_test 表达真 SKIPPED 态

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"

cd /home/vscode/repo/distributed-tracing-docs && git add docs/en/installing/runme-test_installing-distributed-tracing-opensearch.sh \
  docs/en/installing/runme-test_installing-distributed-tracing-elasticsearch.sh \
  docs/en/uninstalling/runme-test_uninstalling-distributed-tracing.sh \
  && git commit -m "test: 分布式调用链测试用 skip_test 表达真 SKIPPED 态

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> 若某仓库为脱离 HEAD 或保护分支，先在该仓库建分支再提交。

---

## Task 9: README.md 更新

更新「测试结果统计」章节，说明三层模型、产物布局、如何跑单元测试。

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 定位现有统计相关章节**

Run: `grep -n "print_test_summary\|测试总结\|测试结果\|record_test_result" README.md`
Expected: 列出需要更新的段落行号。

- [ ] **Step 2: 替换/新增「测试结果统计」章节**

在 README.md 对应位置写入（若无则新增一节）：

```markdown
## 测试结果统计（三层：Run → Case → DocTest）

测试统计由 `framework/report.sh` 提供，数据源为每次运行的 `results.jsonl`（JSON Lines）。

- **Run**：一次 `run-<project>-all.sh` 或一次独立 `./run.sh --file`。
- **Case**：编排脚本中的一个用例组（`case_begin`/`case_end`），内含一到多个 `./run.sh`。
- **DocTest**：一次 `./run.sh --file <doc>`，对应一篇文档的 `runme-test_<doc>.sh`。

**失败策略**：跑完全部再汇总——致命前置（环境初始化）失败立即中止；普通 Case 失败记录后继续。

**状态三态**：passed / failed / **skipped**（文档脚本用 `skip_test "原因"` 主动声明；编排层条件跳过用 `case_skip`）。

**产物**（位于 `tmp/runs/<run-id>/`，`latest` 软链指向最近一次）：

| 文件 | 说明 |
| --- | --- |
| `results.jsonl` | 唯一数据源，每行一条记录 |
| `summary.json` | 三层结构化汇总（两套计数 + 每 Case 明细）|
| `junit.xml` | 标准 JUnit，对接 CI |

终端结束时打印美化摘要（总耗时、Case/DocTest 两套计数、每 Case 一行、失败/跳过明细）。退出码：有 failed→非 0。

**运行报告层单元测试**（不依赖集群）：

\`\`\`bash
bash framework/tests/report_test.sh
\`\`\`
```

- [ ] **Step 3: 确认无旧 API 残留描述**

Run: `grep -n "record_test_result\|print_test_summary" README.md`
Expected: 无输出（旧 API 描述已清除）。

- [ ] **Step 4: 提交**

```bash
git add README.md
git commit -m "docs(readme): 更新测试结果统计章节为三层模型与新产物布局

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## 实现顺序与依赖

```
Task 1 (report.sh 骨架+测试) → Task 2 (聚合+summary.json) → Task 3 (junit.xml) → Task 4 (终端摘要)
                                                                                          ↓
Task 5 (common.sh skip_test) ──────────────────────────────────────────────────────────→ Task 6 (run.sh 引擎)
                                                                                          ↓
                                                          Task 7 (编排×3) → Task 8 (文档脚本×5) → Task 9 (README)
```

Task 1-4 构成可独立测试的 report 层（纯逻辑，TDD 全覆盖）；Task 5-6 接入引擎；Task 7-9 接入编排与文档并收尾。

## 验收

- `bash framework/tests/report_test.sh` 全绿（report 层 TDD）。
- `bash -n` 通过所有改动脚本。
- 单跑冒烟产出 `tmp/runs/<run-id>/{results.jsonl,summary.json,junit.xml}` 且退出码正确。
- 全量 `run-*-all.sh` 真跑（需集群、数十分钟）由真实环境验收，不在本计划自动化范围（spec §12）。
