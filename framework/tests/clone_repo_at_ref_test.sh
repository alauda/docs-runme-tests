#!/usr/bin/env bash
# lynx/clone-repo-at-ref.sh 单元测试（使用本地 bare 仓库，不访问网络）
# 用法: bash framework/tests/clone_repo_at_ref_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$FRAMEWORK_ROOT/lynx/clone-repo-at-ref.sh"

T_PASS=0
T_FAIL=0
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

check_eq() {
    if [ "$2" = "$3" ]; then
        T_PASS=$((T_PASS + 1))
        printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1))
        printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_fail() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        T_FAIL=$((T_FAIL + 1))
        printf '  [FAIL] %s（本应失败）\n' "$name"
    else
        T_PASS=$((T_PASS + 1))
        printf '  [PASS] %s\n' "$name"
    fi
}

make_origin() {
    local source="$SANDBOX/source"
    git init -q --bare "$SANDBOX/origin.git"
    git init -q "$source"
    git -C "$source" config user.email test@example.invalid
    git -C "$source" config user.name ref-test
    printf 'ref checkout\n' > "$source/README"
    git -C "$source" add README
    git -C "$source" commit -qm initial
    git -C "$source" branch -M main
    git -C "$source" tag v1.0
    git -C "$source" remote add origin "$SANDBOX/origin.git"
    git -C "$source" push -q origin main refs/tags/v1.0
    ORIGIN_URL="$SANDBOX/origin.git"
    COMMIT_SHA="$(git -C "$source" rev-parse HEAD)"
}

test_ref_types() {
    printf '\n== 分支、tag、commit SHA checkout ==\n'
    local ref destination index=0
    for ref in main v1.0 "$COMMIT_SHA"; do
        index=$((index + 1))
        destination="$SANDBOX/clone-$index"
        bash "$HELPER" "$ORIGIN_URL" "$ref" "$destination" >/dev/null
        check_eq "checkout $ref" "$(git -C "$destination" rev-parse HEAD)" "$COMMIT_SHA"
        check_eq "checkout $ref 为 detached HEAD" "$(git -C "$destination" symbolic-ref -q HEAD || true)" ""
    done
}

test_invalid_refs() {
    printf '\n== 非法 ref 拒绝 ==\n'
    check_fail "空 ref" bash "$HELPER" "$ORIGIN_URL" "" "$SANDBOX/clone-empty"
    check_fail "以连字符开头" bash "$HELPER" "$ORIGIN_URL" "-bad" "$SANDBOX/clone-dash"
    check_fail "含空白" bash "$HELPER" "$ORIGIN_URL" "feature branch" "$SANDBOX/clone-space"
}

make_origin
test_ref_types
test_invalid_refs

printf '\n==================================\n'
printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
[ "$T_FAIL" -eq 0 ]
