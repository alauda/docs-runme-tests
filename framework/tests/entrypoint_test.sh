#!/usr/bin/env bash
# lynx/entrypoint.sh 兜底逻辑单元测试（伪造 run.sh / run-<x>-all.sh，不依赖集群）
#
# 覆盖点：_emergency_report 在 `docs-test init` 成功时不应产出 broken 占位用例
# （init 路径压根不产生 results.jsonl，见 lynx/entrypoint.sh 的说明），同时确认
# init 真失败、以及非 init 模式的兜底仍然生效——防止修复方式过宽，把兜底整体关掉。
#
# 用法: bash framework/tests/entrypoint_test.sh
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

# 构造隔离的 FRAMEWORK_ROOT 副本：lynx/entrypoint.sh 自己按 BASH_SOURCE 推导
# FRAMEWORK_ROOT，必须让被测 entrypoint.sh 物理位于 <fixture>/lynx/ 下才能生效。
# lynx/ 与 framework/ 软链复用真实目录（只读，不拷贝）；run.sh / run-<x>-all.sh
# 换成可控桩，避免真的去初始化集群或跑文档测试。
FIXTURE=""
setup_fixture() {
    FIXTURE="$(mktemp -d)"
    ln -s "$FRAMEWORK_ROOT/lynx" "$FIXTURE/lynx"
    ln -s "$FRAMEWORK_ROOT/framework" "$FIXTURE/framework"

    cat > "$FIXTURE/run.sh" <<'STUB'
#!/usr/bin/env bash
# 桩：回显收到的参数，按 STUB_EXIT_CODE 退出（默认 0）
echo "STUB run.sh $*"
exit "${STUB_EXIT_CODE:-0}"
STUB
    chmod +x "$FIXTURE/run.sh"

    local m
    for m in mesh otel tracing; do
        cat > "$FIXTURE/run-${m}-all.sh" <<STUB
#!/usr/bin/env bash
echo "STUB run-${m}-all.sh \$*"
exit "\${STUB_EXIT_CODE:-0}"
STUB
        chmod +x "$FIXTURE/run-${m}-all.sh"
    done
}

teardown_fixture() {
    [ -n "$FIXTURE" ] && rm -rf "$FIXTURE"
    FIXTURE=""
}

# 数一数 allure-result 目录下有几个 status=broken 的结果文件（jq 判断，不依赖
# jq -n 是否带 -c，格式无关）
count_broken() {
    local dir="$1" f n=0
    [ -d "$dir" ] || { printf '0'; return 0; }
    for f in "$dir"/*.json; do
        [ -f "$f" ] || continue
        if jq -e 'select(.status=="broken")' "$f" >/dev/null 2>&1; then
            n=$((n + 1))
        fi
    done
    printf '%d' "$n"
}

# 用法: run_entrypoint <mode> <stub_exit_code>
# 副作用: 设置全局 RC / RESULT_DIR 供调用方读取
RC=""
RESULT_DIR=""
run_entrypoint() {
    local mode="$1" stub_rc="$2"
    RESULT_DIR="$(mktemp -d)"
    SINGLE_CLUSTER_NAME=test-cluster \
    TEST_RESULT_DIR="$RESULT_DIR" \
    STUB_EXIT_CODE="$stub_rc" \
    ENABLE_METALLB=false \
        bash "$FIXTURE/lynx/entrypoint.sh" "$mode" >"$RESULT_DIR/.entrypoint.log" 2>&1
    RC=$?
}

test_init_success_no_broken_case() {
    printf '\n== docs-test init 成功不应产出 broken 占位用例（核心回归）==\n'
    setup_fixture
    run_entrypoint init 0
    check_eq "entrypoint 退出码为 0" "$RC" "0"
    check_eq "allure-result 下没有 broken 用例" "$(count_broken "$RESULT_DIR/allure-result")" "0"
    teardown_fixture
}

test_init_failure_still_reports() {
    printf '\n== docs-test init 真失败时兜底仍要产出 broken 占位用例 ==\n'
    setup_fixture
    run_entrypoint init 1
    check_eq "entrypoint 退出码为 1" "$RC" "1"
    check_eq "allure-result 下有 1 条 broken 用例" "$(count_broken "$RESULT_DIR/allure-result")" "1"
    teardown_fixture
}

test_non_init_mode_still_reports() {
    printf '\n== 非 init 模式（mesh）异常退出时兜底仍要产出 broken 占位用例 ==\n'
    setup_fixture
    run_entrypoint mesh 1
    check_eq "entrypoint 退出码为 1" "$RC" "1"
    check_eq "allure-result 下有 1 条 broken 用例" "$(count_broken "$RESULT_DIR/allure-result")" "1"
    teardown_fixture
}

main() {
    test_init_success_no_broken_case
    test_init_failure_still_reports
    test_non_init_mode_still_reports
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
