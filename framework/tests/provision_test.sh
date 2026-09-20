#!/usr/bin/env bash
# provision.sh 单元测试（伪造 curl / 项目钩子，不依赖集群与网络）
#
# 覆盖点：
#   1. 参数校验：缺 --project、未注册项目、项目未实现 project_provision
#      —— 这三条都必须**明确报错**，不能静默跳过（静默跳过会让「没有环境」被
#      误判成「环境已就绪」，然后一路跑到测试脚本里才炸）
#   2. --status 只读，不产生副作用
#   3. 已有可用环境时是 **no-op** —— 这是「不破坏原有框架行为」的核心保证
#   4. run.sh 在 tmp/provisioned.env 不存在时的加载逻辑是 no-op
#
# 用法: bash framework/tests/provision_test.sh
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

check_contains() {
    case "$2" in
        *"$3"*) T_PASS=$((T_PASS + 1)); printf '  [PASS] %s\n' "$1" ;;
        *) T_FAIL=$((T_FAIL + 1)); printf '  [FAIL] %s\n    期望包含: %s\n    实际: %s\n' "$1" "$3" "$2" ;;
    esac
}

# ── fixture：隔离的 FRAMEWORK_ROOT 副本 ────────────────────────────────────────
# provision.sh 按 BASH_SOURCE 推导 FRAMEWORK_ROOT，必须物理位于 <fixture>/ 下。
# framework/ 软链复用真实目录（只读）；repos.conf / projects/ 换成可控桩；
# bin/ 放伪造的 curl，避免真的联网探测平台可达性。
FIXTURE=""
setup_fixture() {
    FIXTURE="$(mktemp -d)"
    ln -s "$FRAMEWORK_ROOT/framework" "$FIXTURE/framework"
    cp "$FRAMEWORK_ROOT/provision.sh" "$FIXTURE/provision.sh"

    mkdir -p "$FIXTURE/bin" "$FIXTURE/projects/hasprovision" "$FIXTURE/projects/noprovision"

    # 伪造 curl：按 FAKE_CURL_CODE 返回状态码，默认 200（平台"可达"）
    cat > "$FIXTURE/bin/curl" <<'STUB'
#!/usr/bin/env bash
# 只处理 -w '%{http_code}' 这一种调用形态；其余一律返回空
code="${FAKE_CURL_CODE:-200}"
for a in "$@"; do
    case "$a" in
        *http_code*) printf '%s' "$code"; exit 0 ;;
    esac
done
printf '%s' "$code"
STUB
    chmod +x "$FIXTURE/bin/curl"

    # 项目桩 1：实现了 project_provision
    cat > "$FIXTURE/projects/hasprovision/project.sh" <<'STUB'
project_provision() {
    export PLATFORM_ADDRESS="https://fake.example.com"
    export PLATFORM_USERNAME="admin@cpaas.io"
    export PLATFORM_PASSWORD="fake"
    return 0
}
STUB

    # 项目桩 2：未实现 project_provision
    cat > "$FIXTURE/projects/noprovision/project.sh" <<'STUB'
project_prepare() { return 0; }
STUB

    # repos.conf：hasprovision / noprovision 都指向 fixture 自身（目录存在）
    cat > "$FIXTURE/repos.conf" <<EOF
hasprovision:${FIXTURE}
noprovision:${FIXTURE}
EOF
}

teardown_fixture() {
    [ -n "$FIXTURE" ] && rm -rf "$FIXTURE"
    FIXTURE=""
}

# 在 fixture 里跑 provision.sh，PATH 前置伪造 curl，清掉真实 PLATFORM_*
run_provision() {
    env -u PLATFORM_ADDRESS -u PLATFORM_USERNAME -u PLATFORM_PASSWORD \
        PATH="$FIXTURE/bin:$PATH" \
        bash "$FIXTURE/provision.sh" "$@" 2>&1
}

# 同上，但**带上**一套 PLATFORM_*，用于模拟「环境已由外部提供」
run_provision_with_env() {
    PATH="$FIXTURE/bin:$PATH" \
    PLATFORM_ADDRESS="https://existing.example.com" \
    PLATFORM_USERNAME="admin@cpaas.io" \
    PLATFORM_PASSWORD="fake" \
    bash "$FIXTURE/provision.sh" "$@" 2>&1
}

# 每个用例前清掉供给产物，避免用例间串味
reset_provisioned_env() {
    rm -f "$FIXTURE/tmp/provisioned.env"
}

# ── 用例 ──────────────────────────────────────────────────────────────────────

setup_fixture

printf '\n[1] 参数校验\n'
out="$(run_provision --help)"; rc=$?
check_eq "--help 退出码 0" "$rc" "0"
check_contains "--help 打印用法" "$out" "环境供给入口"

out="$(run_provision)"; rc=$?
check_eq "缺 --project 退出码非 0" "$rc" "1"
check_contains "缺 --project 有明确报错" "$out" "--project 是必填项"

out="$(run_provision --project nosuchproject)"; rc=$?
check_eq "未注册项目退出码非 0" "$rc" "1"
check_contains "未注册项目有明确报错" "$out" "未在 repos.conf 注册"

printf '\n[2] 项目未实现 project_provision —— 必须明确报错，不能静默\n'
out="$(run_provision --project noprovision)"; rc=$?
check_eq "未实现钩子退出码非 0" "$rc" "1"
check_contains "未实现钩子有明确报错" "$out" "未实现 project_provision 钩子"
check_contains "未实现钩子给出补救建议" "$out" "或改用已有环境"

printf '\n[3] --status 只读\n'
reset_provisioned_env
out="$(run_provision --project hasprovision --status)"; rc=$?
check_eq "--status 退出码 0" "$rc" "0"
check_contains "--status 报告状态" "$out" "环境供给状态"
check_eq "--status 不产出 provisioned.env" \
    "$([ -f "$FIXTURE/tmp/provisioned.env" ] && echo yes || echo no)" "no"

printf '\n[4] 已有可用环境时是 no-op（不破坏原有框架行为）\n'
reset_provisioned_env
out="$(FAKE_CURL_CODE=200 run_provision_with_env --project hasprovision)"; rc=$?
check_eq "已有环境退出码 0" "$rc" "0"
check_contains "已有环境时跳过供给" "$out" "跳过供给"
check_eq "已有环境时不产出 provisioned.env" \
    "$([ -f "$FIXTURE/tmp/provisioned.env" ] && echo yes || echo no)" "no"

printf '\n[5] 无可用环境时执行供给并落盘\n'
reset_provisioned_env
out="$(FAKE_CURL_CODE=000 run_provision --project hasprovision)"; rc=$?
check_eq "供给成功退出码 0" "$rc" "0"
check_contains "供给完成提示" "$out" "环境供给完成"
check_eq "供给后产出 provisioned.env" \
    "$([ -f "$FIXTURE/tmp/provisioned.env" ] && echo yes || echo no)" "yes"
if [ -f "$FIXTURE/tmp/provisioned.env" ]; then
    perms="$(stat -f '%Lp' "$FIXTURE/tmp/provisioned.env" 2>/dev/null || stat -c '%a' "$FIXTURE/tmp/provisioned.env" 2>/dev/null)"
    check_eq "provisioned.env 权限为 600" "$perms" "600"
    env_content="$(cat "$FIXTURE/tmp/provisioned.env")"
    check_contains "provisioned.env 含 PLATFORM_ADDRESS" "$env_content" "PLATFORM_ADDRESS=https://fake.example.com"
fi

printf '\n[6] run.sh 加载逻辑：provisioned.env 不存在时是 no-op\n'
# 直接验证 run.sh 里那段代码的语义：文件不存在 → 不 source、不报错
tmpd="$(mktemp -d)"
cat > "$tmpd/probe.sh" <<'PROBE'
set -u
FRAMEWORK_ROOT="$1"
log_info() { printf '[INFO] %s\n' "$*"; }
provisioned_env="${FRAMEWORK_ROOT}/tmp/provisioned.env"
if [ -f "$provisioned_env" ]; then
    source "$provisioned_env"
    log_info "已加载环境供给产物: $provisioned_env"
fi
printf 'PLATFORM_ADDRESS=[%s]\n' "${PLATFORM_ADDRESS:-}"
PROBE
out="$(env -u PLATFORM_ADDRESS bash "$tmpd/probe.sh" "$tmpd" 2>&1)"; rc=$?
check_eq "无产物时退出码 0" "$rc" "0"
check_contains "无产物时不打印加载提示" "$out" "PLATFORM_ADDRESS=[]"
check_eq "无产物时不出现加载日志" \
    "$(printf '%s' "$out" | grep -c '已加载环境供给产物' || true)" "0"
rm -rf "$tmpd"

printf '\n────────────────────────────────────────\n'
printf '通过 %s / 失败 %s\n' "$T_PASS" "$T_FAIL"
teardown_fixture
[ "$T_FAIL" -eq 0 ]
