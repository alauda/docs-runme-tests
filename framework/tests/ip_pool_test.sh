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

check_not_contains() {
    if __cmp_not_contains "$2" "$3"; then
        T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望不含: %s\n    实际: %s\n' "$1" "$3" "$2"
    fi
}

test_render_owner_label() {
    printf '\n== _render_external_ip_pool owner 标签 ==\n'
    local out addr_section
    out="$(_render_external_ip_pool mesh-v2 metallb-system init 192.168.1.10/32)"
    check_contains "IPAddressPool 带 owner 标签" "$out" "runme-test/owner: init"
    check_contains "地址逐行展开"                "$out" "- 192.168.1.10/32"
    check_eq "两个资源各一处 owner 标签" "$(printf '%s\n' "$out" | grep -c 'runme-test/owner: init')" "2"

    # 地址列表排他性：只截取 IPAddressPool 的 addresses: 到 --- 分隔符之间的段落，
    # 避免和 L2Advertisement 里同样是 "    - " 缩进的 ipAddressPools 列表混在一起数，
    # 用来拦住「owner 参数错位、泄漏进地址数组」这类 shift 计数错误（例如 shift 3 误写成 shift 2）
    addr_section="$(printf '%s\n' "$out" | sed -n '/^  addresses:$/,/^---$/p')"
    check_eq "地址行数与传入地址个数一致（owner 未泄漏进地址列表）" \
        "$(printf '%s\n' "$addr_section" | grep -c '^    - ')" "1"
    check_not_contains "地址列表不应出现 owner 值" "$addr_section" "- init"

    out="$(_render_external_ip_pool mesh-v2 metallb-system doctest 10.0.0.1/32)"
    check_contains "doctest owner" "$out" "runme-test/owner: doctest"
    addr_section="$(printf '%s\n' "$out" | sed -n '/^  addresses:$/,/^---$/p')"
    check_eq "doctest 场景地址行数同样只有 1 条（owner 未泄漏进地址列表）" \
        "$(printf '%s\n' "$addr_section" | grep -c '^    - ')" "1"
    check_not_contains "doctest 场景地址列表不应出现 owner 值" "$addr_section" "- doctest"
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
    # 专门锁住「完全没配 JSON」这条分支才有的 dailybuild 指引句——
    # 空字符串 JSON 恰好也能通过 jq empty + 空地址提取，落到「无地址配置」分支，
    # 该分支报错文案同样含 METALLB_EXTERNAL_ADDRESSES_JSON 字样，上面那条断言无法单独
    # 区分两条分支；只有这句 dailybuild 指引是「无 JSON」分支独有的
    check_contains "报错含 dailybuild 场景指引" "$out" "dailybuild"

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

# 池不存在时，setup_external_ip_pools 有三条报错分支，报错文案容易互相"撞车"
# （都含 METALLB_EXTERNAL_ADDRESSES_JSON 字样），单独一条用例把它们区分开：
#   1. 完全未设置 JSON            —— 独有 dailybuild 场景指引
#   2. JSON 合法但没有该集群条目   —— 「无地址配置」，不应提示 dailybuild
#   3. JSON 本身不是合法 JSON      —— 「不是有效 JSON」
test_setup_missing_json_vs_no_cluster_entry() {
    printf '\n== setup：区分「完全无 JSON」「JSON 合法但无该集群条目」「JSON 非法」三条报错分支 ==\n'
    setup_stub
    local out rc

    rc=0
    out="$(PATH="$STUB:$PATH" ENABLE_METALLB=true \
           METALLB_EXTERNAL_ADDRESSES_JSON="" setup_external_ip_pools c1 2>&1)" || rc=$?
    check_eq "完全无 JSON 返回 1" "$rc" "1"
    check_contains "完全无 JSON 报错含 dailybuild 指引" "$out" "dailybuild"

    rc=0
    out="$(PATH="$STUB:$PATH" ENABLE_METALLB=true \
           METALLB_EXTERNAL_ADDRESSES_JSON='[]' setup_external_ip_pools c1 2>&1)" || rc=$?
    check_eq "JSON 合法但无该集群条目返回 1" "$rc" "1"
    check_contains "报错提示无地址配置" "$out" "无地址配置"
    check_not_contains "不应提示 dailybuild（与完全无 JSON 分支区分开）" "$out" "dailybuild"

    rc=0
    out="$(PATH="$STUB:$PATH" ENABLE_METALLB=true \
           METALLB_EXTERNAL_ADDRESSES_JSON='not-json' setup_external_ip_pools c1 2>&1)" || rc=$?
    check_eq "JSON 非法返回 1" "$rc" "1"
    check_contains "报错提示不是有效 JSON" "$out" "不是有效 JSON"

    rm -rf "$STUB"
}

main() {
    test_render_owner_label
    test_pool_owner_query
    test_teardown_skips_init
    test_setup_reuses_existing
    test_setup_reuse_no_free_ip
    test_setup_missing_json_vs_no_cluster_entry
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
