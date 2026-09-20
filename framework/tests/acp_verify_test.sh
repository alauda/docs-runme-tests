#!/usr/bin/env bash
# framework/acp-verify.sh 单元测试（伪造 kubectl / runme，不依赖集群与网络）
#
# 覆盖点：每个断言在「应通过」与「应失败」两侧都要验证。
# 只测通过路径是不够的——断言库最危险的失效模式是**恒返回 0**，
# 那会让所有文档测试都"通过"。
#
# 重点覆盖三条踩过的坑：
#   1. assert_resource_absent 只应把 NotFound 当"不存在"，
#      权限错误 / API 不存在 必须判失败（否则会把"查不了"当成"没有"）
#   2. assert_rbac_* 必须走 SubjectAccessReview，不走 kubectl auth can-i
#   3. run_block_strict 必须用 bash -ec，让多命令块首条失败即中断
#
# 用法: bash framework/tests/acp_verify_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

T_PASS=0
T_FAIL=0

check_eq() {
    if [ "$2" = "$3" ]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_contains() {
    case "$2" in
        *"$3"*) T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1" ;;
        *) T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望包含: %s\n    实际: %s\n' "$1" "$3" "$2" ;;
    esac
}

# ── fixture：伪造 kubectl / runme ─────────────────────────────────────────────
# 行为由环境变量驱动，让每个用例能精确控制"命令返回什么"。
FIXTURE=""
setup_fixture() {
    FIXTURE="$(mktemp -d)"
    mkdir -p "$FIXTURE/bin"

    # 伪造 kubectl：按 FAKE_KUBECTL_MODE 决定行为
    #   ok       —— 成功，回显 FAKE_KUBECTL_OUT
    #   notfound —— 返回 NotFound
    #   forbidden—— 返回权限错误（用于验证"非 NotFound 不放过"）
    cat > "$FIXTURE/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
mode="${FAKE_KUBECTL_MODE:-ok}"
case "$mode" in
    ok)
        printf '%s' "${FAKE_KUBECTL_OUT:-}"
        exit "${FAKE_KUBECTL_RC:-0}"
        ;;
    notfound)
        printf 'Error from server (NotFound): %s not found\n' "${FAKE_KUBECTL_NAME:-x}" >&2
        exit 1
        ;;
    forbidden)
        printf 'Error from server (Forbidden): %s is forbidden\n' "${FAKE_KUBECTL_NAME:-x}" >&2
        exit 1
        ;;
esac
exit 0
STUB
    chmod +x "$FIXTURE/bin/kubectl"

    # 伪造 runme：run <block> 执行 FAKE_RUNME_SCRIPT；print <block> 回显 FAKE_RUNME_CONTENT
    cat > "$FIXTURE/bin/runme" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
case "$cmd" in
    print)
        printf '%s\n' "${FAKE_RUNME_CONTENT:-}"
        exit 0
        ;;
    run)
        printf '%s\n' "${FAKE_RUNME_OUT:-}"
        exit "${FAKE_RUNME_RC:-0}"
        ;;
esac
exit 0
STUB
    chmod +x "$FIXTURE/bin/runme"

    export PATH="$FIXTURE/bin:$PATH"
}

teardown_fixture() {
    [ -n "$FIXTURE" ] && rm -rf "$FIXTURE"
    FIXTURE=""
}

# 在子 shell 里跑一段断言代码，回显 rc
run_assert() {
    (
        set -u
        # shellcheck disable=SC1090
        source "$FRAMEWORK_ROOT/framework/acp-verify.sh"
        # 屏蔽日志噪音，只关心返回值
        log_error() { :; }
        log_info() { :; }
        log_success() { :; }
        eval "$1"
    ) >/dev/null 2>&1
    echo $?
}

setup_fixture

# ── 用例 ──────────────────────────────────────────────────────────────────────

printf '\n[1] assert_resource_exists\n'
FAKE_KUBECTL_MODE=ok check_eq "存在时通过" "$(FAKE_KUBECTL_MODE=ok run_assert 'assert_resource_exists cm foo -n ns')" "0"
check_eq "NotFound 时失败" "$(FAKE_KUBECTL_MODE=notfound run_assert 'assert_resource_exists cm foo -n ns')" "1"
check_eq "权限错误时失败" "$(FAKE_KUBECTL_MODE=forbidden run_assert 'assert_resource_exists cm foo -n ns')" "1"

printf '\n[2] assert_resource_absent —— 只应把 NotFound 当"不存在"\n'
check_eq "NotFound 时通过" "$(FAKE_KUBECTL_MODE=notfound run_assert 'assert_resource_absent cm foo -n ns')" "0"
check_eq "存在时失败" "$(FAKE_KUBECTL_MODE=ok run_assert 'assert_resource_absent cm foo -n ns')" "1"
# 这条是关键：查不了 ≠ 没有。放过会让"权限不足"被当成"资源不存在"
check_eq "权限错误时必须失败（不能当成不存在）" \
    "$(FAKE_KUBECTL_MODE=forbidden run_assert 'assert_resource_absent cm foo -n ns')" "1"

printf '\n[3] assert_jsonpath_eq / nonempty\n'
check_eq "值相等时通过" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT=Managed run_assert 'assert_jsonpath_eq cm c .spec.x Managed')" "0"
check_eq "值不等时失败" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT=Removed run_assert 'assert_jsonpath_eq cm c .spec.x Managed')" "1"
check_eq "非空时通过" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT=v run_assert 'assert_jsonpath_nonempty cm c .spec.x')" "0"
check_eq "空时失败" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT= run_assert 'assert_jsonpath_nonempty cm c .spec.x')" "1"

printf '\n[4] assert_condition\n'
check_eq "True 通过" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT=True run_assert 'assert_condition cfg c Available True')" "0"
check_eq "False 失败" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT=False run_assert 'assert_condition cfg c Available True')" "1"
check_eq "空（条件不存在）失败" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT= run_assert 'assert_condition cfg c Available True')" "1"

printf '\n[5] assert_crd_field_exists / absent\n'
check_eq "字段存在时 exists 通过" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT='{}' run_assert 'assert_crd_field_exists crd .spec.x')" "0"
check_eq "字段缺失时 exists 失败" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT= run_assert 'assert_crd_field_exists crd .spec.x')" "1"
check_eq "字段缺失时 absent 通过" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT= run_assert 'assert_crd_field_absent crd .spec.oss')" "0"
check_eq "字段存在时 absent 失败" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT='{}' run_assert 'assert_crd_field_absent crd .spec.oss')" "1"

printf '\n[6] assert_rbac_allowed / denied —— 走 SAR\n'
check_eq "allowed=true 通过" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT=true run_assert 'assert_rbac_allowed system:sa:v v get image.alauda.io registry metrics')" "0"
check_eq "allowed=false 时 allowed 断言失败" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT=false run_assert 'assert_rbac_allowed system:sa:v v get image.alauda.io registry metrics')" "1"
check_eq "allowed=false 时 denied 断言通过" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT=false run_assert 'assert_rbac_denied system:sa:v v get image.alauda.io registry metrics')" "0"
check_eq "allowed=true 时 denied 断言失败" \
    "$(FAKE_KUBECTL_MODE=ok FAKE_KUBECTL_OUT=true run_assert 'assert_rbac_denied system:sa:v v get image.alauda.io registry metrics')" "1"
# 断言实现里必须出现 SubjectAccessReview（而不是 auth can-i）
# 注意：只检查**非注释行**——文件头部的说明性注释里刻意提到了 `kubectl auth can-i`
# 来解释为什么不用它，那是文档价值，不该被判失败。
av_src="$(cat "$FRAMEWORK_ROOT/framework/acp-verify.sh")"
check_contains "SAR 断言实现使用 SubjectAccessReview" "$av_src" "kind: SubjectAccessReview"
av_code="$(printf '%s\n' "$av_src" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')"
check_eq "SAR 断言实现（非注释行）不含 kubectl auth can-i" \
    "$(printf '%s\n' "$av_code" | grep -c 'auth can-i' || true)" "0"

printf '\n[7] assert_output_always（固化"这条命令恒返回 X"）\n'
check_eq "输出恒为期望值时通过" \
    "$(FAKE_RUNME_OUT=no run_assert 'assert_output_always no blk:check')" "0"
check_eq "输出不符时失败" \
    "$(FAKE_RUNME_OUT=yes run_assert 'assert_output_always no blk:check')" "1"
# kubectl 的 warning 会混进输出，应取最后一行非空内容
check_eq "多行输出时取最后一行非空" \
    "$(FAKE_RUNME_OUT=$'Warning: blah\n\nno' run_assert 'assert_output_always no blk:check')" "0"

printf '\n[8] run_block_strict —— 多命令块首条失败即中断\n'
check_eq "全部成功时通过" \
    "$(FAKE_RUNME_CONTENT='true; true' run_assert 'run_block_strict blk:multi')" "0"
# 这是关键：runme run 只回传最后一条的返回码，'false; true' 会被判通过。
# run_block_strict 用 bash -ec，必须失败。
check_eq "首条失败即中断（false; true 必须失败）" \
    "$(FAKE_RUNME_CONTENT='false; true' run_assert 'run_block_strict blk:multi')" "1"
check_eq "空内容失败" \
    "$(FAKE_RUNME_CONTENT= run_assert 'run_block_strict blk:multi')" "1"

printf '\n[9] apply_yaml_block —— yaml 块不能靠 runme run\n'
check_eq "合法 YAML 时通过" \
    "$(FAKE_RUNME_CONTENT='apiVersion: v1
kind: Namespace
metadata:
  name: t' run_assert 'apply_yaml_block blk:yaml')" "0"

printf '\n[10] assert_idempotent\n'
check_eq "第二次仍成功时通过" \
    "$(FAKE_RUNME_CONTENT='true' run_assert 'assert_idempotent blk:apply')" "0"
check_eq "第二次失败时失败" \
    "$(FAKE_RUNME_CONTENT='false' run_assert 'assert_idempotent blk:apply')" "1"

printf '\n────────────────────────────────────────\n'
printf '通过 %s / 失败 %s\n' "$T_PASS" "$T_FAIL"
teardown_fixture
[ "$T_FAIL" -eq 0 ]
