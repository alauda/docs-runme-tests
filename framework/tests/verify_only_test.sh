#!/usr/bin/env bash
# 插件包 verify-only 模式单元测试（伪造 kubectl，不依赖集群）
# 用法: bash framework/tests/verify_only_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/tools.sh"

T_PASS=0
T_FAIL=0

check_eq() {
    if __cmp_same "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_contains() {
    if __cmp_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

# 伪造 kubectl：只回答 `get packagemanifest <name> -o json`
make_kubectl_stub() {
    STUB="$(mktemp -d)"
    cat > "$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "get" ] && [ "$2" = "packagemanifest" ]; then
    if [ "$3" != "servicemesh-operator2" ]; then exit 1; fi
    if [ "${4:-}" = "-o" ] && [ "${5:-}" = "json" ]; then
        cat <<'JSON'
{"status":{"defaultChannel":"stable","catalogSource":"platform","catalogSourceNamespace":"cpaas-system",
"channels":[{"name":"stable","currentCSV":"servicemesh-operator2.v2.2.0"},
            {"name":"stable-2.1","currentCSV":"servicemesh-operator2.v2.1.0"}]}}
JSON
    fi
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB/kubectl"
}

test_download_upload_guard() {
    printf '\n== download_package / upload_package 空值守卫 ==\n'
    local out rc
    out="$(download_package "" 2>&1)"; rc=$?
    check_eq "download 空 URL 返回 1" "$rc" "1"
    check_contains "download 报错含提示" "$out" "插件包地址为空"

    out="$(upload_package "some-cluster" "" 2>&1)"; rc=$?
    check_eq "upload 空 URL 返回 1" "$rc" "1"
    check_contains "upload 报错含提示" "$out" "插件包地址为空"
}

test_csv_from_packagemanifest() {
    printf '\n== _operator_csv_from_packagemanifest ==\n'
    make_kubectl_stub
    local out rc
    out="$(PATH="$STUB:$PATH" _operator_csv_from_packagemanifest servicemesh-operator2 2>/dev/null)"; rc=$?
    check_eq "解析 defaultChannel 的 currentCSV" "$out" "servicemesh-operator2.v2.2.0"
    check_eq "成功返回 0" "$rc" "0"

    rc=0
    PATH="$STUB:$PATH" _operator_csv_from_packagemanifest nonexistent-operator >/dev/null 2>&1 || rc=$?
    check_eq "PackageManifest 不存在返回 1" "$rc" "1"
    rm -rf "$STUB"
}

test_parse_csv_still_works() {
    printf '\n== parse_csv_name_from_package 回归 ==\n'
    check_eq "有 URL 时按包名解析" \
        "$(parse_csv_name_from_package 'http://x/servicemesh-operator2.stable.ALL.v2.1.0.tgz')" \
        "servicemesh-operator2.v2.1.0"
    check_eq "空 URL 解析为空" "$(parse_csv_name_from_package '')" ""
}

# 回归守卫：projects/tracing/jaeger-plugin.sh 的 tracing_install_jaeger_plugin 是
# _tracing_jaeger_plugin_install_via_global 的唯一调用方，其自身在调用前还有一道
# PKG_JAEGER_CLUSTER_PLUGIN_URL 硬校验。若只改内层函数（本文件其余测试覆盖的部分），
# 这道外层门槛会让内层的 verify-only 改动变成死代码——此测试专门锁住「外层不再硬卡」。
# 不需要把整个安装流程跑通，只需证明它越过了这道门槛，在下一步（找不到 Global
# kubeconfig）失败即可。
test_jaeger_outer_gate_not_blocking() {
    printf '\n== tracing_install_jaeger_plugin 外层不再硬卡空 URL ==\n'
    local out kc_dir
    # 空的 KUBECONFIG_DIR：确保它必然在「找不到 Global kubeconfig」这一步失败，
    # 从而证明它已经越过了 PKG_JAEGER_CLUSTER_PLUGIN_URL 那道门槛。
    # 在子 shell 外创建，便于用例结束后清理（子 shell 内的局部变量赋值对外层不可见，
    # 但子 shell 会继承外层已存在的变量，故此处先建目录、下面直接在子 shell 里引用）。
    kc_dir="$(mktemp -d)"
    out=$(
        # shellcheck disable=SC1090
        . "$FRAMEWORK_ROOT/projects/tracing/jaeger-plugin.sh"
        KUBECONFIG_DIR="$kc_dir"
        PKG_JAEGER_CLUSTER_PLUGIN_URL=""
        tracing_install_jaeger_plugin install-tracing-es some-cluster 2>&1
    )
    check_eq "不再因缺少 PKG_JAEGER_CLUSTER_PLUGIN_URL 而失败" \
        "$(printf '%s' "$out" | grep -c '缺少环境变量 PKG_JAEGER_CLUSTER_PLUGIN_URL')" "0"
    check_contains "越过门槛后停在缺 Global kubeconfig" "$out" "未找到 Global kubeconfig"
    rm -rf "$kc_dir"
}

main() {
    test_download_upload_guard
    test_csv_from_packagemanifest
    test_parse_csv_still_works
    test_jaeger_outer_gate_not_blocking
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
