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

    # 同一篇文档在一次 Run 里会出现多条 doctest 记录：不同 Case 各跑一遍
    # （如 mesh/kiali 在 Case 3 与 Case 5 都跑），同一 Case 内也会先 --no-cleanup
    # 再 --cleanup-only（phase 分别是 test / cleanup-only），个别 Case 甚至同一
    # phase 重复跑（Case 4 的 install-mesh 跑两次）。
    # historyId 必须把这些区分开：allure 把 historyId 相同的结果当成同一用例的重试，
    # 只保留最后一条当作最终状态。实测后果——mesh Case 5 的 deploying-ambient-bookinfo
    # 主跑 failed、随后的 cleanup-only passed，报告里就只剩 passed，
    # 终端汇总明明是 31✓/1✗，allure 却是 failed=0，dailybuild 拿到的是假绿。
    # 用 project|case_id|file|phase 做键，再加一个出现次序兜底重复。
    # 计数用字符串而不是 declare -A：macOS 自带 bash 3.2 没有关联数组。
    local line rtype project doc uuid cid phase rcase key seen_keys="" occ
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        rtype=$(printf '%s' "$line" | jq -r '.type // ""')
        [ "$rtype" = "doctest" ] || continue
        project=$(printf '%s' "$line" | jq -r '.project')
        doc=$(printf '%s' "$line" | jq -r '.file')
        phase=$(printf '%s' "$line" | jq -r '.phase // ""')
        rcase=$(printf '%s' "$line" | jq -r '.case_id // ""')
        uuid=$(_allure_uuid)
        cid=$(_allure_case_id "$project" "$doc")
        key="${project}|${rcase}|${doc}|${phase}"
        occ=$(printf '%s' "$seen_keys" | grep -Fxc -- "$key" 2>/dev/null || true)
        occ=$(( ${occ:-0} + 1 ))
        seen_keys="${seen_keys}${key}
"
        printf '%s' "$line" | jq \
            --arg uuid "$uuid" --arg case_id "${cid:-}" --argjson casemap "$casemap" \
            --arg occ "$occ" --argjson multi "$( [ "$occ" -gt 1 ] && echo true || echo false )" '
            . as $r
            | ($casemap[$r.case_id] // {name: "（无 Case）", tags: ""}) as $c
            # 名字保持可读：主跑仍是纯文档名，只给 cleanup-only 与重复出现加后缀
            | ( ($r.file)
                + (if ($r.phase // "") == "cleanup-only" then " (cleanup)" else "" end)
                + (if $multi then " #\($occ)" else "" end) ) as $dname
            | {
                uuid: $uuid,
                name: $dname,
                fullName: "\($r.project)/\($r.file) [Case \($r.case_id) \($r.phase // "")]",
                historyId: "\($r.project)/\($r.file)|case\($r.case_id)|\($r.phase // "")|\($occ)",
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

    # 补发「整 Case 无任何 doctest」的占位结果：case / case_skip 记录里出现过、
    # 但没有任何 doctest 行引用其 case_id 的 Case（典型场景：按 CASE_TYPE 门控整体
    # 未命中而 case_skip 的 Case，也覆盖零 doctest 的纯前置/收尾 Case）。逻辑镜像
    # framework/report.sh 的 _report_write_junit 在 ($dts|length)==0 时的 fallback 分支——
    # 否则这类 Case 在 allure 报告里会直接消失，而不是显示为 skipped。
    local orphans
    orphans=$(jq -sc '
        . as $rows
        | ([$rows[] | select(.type=="doctest") | .case_id]) as $used
        | $rows[] | select(.type=="case" or .type=="case_skip")
                  | select(.case_id as $cid | ($used | index($cid)) == null)
                  | {case_id, case_name,
                     status: (if .type=="case_skip" then "skipped" else .status end),
                     skip_reason: (.skip_reason // ""),
                     tags: (.tags // "")}
        ' "$results") || return 1

    local orow now
    while IFS= read -r orow; do
        [ -n "$orow" ] || continue
        uuid=$(_allure_uuid)
        now=$(( $(date +%s) * 1000 ))
        printf '%s' "$orow" | jq \
            --arg uuid "$uuid" --arg project "${RUNME_TEST_PROJECT:-unknown}" --argjson now "$now" '
            . as $c
            | {
                uuid: $uuid,
                name: "Case \($c.case_id): \($c.case_name)",
                fullName: "case/\($c.case_id)",
                historyId: "case/\($c.case_id)",
                status: $c.status,
                statusDetails: { message: $c.skip_reason },
                start: $now,
                stop:  $now,
                labels: (
                    [ {name: "suite",    value: "Case \($c.case_id): \($c.case_name)"},
                      {name: "feature",  value: $project},
                      {name: "severity", value: "normal"} ]
                    + ($c.tags | split(" ") | map(select(length > 0)) | map({name: "tag", value: .}))
                )
              }' > "$outdir/${uuid}-result.json" || return 1
    done <<EOF
$orphans
EOF

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
    # 注意：这里不加 -c。allure-result/*.json 是独立 JSON 文档（不是 results.jsonl 那种
    # 一行一条的 JSON Lines，没有单行约束），与 allure_emit_results 保持同样的 pretty
    # 格式，方便人工排查；不要「顺手」统一成紧凑格式，会导致测试断言变红。
    jq -n --arg uuid "$uuid" --arg msg "$message" --argjson now "$now" \
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
