#!/usr/bin/env bash
# 编排失败判定的单元测试（纯 Bash，可独立运行，不依赖集群）
# 用法: bash framework/tests/orchestration_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/report.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if [ "$2" = "$3" ]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 中途失败必须反映到 Case 判定，且后续步骤（含体尾清理）仍要执行——
# 这正是 `set -e` 在 `if (...)` 条件位置失效时做不到的。
test_case_step_accumulates_failure() {
    printf '\n== case_step 失败累积 ==\n'

    local trace_file
    trace_file="$(mktemp)"
    step() { printf '%s\n' "$1" >> "$trace_file"; return "$2"; }

    # 1) 全部成功 → 退出码 0
    : > "$trace_file"
    if (
        __case_rc=0
        case_step step a 0
        case_step step b 0
        exit "$__case_rc"
    ); then check_eq "全部成功判通过" "0" "0"; else check_eq "全部成功判通过" "1" "0"; fi

    # 2) 首步失败 → 退出码非 0，但后续步骤照常执行（体尾清理不能被跳过）
    : > "$trace_file"
    if (
        __case_rc=0
        case_step step first 1
        case_step step second 0
        case_step step cleanup 0
        exit "$__case_rc"
    ); then check_eq "中途失败判失败" "0" "1"; else check_eq "中途失败判失败" "1" "1"; fi
    check_eq "失败后仍执行到体尾清理" "$(tr '\n' ' ' < "$trace_file")" "first second cleanup "

    # 3) 仅末步失败 → 也要判失败
    : > "$trace_file"
    if (
        __case_rc=0
        case_step step a 0
        case_step step last 1
        exit "$__case_rc"
    ); then check_eq "末步失败判失败" "0" "1"; else check_eq "末步失败判失败" "1" "1"; fi

    unset -f step
    rm -f "$trace_file"
}

# 回归护栏：编排脚本不得回退成 `if ( set -e; ... )`。
# 该写法下 bash 会禁用子 shell 内的 errexit（ERR trap 同样被抑制），
# Case 状态只由最后一条命令的退出码决定，中途失败被吞掉。
test_orchestration_scripts_have_no_ineffective_set_e() {
    printf '\n== 编排脚本无失效的 set -e ==\n'

    local f bad
    for f in "$FRAMEWORK_ROOT"/run-*-all.sh; do
        [ -f "$f" ] || continue
        # 提取所有 `if (` ... `); then` 块，检查其内是否出现 set -e
        bad=$(awk '/^[ \t]*if \($/{inb=1} inb && /^[ \t]*set -e[ \t]*$/{c++} inb && /^[ \t]*\); then$/{inb=0} END{print c+0}' "$f")
        check_eq "$(basename "$f") 用例块内无 set -e" "$bad" "0"
    done
}

main() {
    test_case_step_accumulates_failure
    test_orchestration_scripts_have_no_ineffective_set_e
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}

main
