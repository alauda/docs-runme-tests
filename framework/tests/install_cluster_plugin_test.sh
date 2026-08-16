#!/usr/bin/env bash
# install_cluster_plugin 版本选择与幂等逻辑单元测试（纯 Bash，不依赖真实集群）
# 用法: bash framework/tests/install_cluster_plugin_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"

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
    if [[ "$2" == *"$3"* ]]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

check_not_contains() {
    if [[ "$2" != *"$3"* ]]; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望不含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

TEST_TMP="$(mktemp -d)"
KUBECONFIG_DIR="$TEST_TMP/kubeconfig"
mkdir -p "$KUBECONFIG_DIR"
touch "$KUBECONFIG_DIR/global.yaml"
export KUBECONFIG_DIR

FAKE_LOG="$TEST_TMP/calls.log"
FAKE_APPLY="$TEST_TMP/moduleinfo.yaml"
export FAKE_LOG FAKE_APPLY

# 伪造集群状态。ModuleConfig 版本以空格分隔，kubectl 查询时转换为逐行输出。
kubectl() {
    printf 'kubectl %s\n' "$*" >> "$FAKE_LOG"

    case "$*" in
        *"get moduleinfo "*"status.phase"*)
            printf '%s' "${FAKE_MODULEINFO_PHASE:-}"
            ;;
        *"get moduleinfo "*"metadata.name"*)
            printf '%s' "${FAKE_MODULEINFO_NAME:-}"
            ;;
        *"get moduleinfo "*"spec.version"*)
            printf '%s' "${FAKE_MODULEINFO_VERSION:-}"
            ;;
        *"get moduleconfigs "*"spec.version"*)
            local version
            for version in ${FAKE_MODULECONFIG_VERSIONS:-}; do
                printf '%s\n' "$version"
            done
            ;;
        *"get moduleconfigs "*"-o name"*)
            local version
            for version in ${FAKE_MODULECONFIG_VERSIONS:-}; do
                printf 'moduleconfig/%s-%s\n' "${FAKE_MODULE_NAME:-mesh-v2-test-suite}" "$version"
            done
            ;;
        "apply -f -")
            tee "$FAKE_APPLY" >/dev/null
            ;;
    esac
    return 0
}

download_package() {
    printf 'download_package %s\n' "$1" >> "$FAKE_LOG"
}

upload_package() {
    printf 'upload_package %s %s\n' "$1" "$2" >> "$FAKE_LOG"
    # 模拟 violet push 后平台发布目标版本的 ModuleConfig。
    case "$2" in
        *"v2.2.0.20260814.tgz")
            FAKE_MODULECONFIG_VERSIONS="${FAKE_MODULECONFIG_VERSIONS:+$FAKE_MODULECONFIG_VERSIONS }v2.2.0.20260814"
            ;;
        *"v2.2.0.tgz")
            FAKE_MODULECONFIG_VERSIONS="${FAKE_MODULECONFIG_VERSIONS:+$FAKE_MODULECONFIG_VERSIONS }v2.2.0"
            ;;
    esac
}

_wait_for_moduleinfo_running() {
    return 0
}

PKG_URL="http://package-minio.alauda.cn:9199/packages/mesh-v2-test-suite/v2.2/mesh-v2-test-suite.amd64.v2.2.0.tgz"
PKG_SUFFIX_URL="http://package-minio.alauda.cn:9199/packages/mesh-v2-test-suite/v2.2/mesh-v2-test-suite.amd64.v2.2.0.20260814.tgz"

new_case() {
    : > "$FAKE_LOG"
    : > "$FAKE_APPLY"
    FAKE_MODULE_NAME="mesh-v2-test-suite"
    FAKE_MODULECONFIG_VERSIONS="v1.0.4"
    FAKE_MODULEINFO_PHASE=""
    FAKE_MODULEINFO_NAME=""
    FAKE_MODULEINFO_VERSION=""
}

run_install() {
    run_install_with_url "$PKG_URL"
}

run_install_with_url() {
    local package_url="$1"
    local out rc=0
    out=$(install_cluster_plugin "mesh-v2-test-suite" "business-1" "$package_url" 2>&1) || rc=$?
    LAST_OUTPUT="$out"
    LAST_RC="$rc"
}

test_parses_optional_version_suffix() {
    printf '\n== 完整解析 vX.Y.Z 及其可选后缀 ==\n'
    check_eq "无后缀版本" "$(_cluster_plugin_package_version "$PKG_URL")" "v2.2.0"
    check_eq "点号后缀版本" "$(_cluster_plugin_package_version "$PKG_SUFFIX_URL")" "v2.2.0.20260814"
    check_eq "预发布后缀版本" \
        "$(_cluster_plugin_package_version "http://example.com/plugin.amd64.v2.2.0-rc.1+build.7.tgz")" \
        "v2.2.0-rc.1+build.7"
}

test_resolve_rejects_missing_target_version() {
    printf '\n== URL 指定版本尚未发布时禁止回退旧版本 ==\n'
    new_case
    local output rc=0
    output=$(_cluster_plugin_resolve_version "mesh-v2-test-suite" "$PKG_URL" 2>&1) || rc=$?
    check_eq "解析失败" "$rc" "1"
    check_contains "错误包含 URL 目标版本" "$output" "v2.2.0"
    check_contains "明确说明目标版本未发布" "$output" "对应 ModuleConfig 尚未发布"
}

test_uploads_and_installs_url_version() {
    printf '\n== 仅有旧 ModuleConfig 时上架并安装 URL 指定版本 ==\n'
    new_case
    run_install
    check_eq "返回码 0" "$LAST_RC" "0"
    check_contains "执行新包上架" "$(cat "$FAKE_LOG")" "upload_package global $PKG_URL"
    check_contains "日志输出目标版本" "$LAST_OUTPUT" "目标版本: v2.2.0"
    check_contains "ModuleInfo 使用目标版本" "$(cat "$FAKE_APPLY")" "version: v2.2.0"
}

test_skips_push_when_target_version_exists() {
    printf '\n== 目标版本 ModuleConfig 已存在时保持幂等 ==\n'
    new_case
    FAKE_MODULECONFIG_VERSIONS="v1.0.4 v2.2.0"
    run_install
    check_eq "返回码 0" "$LAST_RC" "0"
    check_not_contains "不重复上架目标包" "$(cat "$FAKE_LOG")" "upload_package"
    check_contains "仍选择 URL 目标版本" "$LAST_OUTPUT" "目标版本: v2.2.0"
}

test_installs_complete_suffixed_version() {
    printf '\n== 带后缀版本不会被截断为三段数字 ==\n'
    new_case
    FAKE_MODULECONFIG_VERSIONS="v2.2.0"
    run_install_with_url "$PKG_SUFFIX_URL"
    check_eq "返回码 0" "$LAST_RC" "0"
    check_contains "上架带后缀版本包" "$(cat "$FAKE_LOG")" "upload_package global $PKG_SUFFIX_URL"
    check_contains "日志保留完整版本" "$LAST_OUTPUT" "目标版本: v2.2.0.20260814"
    check_contains "ModuleInfo 使用完整版本" "$(cat "$FAKE_APPLY")" "version: v2.2.0.20260814"
}

test_rejects_running_different_version() {
    printf '\n== 已运行版本与 URL 版本不一致时明确失败 ==\n'
    new_case
    FAKE_MODULEINFO_PHASE="Running"
    FAKE_MODULEINFO_NAME="business-1-old"
    FAKE_MODULEINFO_VERSION="v1.0.4"
    run_install
    check_eq "返回码 1" "$LAST_RC" "1"
    check_contains "提示当前版本" "$LAST_OUTPUT" "v1.0.4"
    check_contains "提示目标版本" "$LAST_OUTPUT" "v2.2.0"
    check_not_contains "不误报已安装并跳过" "$LAST_OUTPUT" "已安装于 business-1 (phase=Running)，跳过"
}

test_preserves_prerequisite_packages() {
    printf '\n== 前置插件包仍下载并上架到业务集群 ==\n'
    new_case
    local prereq_url="http://example.com/metallb-operator.stable.amd64.v4.0.0.tgz"
    local output rc=0
    output=$(install_cluster_plugin "mesh-v2-test-suite" "business-1" "$PKG_URL" "$prereq_url" 2>&1) || rc=$?
    check_eq "返回码 0" "$rc" "0"
    check_contains "下载前置包" "$(cat "$FAKE_LOG")" "download_package $prereq_url"
    check_contains "前置包上架到业务集群" "$(cat "$FAKE_LOG")" "upload_package business-1 $prereq_url"
}

test_parses_optional_version_suffix
test_resolve_rejects_missing_target_version
test_uploads_and_installs_url_version
test_skips_push_when_target_version_exists
test_installs_complete_suffixed_version
test_rejects_running_different_version
test_preserves_prerequisite_packages

printf '\n==================== 结果 ====================\n'
printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
rm -rf "$TEST_TMP"
[ "$T_FAIL" -eq 0 ]
