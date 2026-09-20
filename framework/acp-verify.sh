#!/usr/bin/env bash
# ACP 文档测试通用断言库
#
# ── 为什么单独一个文件 ────────────────────────────────────────────────────────
# framework/verify.sh 是**纯文本比对**（输出 vs 期望字符串），与 ACP 无关。
# 但 ACP 文档里的断言大量是**集群状态断言**：「这个 CR 存在」「那个 condition 是 True」
# 「这个字段等于 X」「这个权限被允许」。这些形状在 mesh / otel / tracing / registry
# 以及将来任何模块的文档里都会重复出现。
#
# 本文件把这些形状固化成函数，好处有三：
#   1. 写测试脚本时只表达**意图**（"断言 Config/cluster 的 Available 为 True"），
#      不用每次手写 jsonpath 与错误处理
#   2. 失败信息统一、可定位——报错会带上实际值与期望值
#   3. 把踩过的坑固化成正确的默认写法（见下面「设计约定」）
#
# ── 设计约定（都是踩过的坑）─────────────────────────────────────────────────
#
# 【权限断言必须用 SubjectAccessReview，不要用 kubectl auth can-i】
#   对不在 API discovery 里的资源（如 image.alauda.io 的 registry/metrics），
#   `kubectl auth can-i` 无法解析资源名，**恒返回 no**——即使 RBAC 完全正确。
#   实测：把 system:image-registry-metrics-reader 绑给一个 SA 后，
#   SAR 判 allowed=true，而 can-i 仍返回 no。用 can-i 会误导排查方向。
#   本库的 assert_rbac_allowed / assert_rbac_denied 走 SAR。
#
# 【断言"不存在"与断言"存在"同样重要】
#   文档经常给出否定性论断（「全新环境里没有这个包」「该字段未实现」）。
#   这类断言不能靠"命令没报错"来通过，必须显式断言缺失。
#   本库提供 assert_resource_absent / assert_crd_field_absent / assert_count。
#
# 【多命令代码块不要用 runme run】
#   runme run 只回传代码块里**最后一条**命令的返回码。文档里常见的
#   「patch 然后 rollout status」形状，patch 失败而 rollout status 成功时整块返回 0，
#   测试判定通过、实际什么都没改。本库提供 run_block_strict（bash -ec 子进程）。
#
# ── 用法 ─────────────────────────────────────────────────────────────────────
#   source "$FRAMEWORK_ROOT/framework/acp-verify.sh"
#   assert_resource_exists configs.imageregistry.operator.alauda.io cluster || return 1

# 防重复加载
if [ -n "${_ACP_VERIFY_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_ACP_VERIFY_LOADED=1

# ── 内部工具 ──────────────────────────────────────────────────────────────────

# 统一的失败输出：带上实际值与期望值，便于定位
_av_fail() {
    local what="$1" expected="$2" actual="$3"
    log_error "断言失败: ${what}"
    [ -n "${expected}" ] && log_error "  期望: ${expected}"
    [ -n "${actual}" ] && log_error "  实际: ${actual}"
    return 1
}

# 把 [-n ns] 形式的参数规范化，输出 kubectl 的命名空间片段
_av_ns_args() {
    local ns="${1:-}"
    if [ -n "${ns}" ]; then
        printf -- '-n %s' "${ns}"
    fi
}

# ── 资源存在性 ────────────────────────────────────────────────────────────────

# 断言资源存在
# 用法: assert_resource_exists <kind[.group]> <name> [namespace]
assert_resource_exists() {
    local kind="$1" name="$2" ns="${3:-}"
    local out rc
    # shellcheck disable=SC2086
    out="$(kubectl get "${kind}" "${name}" $(_av_ns_args "${ns}") -o name 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ]; then
        _av_fail "资源应存在: ${kind}/${name}${ns:+ (ns=${ns})}" "存在" "${out}"
        return 1
    fi
    return 0
}

# 断言资源不存在
# 用途：文档给出否定性论断时（如「全新环境的 OperatorHub 里没有这个包」）
assert_resource_absent() {
    local kind="$1" name="$2" ns="${3:-}"
    local out rc
    # shellcheck disable=SC2086
    out="$(kubectl get "${kind}" "${name}" $(_av_ns_args "${ns}") -o name 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ]; then
        _av_fail "资源应不存在: ${kind}/${name}${ns:+ (ns=${ns})}" "不存在" "存在: ${out}"
        return 1
    fi
    # NotFound 是预期；其它错误（权限、API 不存在）不应被当成"不存在"放过
    case "${out}" in
        *NotFound*|*"not found"*) return 0 ;;
        *) _av_fail "资源应不存在，但查询报错（不是 NotFound）: ${kind}/${name}" "NotFound" "${out}"; return 1 ;;
    esac
}

# 断言某类资源的数量
# 用法: assert_count <expected> <kind[.group]> [namespace]
assert_count() {
    local expected="$1" kind="$2" ns="${3:-}"
    local actual
    # shellcheck disable=SC2086
    actual="$(kubectl get "${kind}" $(_av_ns_args "${ns}") --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${actual}" != "${expected}" ]; then
        _av_fail "资源数量: ${kind}${ns:+ (ns=${ns})}" "${expected}" "${actual}"
        return 1
    fi
    return 0
}

# ── 字段断言 ──────────────────────────────────────────────────────────────────

# 断言 jsonpath 取值等于期望值
# 用法: assert_jsonpath_eq <kind> <name> <jsonpath> <expected> [namespace]
assert_jsonpath_eq() {
    local kind="$1" name="$2" path="$3" expected="$4" ns="${5:-}"
    local actual
    # shellcheck disable=SC2086
    actual="$(kubectl get "${kind}" "${name}" $(_av_ns_args "${ns}") -o jsonpath="${path}" 2>&1)"
    if [ "${actual}" != "${expected}" ]; then
        _av_fail "${kind}/${name} 的 ${path}" "${expected}" "${actual}"
        return 1
    fi
    return 0
}

# 断言 jsonpath 取值非空
assert_jsonpath_nonempty() {
    local kind="$1" name="$2" path="$3" ns="${4:-}"
    local actual
    # shellcheck disable=SC2086
    actual="$(kubectl get "${kind}" "${name}" $(_av_ns_args "${ns}") -o jsonpath="${path}" 2>&1)"
    if [ -z "${actual}" ]; then
        _av_fail "${kind}/${name} 的 ${path} 应非空" "非空" "空"
        return 1
    fi
    return 0
}

# 断言 status.conditions 里某个 type 的 status
# 用法: assert_condition <kind> <name> <conditionType> <expectedStatus> [namespace]
# 例:   assert_condition configs.imageregistry.operator.alauda.io cluster Available True
assert_condition() {
    local kind="$1" name="$2" ctype="$3" expected="$4" ns="${5:-}"
    local actual
    # shellcheck disable=SC2086
    actual="$(kubectl get "${kind}" "${name}" $(_av_ns_args "${ns}") \
        -o jsonpath="{range .status.conditions[?(@.type==\"${ctype}\")]}{.status}{end}" 2>&1)"
    if [ "${actual}" != "${expected}" ]; then
        local reason
        # shellcheck disable=SC2086
        reason="$(kubectl get "${kind}" "${name}" $(_av_ns_args "${ns}") \
            -o jsonpath="{range .status.conditions[?(@.type==\"${ctype}\")]}{.reason}: {.message}{end}" 2>/dev/null)"
        _av_fail "${kind}/${name} 的条件 ${ctype}" "${expected}" "${actual} (${reason})"
        return 1
    fi
    return 0
}

# 断言工作负载就绪（Deployment / DaemonSet / StatefulSet）
# 用法: assert_workload_ready <kind> <name> [namespace]
assert_workload_ready() {
    local kind="$1" name="$2" ns="${3:-}"
    local out rc
    # shellcheck disable=SC2086
    out="$(kubectl rollout status "${kind}/${name}" $(_av_ns_args "${ns}") --timeout="${AV_ROLLOUT_TIMEOUT:-300s}" 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ]; then
        _av_fail "工作负载应就绪: ${kind}/${name}" "rolled out" "${out}"
        return 1
    fi
    return 0
}

# ── CRD schema 断言 ───────────────────────────────────────────────────────────

# 断言 CRD 的 schema 里存在某字段
# 用法: assert_crd_field_exists <crd-name> <schema-jsonpath>
# 例:   assert_crd_field_exists configs.imageregistry.operator.alauda.io \
#         '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.storage.properties.emptyDir'
assert_crd_field_exists() {
    local crd="$1" path="$2"
    local actual
    actual="$(kubectl get crd "${crd}" -o jsonpath="{${path}}" 2>&1)"
    if [ -z "${actual}" ]; then
        _av_fail "CRD ${crd} 应包含字段 ${path}" "存在" "不存在"
        return 1
    fi
    return 0
}

# 断言 CRD 的 schema 里**不存在**某字段
# 用途：文档声明「只支持这几种」，需要断言多出来的字段确实不被实现
assert_crd_field_absent() {
    local crd="$1" path="$2"
    local actual
    actual="$(kubectl get crd "${crd}" -o jsonpath="{${path}}" 2>&1)"
    if [ -n "${actual}" ]; then
        _av_fail "CRD ${crd} 不应包含字段 ${path}" "不存在" "存在"
        return 1
    fi
    return 0
}

# ── 权限断言（走 SubjectAccessReview，不用 kubectl auth can-i）────────────────

# 断言某主体对某资源有权限
# 用法: assert_rbac_allowed <user> <verb> <group> <resource> [subresource]
# 例:   assert_rbac_allowed system:serviceaccount:ns:sa get image.alauda.io registry metrics
assert_rbac_allowed() {
    local user="$1" verb="$2" group="$3" resource="$4" sub="${5:-}"
    local sub_line=""
    [ -n "${sub}" ] && sub_line="    subresource: ${sub}"
    local allowed
    allowed="$(kubectl create -f - -o jsonpath='{.status.allowed}' 2>/dev/null <<EOF
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: ${user}
  resourceAttributes:
    verb: ${verb}
    group: ${group}
    resource: ${resource}
${sub_line}
EOF
)"
    if [ "${allowed}" != "true" ]; then
        _av_fail "权限应被允许: ${user} ${verb} ${resource}${sub:+/}${sub} (${group})" "true" "${allowed:-<无返回>}"
        return 1
    fi
    return 0
}

# 断言某主体对某资源**无**权限
assert_rbac_denied() {
    local user="$1" verb="$2" group="$3" resource="$4" sub="${5:-}"
    local sub_line=""
    [ -n "${sub}" ] && sub_line="    subresource: ${sub}"
    local allowed
    allowed="$(kubectl create -f - -o jsonpath='{.status.allowed}' 2>/dev/null <<EOF
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: ${user}
  resourceAttributes:
    verb: ${verb}
    group: ${group}
    resource: ${resource}
${sub_line}
EOF
)"
    if [ "${allowed}" = "true" ]; then
        _av_fail "权限应被拒绝: ${user} ${verb} ${resource}${sub:+/}${sub} (${group})" "false" "true"
        return 1
    fi
    return 0
}

# ── 代码块执行（绕过 runme 的返回码陷阱）─────────────────────────────────────

# 严格执行代码块：多命令时首条失败即中断
#
# 为什么需要它：runme run 只回传**最后一条**命令的返回码。
# 文档里「patch 然后 rollout status」这类形状，patch 失败时整块仍可能返回 0。
# 本函数把代码块内容取出来交给 `bash -ec` 执行，errexit 逐条生效。
#
# 注意：不能用 `( set -e; eval "$content" )` —— errexit 对 eval 的多行字符串不生效。
# 代码块里引用的变量必须是 export 的，子进程才继承。
#
# 用法: run_block_strict <prefix:action> [workdir]
run_block_strict() {
    local block="$1" workdir="${2:-}"
    local content
    content="$(runme print "${block}" 2>/dev/null)"
    if [ -z "${content}" ]; then
        _av_fail "取代码块内容: ${block}" "非空" "空"
        return 1
    fi
    if [ -n "${workdir}" ]; then
        ( cd "${workdir}" && bash -ec "${content}" ) || {
            _av_fail "严格执行代码块: ${block}（首条失败即中断）" "全部成功" "见上方输出"
            return 1
        }
    else
        bash -ec "${content}" || {
            _av_fail "严格执行代码块: ${block}（首条失败即中断）" "全部成功" "见上方输出"
            return 1
        }
    fi
    return 0
}

# 应用 YAML 代码块
#
# 为什么需要它：runme run 对 ```yaml 块只**回显不执行**且返回 0——
# 看起来"跑过了"，实际什么都没做。
#
# 用法: apply_yaml_block <prefix:action>
apply_yaml_block() {
    local block="$1"
    local content
    content="$(runme print "${block}" 2>/dev/null)"
    if [ -z "${content}" ]; then
        _av_fail "取 YAML 代码块内容: ${block}" "非空" "空"
        return 1
    fi
    if ! printf '%s\n' "${content}" | kubectl apply -f - ; then
        _av_fail "应用 YAML 代码块: ${block}" "apply 成功" "失败"
        return 1
    fi
    return 0
}

# ── 输出断言辅助 ──────────────────────────────────────────────────────────────

# 断言命令输出**恒为**某值（用于固化"这条命令给不出有效结果"这类发现）
# 用法: assert_output_always <expected> <prefix:action>
# 例:   断言 can-i 对 registry/metrics 恒返回 no
#         assert_output_always "no" registry:check-metrics-access
assert_output_always() {
    local expected="$1" block="$2"
    local out
    out="$(runme run "${block}" 2>&1)"
    # 取最后一行非空内容（kubectl 的 warning 会走 stderr 混进来）
    local last
    last="$(printf '%s\n' "${out}" | grep -v '^$' | tail -1)"
    if [ "${last}" != "${expected}" ]; then
        _av_fail "${block} 的输出应恒为 ${expected}" "${expected}" "${last}"
        return 1
    fi
    return 0
}

# 断言命令输出包含子串（对 __cmp_contains 的语义化包装，统一失败信息）
assert_output_contains() {
    local block="$1" needle="$2"
    local out
    out="$(runme run "${block}" 2>&1)"
    if ! printf '%s' "${out}" | grep -qF "${needle}"; then
        _av_fail "${block} 的输出应包含" "${needle}" "$(printf '%s' "${out}" | head -3 | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# ── 幂等性 ────────────────────────────────────────────────────────────────────

# 断言代码块可重复执行（第二次仍成功）
# 用途：文档声明"这一步可重复执行"时固化它
# 用法: assert_idempotent <prefix:action> [workdir]
assert_idempotent() {
    local block="$1" workdir="${2:-}"
    log_info "幂等性检查: ${block} 第二次执行"
    run_block_strict "${block}" "${workdir}" || {
        _av_fail "代码块应可重复执行: ${block}" "第二次仍成功" "第二次失败"
        return 1
    }
    return 0
}
