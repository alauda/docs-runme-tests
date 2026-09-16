#!/usr/bin/env bash
# framework/kubeconfig.sh 的 select_test_context 单元测试（伪造 kubectl，不依赖集群）
# 用法: bash framework/tests/kubeconfig_test.sh
#
# 覆盖重点：--file 模式下 --cluster 的落地行为
#   - 只改派生副本，不动 merged.yaml（否则会影响后续不带 --cluster 的测试）
#   - 导出 TEST_TARGET_CLUSTER：走平台 API 的操作（如 tracing 的 Jaeger 集群插件）
#     要的是 ACP 集群名，光切 context 不够
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

# 伪造 kubectl：只回答 select_test_context 用到的 config get-contexts -o name
make_kubectl_stub() {
    STUB="$(mktemp -d)"
    cat > "$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "config" ] && [ "$2" = "get-contexts" ]; then
    printf '%s\n' ${STUB_CONTEXTS:-}
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB/kubectl"
    PATH="$STUB:$PATH"
    export PATH
    STUB_CONTEXTS="east west global"
    export STUB_CONTEXTS
}

# 造一份含三个 context 的假 merged.yaml，current-context 为 east
make_merged_kubeconfig() {
    cat > "$KUBECONFIG_DIR/merged.yaml" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- cluster: {server: https://east:6443}
  name: east
- cluster: {server: https://west:6443}
  name: west
- cluster: {server: https://global:6443}
  name: global
contexts:
- context: {cluster: east, user: east}
  name: east
- context: {cluster: west, user: west}
  name: west
- context: {cluster: global, user: global}
  name: global
current-context: east
users: []
EOF
}

main() {
    KUBECONFIG_DIR="$(mktemp -d)"
    export KUBECONFIG_DIR
    make_kubectl_stub
    make_merged_kubeconfig

    # shellcheck disable=SC1090,SC1091
    source "$FRAMEWORK_ROOT/framework/kubeconfig.sh"

    printf '\n== select_test_context 正常切换 ==\n'
    unset TEST_TARGET_CLUSTER
    local rc=0
    select_test_context west > /dev/null 2>&1 || rc=$?
    check_eq "返回码 0"                  "$rc" "0"
    check_eq "导出 TEST_TARGET_CLUSTER"  "${TEST_TARGET_CLUSTER:-}" "west"
    check_eq "KUBECONFIG 指向派生副本"   "$KUBECONFIG" "$KUBECONFIG_DIR/current-west.yaml"
    check_eq "副本 current-context 已改" \
        "$(grep '^current-context:' "$KUBECONFIG_DIR/current-west.yaml")" "current-context: west"
    check_eq "副本保留全部 context"      \
        "$(grep -c '^  name: ' "$KUBECONFIG_DIR/current-west.yaml")" "6"
    check_eq "merged.yaml 未被改动"      \
        "$(grep '^current-context:' "$KUBECONFIG_DIR/merged.yaml")" "current-context: east"
    check_eq "副本权限 600"              \
        "$(ls -l "$KUBECONFIG_DIR/current-west.yaml" | cut -c2-10)" "rw-------"

    printf '\n== context 不存在时拒绝 ==\n'
    local before="$KUBECONFIG"
    TEST_TARGET_CLUSTER=west
    rc=0
    select_test_context nosuch > /dev/null 2>&1 || rc=$?
    check_eq "返回码非 0"                "$rc" "1"
    check_eq "KUBECONFIG 未被改动"       "$KUBECONFIG" "$before"
    check_eq "TEST_TARGET_CLUSTER 未被改动" "${TEST_TARGET_CLUSTER:-}" "west"

    printf '\n== 缺少集群名 / merged.yaml 时报错 ==\n'
    rc=0
    select_test_context "" > /dev/null 2>&1 || rc=$?
    check_eq "空集群名返回非 0"          "$rc" "1"
    mv "$KUBECONFIG_DIR/merged.yaml" "$KUBECONFIG_DIR/merged.yaml.bak"
    rc=0
    select_test_context west > /dev/null 2>&1 || rc=$?
    check_eq "merged.yaml 缺失返回非 0"  "$rc" "1"

    rm -rf "$KUBECONFIG_DIR" "$STUB"

    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
