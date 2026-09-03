#!/usr/bin/env bash
# tracing OpenSearch 插件包准备 / operator 命名空间解析单元测试（伪造 kubectl，不依赖集群）
# 用法: bash framework/tests/tracing_opensearch_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/tools.sh"
# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/projects/tracing/opensearch.sh"

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

# 伪造 kubectl：只回答本组用例要用到的三种查询
#   - config current-context     → 固定集群名
#   - get packagemanifest <name> → 名字在 STUB_PACKAGEMANIFESTS 里才存在
#   - get subscription --all-namespaces ... → 打印 STUB_OPERATOR_NS（空则无输出）
make_kubectl_stub() {
    STUB="$(mktemp -d)"
    cat > "$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "config" ] && [ "$2" = "current-context" ]; then
    printf '%s\n' "business-1"; exit 0
fi
if [ "$1" = "get" ] && [ "$2" = "packagemanifest" ]; then
    case " ${STUB_PACKAGEMANIFESTS:-} " in
        *" $3 "*) exit 0 ;;
        *) exit 1 ;;
    esac
fi
if [ "$1" = "get" ] && [ "$2" = "subscription" ]; then
    [ -n "${STUB_OPERATOR_NS:-}" ] && printf '%s\n' "$STUB_OPERATOR_NS"
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB/kubectl"
}

# 伪造插件包三件套：把调用记录追加到 $CALL_LOG，避免真的联网下载 / violet push。
# STUB_UPLOADED 列出「已上架」的包文件名，check_package_uploaded 据此作答。
stub_package_funcs() {
    CALL_LOG="$(mktemp)"
    check_package_uploaded() {
        printf 'check %s\n' "$(basename "$2")" >> "$CALL_LOG"
        case " ${STUB_UPLOADED:-} " in
            *" $(basename "$2") "*) return 0 ;;
            *) return 1 ;;
        esac
    }
    download_package() { printf 'download %s\n' "$(basename "$1")" >> "$CALL_LOG"; return 0; }
    upload_package() { printf 'upload %s\n' "$(basename "$2")" >> "$CALL_LOG"; return 0; }
}

PKG_STORAGE_URL="http://minio/packages/acp-storage-operator/v4.3/acp-storage-operator.stable.ALL.v4.3.3.tgz"
PKG_TOPOLVM_URL="http://minio/packages/topolvm-operator/v4.3/topolvm-operator.alpha.ALL.v4.3.6.tgz"
PKG_OS_URL="http://minio/packages/opensearch-operator/v2.8/opensearch-operator.alpha.amd64.v2.8.0.tgz"

test_prepare_downloads_all_three() {
    printf '\n== 三个包地址齐全且均未上架：逐个下载上架 ==\n'
    make_kubectl_stub; stub_package_funcs
    local out rc=0
    out=$(
        PATH="$STUB:$PATH" \
        PKG_ACP_STORAGE_OPERATOR_URL="$PKG_STORAGE_URL" \
        PKG_TOPOLVM_OPERATOR_URL="$PKG_TOPOLVM_URL" \
        PKG_OPENSEARCH_OPERATOR_URL="$PKG_OS_URL" \
        _tracing_prepare_opensearch_packages 2>&1
    ) || rc=$?
    check_eq "返回 0" "$rc" "0"
    check_contains "下载 opensearch-operator 包" "$(cat "$CALL_LOG")" "download opensearch-operator.alpha.amd64.v2.8.0.tgz"
    check_contains "上架 opensearch-operator 包" "$(cat "$CALL_LOG")" "upload opensearch-operator.alpha.amd64.v2.8.0.tgz"
    check_eq "三个包各上架一次" "$(grep -c '^upload ' "$CALL_LOG")" "3"
    check_eq "日志无残留告警" "$(printf '%s' "$out" | grep -c '手动')" "0"
    rm -rf "$STUB" "$CALL_LOG"
}

test_prepare_skips_download_when_uploaded() {
    printf '\n== 已上架的包不重复下载（3GB 级别的包代价高）==\n'
    make_kubectl_stub; stub_package_funcs
    local rc=0
    STUB_UPLOADED="opensearch-operator.alpha.amd64.v2.8.0.tgz" \
    PATH="$STUB:$PATH" \
    PKG_ACP_STORAGE_OPERATOR_URL="" \
    PKG_TOPOLVM_OPERATOR_URL="" \
    PKG_OPENSEARCH_OPERATOR_URL="$PKG_OS_URL" \
    STUB_PACKAGEMANIFESTS="acp-storage-operator topolvm-operator" \
        _tracing_prepare_opensearch_packages >/dev/null 2>&1 || rc=$?
    check_eq "返回 0" "$rc" "0"
    check_eq "查过是否已上架" "$(grep -c '^check ' "$CALL_LOG")" "1"
    check_eq "未触发下载" "$(grep -c '^download ' "$CALL_LOG")" "0"
    check_eq "未触发上架" "$(grep -c '^upload ' "$CALL_LOG")" "0"
    rm -rf "$STUB" "$CALL_LOG"
}

test_prepare_verify_only_ok() {
    printf '\n== verify-only：地址留空但三个插件都已预上架 ==\n'
    make_kubectl_stub; stub_package_funcs
    local out rc=0
    out=$(
        PATH="$STUB:$PATH" \
        PKG_ACP_STORAGE_OPERATOR_URL="" PKG_TOPOLVM_OPERATOR_URL="" PKG_OPENSEARCH_OPERATOR_URL="" \
        STUB_PACKAGEMANIFESTS="acp-storage-operator topolvm-operator opensearch-operator" \
        _tracing_prepare_opensearch_packages 2>&1
    ) || rc=$?
    check_eq "返回 0" "$rc" "0"
    check_contains "提示进入 verify-only" "$out" "opensearch-operator 已上架"
    check_eq "完全不碰下载上架" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"
    rm -rf "$STUB" "$CALL_LOG"
}

test_prepare_verify_only_missing() {
    printf '\n== verify-only：opensearch-operator 未预上架则报错退出 ==\n'
    make_kubectl_stub; stub_package_funcs
    local out rc=0
    out=$(
        PATH="$STUB:$PATH" \
        PKG_ACP_STORAGE_OPERATOR_URL="" PKG_TOPOLVM_OPERATOR_URL="" PKG_OPENSEARCH_OPERATOR_URL="" \
        STUB_PACKAGEMANIFESTS="acp-storage-operator topolvm-operator" \
        _tracing_prepare_opensearch_packages 2>&1
    ) || rc=$?
    check_eq "返回 1" "$rc" "1"
    check_contains "报错点名缺失的插件" "$out" "未上架插件 opensearch-operator"
    check_contains "提示要设的变量名" "$out" "PKG_OPENSEARCH_OPERATOR_URL"
    rm -rf "$STUB" "$CALL_LOG"
}

test_operator_ns_resolution() {
    printf '\n== opensearch-operator 命名空间解析 ==\n'
    make_kubectl_stub
    check_eq "集群上没装过时用默认命名空间" \
        "$(PATH="$STUB:$PATH" STUB_OPERATOR_NS="" _tracing_opensearch_operator_ns)" \
        "opensearch-operator"
    check_eq "已装在别的命名空间时沿用它" \
        "$(PATH="$STUB:$PATH" STUB_OPERATOR_NS="opensearch-system" _tracing_opensearch_operator_ns)" \
        "opensearch-system"
    rm -rf "$STUB"
}

test_version_defaults() {
    printf '\n== 版本默认值与 opensearch-operator v2.8.0 随包镜像一致 ==\n'
    check_eq "OpenSearch 默认 3.7.0" "$TRACING_OPENSEARCH_VERSION" "3.7.0"
    check_eq "Dashboards 默认 3.7.0" "$TRACING_OPENSEARCH_DASHBOARDS_VERSION" "3.7.0"
    check_contains "渲染的 OpenSearchCluster 带该版本" \
        "$(_tracing_render_opensearchcluster /clusters/business-1/opensearch-dashboards)" \
        "version: 3.7.0"
}

main() {
    test_prepare_downloads_all_three
    test_prepare_skips_download_when_uploaded
    test_prepare_verify_only_ok
    test_prepare_verify_only_missing
    test_operator_ns_resolution
    test_version_defaults
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
