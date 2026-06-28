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

    # 新 Run 开始：清除上一轮的 finalize 幂等状态
    unset __REPORT_FINALIZED __REPORT_FINALIZE_RC

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
    local duration
    duration=$(( end_ts - start_ts ))
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
    unset RUNME_TEST_CASE_ID RUNME_TEST_CASE_NAME
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

# ── report_finalize（聚合 + 写 summary.json；Task 3/4 继续增强）──
report_finalize() {
    # 幂等防护：report_finalize 既会被 case_end_fatal 显式调用、又会被编排脚本的
    # `trap report_finalize EXIT` 触发。无防护时致命前置失败会汇总两次、终端摘要重复打印。
    # 已汇总过则直接返回上次退出码。
    if [ -n "${__REPORT_FINALIZED:-}" ]; then
        return "${__REPORT_FINALIZE_RC:-0}"
    fi
    __REPORT_FINALIZED=1

    local results="${RUNME_TEST_RUN_DIR:-}/results.jsonl"
    if [ -z "${RUNME_TEST_RUN_DIR:-}" ] || [ ! -f "$results" ]; then
        log_warn "无结果数据，跳过汇总"; __REPORT_FINALIZE_RC=0; return 0
    fi
    if [ ! -s "$results" ]; then
        log_warn "未执行任何测试（results.jsonl 为空）"; __REPORT_FINALIZE_RC=0; return 0
    fi

    local summary
    summary="$(_report_aggregate "$results")"
    printf '%s\n' "$summary" > "$RUNME_TEST_RUN_DIR/summary.json"
    _report_write_junit "$summary" > "$RUNME_TEST_RUN_DIR/junit.xml"

    local result
    result="$(printf '%s' "$summary" | jq -r '.result')"

    echo ""
    _report_print_terminal "$summary"
    echo "  报告目录: $RUNME_TEST_RUN_DIR"

    if [ "$result" = "failed" ]; then __REPORT_FINALIZE_RC=1; return 1; fi
    __REPORT_FINALIZE_RC=0
    return 0
}
