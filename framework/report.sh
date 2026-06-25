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
