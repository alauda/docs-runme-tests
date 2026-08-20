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
