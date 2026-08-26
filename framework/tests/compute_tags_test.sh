#!/usr/bin/env bash
# lynx/compute-tags.sh 单元测试（纯字符串计算，不依赖网络与集群）
#
# 重点覆盖两条容易写反的规则：
#   - 特性分支要能算出 tag（否则 PR 上 /image-build 直接失败，四仓联合改动没法在
#     合入前验证），但**不能**带 latest / release-<x> 这类浮动 tag（否则会覆盖
#     dailybuild 正在用的镜像）
#   - release-mesh-* 形状却没登记进 release-matrix.tsv 时必须报错，不能降级成
#     特性分支 tag —— 那样发版镜像会缺 release-<ACP大版本> 这个被真正引用的 tag
#
# 用法: bash framework/tests/compute_tags_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CT="${FRAMEWORK_ROOT}/lynx/compute-tags.sh"
SHA=615f7970abcdef1234567890abcdef1234567890

T_PASS=0
T_FAIL=0

check_eq() {
    if [ "$2" = "$3" ]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 用法: tags_of <branch>；副作用：设置 OUT / RC
OUT=""
RC=""
tags_of() {
    OUT="$(bash "${CT}" "$1" "${SHA}" 2>&1)"
    RC=$?
}

test_main_branch() {
    printf '\n== main 出 latest + main-<短 commit> ==\n'
    tags_of main
    check_eq "rc=0" "${RC}" "0"
    check_eq "tag 列表" "${OUT}" "latest,main-615f797"
}

test_registered_release_branch() {
    printf '\n== 已登记的 release 分支出 release-<ACP大版本> + 分支 tag ==\n'
    tags_of release-mesh-2.2
    check_eq "rc=0" "${RC}" "0"
    check_eq "tag 列表" "${OUT}" "release-4.5,release-mesh-2.2-615f797"
}

test_unregistered_release_branch_fails() {
    printf '\n== release-mesh-* 形状但未登记 -> 必须报错，不能降级 ==\n'
    tags_of release-mesh-99.9
    check_eq "rc=1" "${RC}" "1"
    check_eq "错误信息提到 release-matrix.tsv" \
        "$(printf '%s' "${OUT}" | grep -c 'release-matrix.tsv')" "1"
}

test_feature_branch_gets_only_scoped_tag() {
    printf '\n== 特性分支：能算出 tag，且不带任何浮动 tag ==\n'
    tags_of feat/dailybuild-lynx-integration
    check_eq "rc=0" "${RC}" "0"
    check_eq "斜杠被净化成短横，只有一个 tag" \
        "${OUT}" "feat-dailybuild-lynx-integration-615f797"
    check_eq "不含 latest" "$(printf '%s' "${OUT}" | grep -c 'latest')" "0"
    check_eq "不含 release- 前缀的浮动 tag" \
        "$(printf '%s' "${OUT}" | grep -c '^release-[0-9]')" "0"
}

test_leading_punctuation_stripped() {
    printf '\n== 镜像 tag 不能以 . 或 - 开头 ==\n'
    tags_of "--weird-branch"
    check_eq "rc=0" "${RC}" "0"
    check_eq "开头的短横被去掉" "${OUT}" "weird-branch-615f797"
}

test_empty_after_sanitize_fails() {
    printf '\n== 净化后为空的分支名必须报错，不能产出裸 -<sha> 这种 tag ==\n'
    tags_of "///"
    check_eq "rc=1" "${RC}" "1"
    check_eq "错误信息提到净化后为空" \
        "$(printf '%s' "${OUT}" | grep -c '净化后为空')" "1"
}

main() {
    test_main_branch
    test_registered_release_branch
    test_unregistered_release_branch_fails
    test_feature_branch_gets_only_scoped_tag
    test_leading_punctuation_stripped
    test_empty_after_sanitize_fails
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "${T_PASS}" "${T_FAIL}"
    [ "${T_FAIL}" -eq 0 ]
}
main
