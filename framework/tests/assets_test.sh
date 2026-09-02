#!/usr/bin/env bash
# framework/assets.sh 单元测试（纯 bash，不联网、不依赖集群）
# 用法: bash framework/tests/assets_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export FRAMEWORK_ROOT

# shellcheck disable=SC1090,SC1091
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/assets.sh"

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

# 造一个沙箱清单 + 预置文件
setup_sandbox() {
    SANDBOX="$(mktemp -d)"
    printf 'https://example.com/a/b.yaml\texample.com/a/b.yaml\n' >  "$SANDBOX/manifest.tsv"
    printf 'https://example.com/missing.yaml\texample.com/missing.yaml\n' >> "$SANDBOX/manifest.tsv"
    mkdir -p "$SANDBOX/assets/example.com/a"
    printf 'kind: ConfigMap\n' > "$SANDBOX/assets/example.com/a/b.yaml"
    ASSETS_MANIFEST="$SANDBOX/manifest.tsv"
    ASSETS_DIR="$SANDBOX/assets"
}

test_local_path() {
    printf '\n== asset_local_path ==\n'
    setup_sandbox
    check_eq "命中且文件存在" "$(asset_local_path 'https://example.com/a/b.yaml')" "$SANDBOX/assets/example.com/a/b.yaml"
    check_eq "命中但文件缺失→空" "$(asset_local_path 'https://example.com/missing.yaml')" ""
    check_eq "未登记→空"          "$(asset_local_path 'https://example.com/other.yaml')" ""
    rm -rf "$SANDBOX"
}

test_fetch_content() {
    printf '\n== fetch_url_content ==\n'
    setup_sandbox
    check_eq "命中读本地文件" "$(fetch_url_content 'https://example.com/a/b.yaml' 2>/dev/null)" "kind: ConfigMap"
    rm -rf "$SANDBOX"
}

test_rewrite() {
    printf '\n== rewrite_urls_to_assets ==\n'
    setup_sandbox
    local out
    out="$(rewrite_urls_to_assets 'kubectl -n ns apply -f https://example.com/a/b.yaml')"
    check_eq "URL 换成本地路径" "$out" "kubectl -n ns apply -f $SANDBOX/assets/example.com/a/b.yaml"
    out="$(rewrite_urls_to_assets 'kubectl apply -f https://example.com/other.yaml')"
    check_contains "未登记的 URL 保持原样" "$out" "https://example.com/other.yaml"
    rm -rf "$SANDBOX"

    # 诱饵用例（review 报告的失败形态 B）：${cmd//$url/...} 的 pattern 侧不加引号时，
    # 已登记 URL 里的 `?` 会被当成 glob 通配符（匹配任意单字符）。命令里同时出现
    # 已登记 URL 与仅该位不同的未登记诱饵 URL 时，替换已登记 URL 会把整个 $cmd
    # 当模式扫描，捎带命中诱饵——本该只替换一条，结果两条都换成同一个本地文件，
    # 即「静默 apply 错内容到真实集群」。必须两个 URL 同时出现在同一条命令里才能
    # 触发：诱饵自己单独查 asset_local_path 是查不到的（那是精确字符串比较，
    # 没有 glob 问题），问题出在已登记 URL 命中后的替换会误伤旁边的诱饵。
    setup_sandbox
    printf 'https://example.com/pkg?v=1.yaml\texample.com/pkg-registered.yaml\n' >> "$SANDBOX/manifest.tsv"
    mkdir -p "$SANDBOX/assets/example.com"
    printf 'kind: Registered\n' > "$SANDBOX/assets/example.com/pkg-registered.yaml"
    out="$(rewrite_urls_to_assets 'kubectl apply -f https://example.com/pkg?v=1.yaml && kubectl apply -f https://example.com/pkgXv=1.yaml')"
    check_contains "已登记 URL 被替换为本地路径" "$out" "$SANDBOX/assets/example.com/pkg-registered.yaml"
    check_contains "诱饵 URL（? 通配符误匹配）不应被替换" "$out" "https://example.com/pkgXv=1.yaml"
    rm -rf "$SANDBOX"
}

test_runme_run_with_assets() {
    printf '\n== runme_run_with_assets ==\n'
    setup_sandbox
    # 伪造 runme：print 时回显一条会把文件内容打出来的命令
    local stub; stub="$(mktemp -d)"
    cat > "$stub/runme" <<EOF
#!/usr/bin/env bash
[ "\$1" = "print" ] || exit 1
echo "cat https://example.com/a/b.yaml"
EOF
    chmod +x "$stub/runme"
    local out
    out="$(PATH="$stub:$PATH" runme_run_with_assets fake:block 2>/dev/null)"
    check_eq "替换后 eval 读到本地内容" "$out" "kind: ConfigMap"
    rm -rf "$stub" "$SANDBOX"
}

test_runme_run_with_assets_failfast() {
    printf '\n== runme_run_with_assets 多命令块失败即停 ==\n'
    setup_sandbox
    # 伪造 runme：print 出一个三行的多命令块，第二行必定失败
    local stub; stub="$(mktemp -d)"
    cat > "$stub/runme" <<EOF
#!/usr/bin/env bash
[ "\$1" = "print" ] || exit 1
printf 'true\nfalse\ntouch %s\n' "$SANDBOX/should-not-run"
EOF
    chmod +x "$stub/runme"
    # 复刻真实调用形态：调用方在 set -e 下写成 \`f X || { ... }\`，
    # 该上下文会抑制 errexit —— 修复前这里会「全跑完且返回 0」
    local rc=0
    ( set -e
      PATH="$stub:$PATH" runme_run_with_assets fake:block ) >/dev/null 2>&1 || rc=$?
    check_eq "中间命令失败时返回非 0" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
    check_eq "失败后不再执行后续命令" "$([ -e "$SANDBOX/should-not-run" ] && echo ran || echo stopped)" "stopped"
    rm -rf "$stub" "$SANDBOX"
}

test_manifest_wellformed() {
    printf '\n== lynx/assets-manifest.tsv 格式 ==\n'
    local f="$FRAMEWORK_ROOT/lynx/assets-manifest.tsv"
    check_eq "清单存在" "$([ -f "$f" ] && echo yes || echo no)" "yes"
    check_eq "16 条记录" "$(grep -cE '^https?://' "$f")" "16"
    check_eq "每行恰好两列" "$(awk -F'\t' '/^https?:\/\// && NF != 2 {c++} END {print c+0}' "$f")" "0"
    check_eq "路径无重复"   "$(awk -F'\t' '/^https?:\/\//{print $2}' "$f" | sort | uniq -d | wc -l | tr -d ' ')" "0"
    check_eq "URL 无重复"   "$(awk -F'\t' '/^https?:\/\//{print $1}' "$f" | sort | uniq -d | wc -l | tr -d ' ')" "0"
    # 永久防线：URL 不含 glob 元字符 ? * [ ]。rewrite_urls_to_assets 用
    # ${cmd//$url/...} 做替换，pattern 侧一旦不小心又去掉引号，含这些字符的 URL
    # 会被当通配符误匹配（见 test_rewrite 的诱饵用例），将来有人加了带查询串的
    # URL 应该在这里立刻变红，而不是留到运行时才发现替换错了目标。
    check_eq "URL 不含 glob 元字符 ? * [ ]" \
        "$(awk -F'\t' '/^https?:\/\// && $1 ~ /[]?*[]/ {c++} END {print c+0}' "$f")" "0"
}

main() {
    test_local_path
    test_fetch_content
    test_rewrite
    test_runme_run_with_assets
    test_runme_run_with_assets_failfast
    test_manifest_wellformed
    printf '\n==================================\n'
    printf '通过: %d  失败: %d\n' "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
main
