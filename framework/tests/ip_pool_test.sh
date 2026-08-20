#!/usr/bin/env bash
# 外部 IP 地址池所有权模型单元测试（伪造 kubectl，不依赖集群）
# 用法: bash framework/tests/ip_pool_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

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

test_render_owner_label() {
    printf '\n== _render_external_ip_pool owner 标签 ==\n'
    local out
    out="$(_render_external_ip_pool mesh-v2 metallb-system init 192.168.1.10/32)"
    check_contains "IPAddressPool 带 owner 标签" "$out" "runme-test/owner: init"
    check_contains "地址逐行展开"                "$out" "- 192.168.1.10/32"
    check_eq "两个资源各一处 owner 标签" "$(printf '%s\n' "$out" | grep -c 'runme-test/owner: init')" "2"
    out="$(_render_external_ip_pool mesh-v2 metallb-system doctest 10.0.0.1/32)"
    check_contains "doctest owner" "$out" "runme-test/owner: doctest"
}

# 伪造 kubectl + kubeconfig 目录，让 _cluster_kubeconfig_path 能通过
setup_stub() {
    STUB="$(mktemp -d)"
    KUBECONFIG_DIR="$STUB/kc"
    mkdir -p "$KUBECONFIG_DIR"
    : > "$KUBECONFIG_DIR/c1.yaml"
    cat > "$STUB/kubectl" <<EOF
#!/usr/bin/env bash
# 只回答 ipaddresspool 的两类查询：
#   - owner 标签查询（_external_ip_pool_owner）
#   - 可用地址数查询（_wait_ipaddresspool_available）
# POOL_OWNER 为空表示池不存在；POOL_AVAIL 覆盖可用地址数，缺省 "1 0"
_want=""
for a in "\$@"; do
  case "\$a" in
    *availableIPv4*)     _want=avail ;;
    *runme-test/owner*)  _want=owner ;;
  esac
done
for a in "\$@"; do
  if [ "\$a" = "ipaddresspool" ]; then
    if [ -z "\${POOL_OWNER:-}" ]; then exit 1; fi
    case "\$_want" in
      avail) printf '%s' "\${POOL_AVAIL:-1 0}" ;;
      owner) printf '%s' "\${POOL_OWNER}" ;;
    esac
    exit 0
  fi
done
exit 0
EOF
    chmod +x "$STUB/kubectl"
    export KUBECONFIG_DIR
}

test_pool_owner_query() {
    printf '\n== _external_ip_pool_owner ==\n'
    setup_stub
    check_eq "池不存在→空串" "$(PATH="$STUB:$PATH" _external_ip_pool_owner c1 mesh-v2 2>/dev/null)" ""
    check_eq "读到 init"     "$(PATH="$STUB:$PATH" POOL_OWNER=init _external_ip_pool_owner c1 mesh-v2 2>/dev/null)" "init"
    rm -rf "$STUB"
}

test_teardown_skips_init() {
    printf '\n== teardown 跳过 owner=init ==\n'
    setup_stub
    local out
    out="$(PATH="$STUB:$PATH" POOL_OWNER=init ENABLE_METALLB=true teardown_external_ip_pools c1 2>&1)"
    check_contains "跳过 init 池" "$out" "跳过清理"
    out="$(PATH="$STUB:$PATH" POOL_OWNER=doctest ENABLE_METALLB=true teardown_external_ip_pools c1 2>&1)"
    check_contains "删除 doctest 池" "$out" "删除外部 IP 地址池"
    rm -rf "$STUB"
}

test_setup_reuses_existing() {
    printf '\n== setup 复用已存在的池（不要求 JSON）==\n'
    setup_stub
    local out rc=0
    # 关键：不设置 METALLB_EXTERNAL_ADDRESSES_JSON，池已存在时也应成功
    out="$(PATH="$STUB:$PATH" POOL_OWNER=init ENABLE_METALLB=true \
           METALLB_EXTERNAL_ADDRESSES_JSON="" setup_external_ip_pools c1 2>&1)" || rc=$?
    check_eq "复用路径返回 0" "$rc" "0"
    check_contains "日志说明复用" "$out" "直接复用"

    # 池不存在且没有 JSON 时必须报错
    rc=0
    out="$(PATH="$STUB:$PATH" ENABLE_METALLB=true \
           METALLB_EXTERNAL_ADDRESSES_JSON="" setup_external_ip_pools c1 2>&1)" || rc=$?
    check_eq "无池无 JSON 返回 1" "$rc" "1"
    check_contains "报错提示 JSON" "$out" "METALLB_EXTERNAL_ADDRESSES_JSON"

    # 门控关闭时直接返回 0
    rc=0
    PATH="$STUB:$PATH" ENABLE_METALLB=false setup_external_ip_pools c1 >/dev/null 2>&1 || rc=$?
    check_eq "ENABLE_METALLB=false 直接返回 0" "$rc" "0"
    rm -rf "$STUB"
}

test_setup_reuse_no_free_ip() {
    printf '\n== 复用已存在的池但无可用地址时应失败 ==\n'
    setup_stub
    local rc=0
    # 池存在（owner=init），但可用地址数为 0 —— 对应「前一个 Case 的 LoadBalancer 占着唯一 IP」
    PATH="$STUB:$PATH" POOL_OWNER=init POOL_AVAIL="0 0" ENABLE_METALLB=true \
        METALLB_EXTERNAL_ADDRESSES_JSON="" \
        _wait_ipaddresspool_available c1 mesh-v2 2 0 >/dev/null 2>&1 || rc=$?
    check_eq "无可用地址时返回 1" "$rc" "1"
    rm -rf "$STUB"
}

main() {
    test_render_owner_label
    test_pool_owner_query
    test_teardown_skips_init
    test_setup_reuses_existing
    test_setup_reuse_no_free_ip
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
