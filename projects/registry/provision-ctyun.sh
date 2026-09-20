#!/usr/bin/env bash
# registry 项目的环境供给实现：天翼云（贵州3）relay 路径
#
# ── 定位 ──────────────────────────────────────────────────────────────────────
# 本文件由 projects/registry/project.sh 的 project_provision 加载，也可被
# provision.sh 间接调用。它**不是**框架的默认路径——只有明确执行
# `./provision.sh --project registry` 时才会走到这里。
#
# ── 前置条件（缺一不可，脚本会逐项校验并明确报错）────────────────────────────
#   1. 本机 VPN 已连通 ctyun 私网（relay 机器无公网 IP，SSH 只能走私网）
#      `ping -c1 10.64.0.1` 应通
#   2. relay 凭据 JSON（0600），含 accessKey/secretKey/endpoint/regionID
#   3. SSH 私钥（microOS 镜像的默认用户是 boot）
#   4. ctyun-relayctl 二进制
#   5. 文档仓库里 cluster-api-provider-ctyun-relay 的 runbook 与 provider 包
#
# ── 时间盒 ────────────────────────────────────────────────────────────────────
# 个人账号 relay TTL 硬性 8h，无法放宽。全流程实测约 55–65 分钟：
#   bootstrap 机 10min + installer 解压 5min + setup.sh 7min + provider 推送 5min
#   + global 集群 6min + 安装器提交 1min + 安装器部署 25min
# **请务必在时间盒起始时就跑，不要中途才发现。**
#
# ── 验证状态（诚实标注）───────────────────────────────────────────────────────
# 本文件描述的是 2026-09-20 在 ACP 4.4.0 / 天翼云贵州3 上**实际跑通过**的流程，
# 但拆成函数后**尚未端到端重跑一遍**。首次使用请预留排错时间，
# 并优先参考下面「实测踩坑」里的 8 条——那些都是真踩过的。
#
# ── 实测踩坑（每条都会导致失败或浪费大量时间）────────────────────────────────
#   1. provider 包必须用 beta 渠道。群公告给的 default 渠道（commit aa1856c2）
#      其 CtyunCluster CRD 不含 apiEndpointType / retentionHours，
#      照 runbook §5.2 做会报 field not declared in schema。
#   2. kubeadm provider chart 版本是 v1.0.14，runbook 写的 v1.0.8 不存在。
#   3. 安装器密码有复杂度正则，纯字母数字会被拒：
#      ^(?![\dA-Za-z]+$)(?![!#$%&()*+=?@A-Z^_a-z~-]+$)(?![\d!#$%&()*+=?@^_~-]+$)[\w!#$%&()*+=?@^~-]{8,32}$
#      （注意不含 '/'，openssl rand -base64 常被拒）
#   4. bootstrap VM 内网 DNS 必须用 10.64.0.145，runbook 给的公网 DNS 解析不了 *.alauda.cn
#   5. IP 池稀疏，指定 IP 大概率 409。用 ip-reserve -subnet-id 自动分配
#   6. IP 租约实测 3h（文档写 30min），但仍短于 8h 时间盒，中途可能过期
#   7. manifest 里填的是**名字**不是 ID（vpc name / subnet name / 安全组中文名）
#   8. 固定 IP 与持久盘写在 CtyunMachineConfigPool.spec.configs[] 槽位上，
#      不是 CtyunMachineTemplate

set -u

# ── 配置（全部可用环境变量覆盖；未设置则用实测默认值）────────────────────────
CTYUN_REGION_ID="${CTYUN_REGION_ID:-aaf589124d5d11eaa04d0242ac110002}"
CTYUN_VPC_ID="${CTYUN_VPC_ID:-e25c5e89-b54e-4369-9dec-6e9174fc4222}"
CTYUN_SUBNET_DEV="${CTYUN_SUBNET_DEV:-0a54a8c3-f92c-43ad-b118-9f3473477355}"   # vlan300
CTYUN_SG_ID="${CTYUN_SG_ID:-f115f44f-621d-4c5b-9327-d7d2c2b250d7}"
CTYUN_AZ="${CTYUN_AZ:-default}"

CTYUN_VPC_NAME="${CTYUN_VPC_NAME:-alauda-vpc}"
CTYUN_SUBNET_NAME="${CTYUN_SUBNET_NAME:-vlan300}"
CTYUN_SECURITY_GROUP_NAME="${CTYUN_SECURITY_GROUP_NAME:-release安全组}"

MICROOS_IMAGE_NAME="${MICROOS_IMAGE_NAME:-microOS-55-ctyun-x86-v440}"
FLAVOR_BOOTSTRAP="${FLAVOR_BOOTSTRAP:-s6.2xlarge.2}"   # 8C16G
FLAVOR_CP="${FLAVOR_CP:-s6.4xlarge.2}"                 # 16C32G

RELAY_ENDPOINT="${RELAY_ENDPOINT:-https://ctyun-relay.alaudatech.net}"
CTYUN_TEAM="${CTYUN_TEAM:-acp}"

# ── 凭据：**必须由调用者提供** ────────────────────────────────────────────────
# 本仓库**不保存任何 AK/SK**，也**不假设凭据属于谁**。
# 每个调用者自己准备凭据文件并导出路径：
#
#   export CTYUN_CRED_FILE="$HOME/.codex/secrets/ctyun-relay/<你的账号>.json"   # 0600
#
# 文件格式：
#   {"apiEndpointType":"Relay","endpoint":"https://ctyun-relay.alaudatech.net",
#    "accessKey":"...","secretKey":"...","regionID":"..."}
#
# 为什么不在仓库里给默认值：默认值意味着「仓库知道某个人是谁」——
# 既会指向错误路径（别人用必然失败），也是不该外泄的个人标识。
# 兼容旧变量名 CRED_FILE（同样必须显式提供，没有默认值）。
CTYUN_CRED_FILE="${CTYUN_CRED_FILE:-${CRED_FILE:-}}"
CRED_FILE="${CTYUN_CRED_FILE}"

# SSH 私钥同样由调用者提供；只给一个常见的本地路径作为**提示**，
# 不存在时会明确报错并提示如何设置，不会静默使用别人的路径。
SSH_KEY="${SSH_KEY:-${HOME}/Downloads/id_rsa_microos}"
RELAYCTL="${RELAYCTL:-${FRAMEWORK_ROOT}/bin/ctyun-relayctl}"

# 文档仓库里 provider 的 checkout（含 runbook 与 packages/）
CTYUN_PROVIDER_REPO="${CTYUN_PROVIDER_REPO:-${FRAMEWORK_ROOT}/../cluster-api-provider-ctyun-relay}"

# 安装器与凭据（供给产物的一部分）
ACP_VERSION="${ACP_VERSION:-v4.4.0}"
INSTALLER_TAR="${INSTALLER_TAR:-acp/v4.4/installer-core-v4.4.0-x86.tar}"
GLOBAL_CLUSTER_NAME="${GLOBAL_CLUSTER_NAME:-global}"
PLATFORM_USERNAME="${PLATFORM_USERNAME:-admin@cpaas.io}"

# 台账目录：记录本次造出来的实例，供 cleanup 释放
CTYUN_STATE_DIR="${FRAMEWORK_ROOT}/tmp/provision/ctyun"

# ==============================================================================
# 前置校验
# ==============================================================================

_ctyun_require() {
    local var="$1" desc="$2"
    if [ -z "${!var:-}" ]; then
        log_error "缺少 $var（$desc）"
        return 1
    fi
    return 0
}

_ctyun_check_prereqs() {
    local rc=0

    log_info "[1/6] 校验 VPN 私网通路..."
    if ! ping -c 1 -W 3000 10.64.0.1 >/dev/null 2>&1; then
        log_error "ping 10.64.0.1 不通。relay 机器无公网 IP，SSH 只能走 VPN 私网直连。"
        log_error "请先连 VPN，并确认存在 10.64/14 → utun* 路由：netstat -rn -f inet | grep 10.64"
        rc=1
    else
        log_success "VPN 私网通路正常"
    fi

    log_info "[2/6] 校验 relay 凭据..."
    if [ -z "${CRED_FILE}" ]; then
        log_error "未提供 relay 凭据文件路径。"
        log_error "凭据由调用者提供——本仓库不保存任何 AK/SK，也不假设凭据属于谁。请导出："
        log_error "  export CTYUN_CRED_FILE=/abs/path/to/<你的账号>.json    # 权限 0600"
        log_error "文件格式："
        log_error "  {\"apiEndpointType\":\"Relay\",\"endpoint\":\"https://ctyun-relay.alaudatech.net\","
        log_error "   \"accessKey\":\"<AK>\",\"secretKey\":\"<SK>\",\"regionID\":\"<region>\"}"
        rc=1
    elif [ ! -f "${CRED_FILE}" ]; then
        log_error "凭据文件不存在: ${CRED_FILE}"
        log_error "请确认 CTYUN_CRED_FILE 指向你自己的凭据文件。"
        rc=1
    elif [ "$(stat -f '%Lp' "${CRED_FILE}" 2>/dev/null || stat -c '%a' "${CRED_FILE}" 2>/dev/null)" != "600" ]; then
        log_warn "凭据文件权限不是 600: ${CRED_FILE}"
    else
        log_success "凭据文件就绪"
    fi

    log_info "[3/6] 校验 SSH 私钥..."
    if [ ! -f "${SSH_KEY}" ]; then
        log_error "SSH 私钥不存在: ${SSH_KEY}（microOS 镜像默认用户是 boot）"
        rc=1
    else
        log_success "SSH 私钥就绪"
    fi

    log_info "[4/6] 校验 ctyun-relayctl..."
    if [ ! -x "${RELAYCTL}" ]; then
        log_error "ctyun-relayctl 不存在或不可执行: ${RELAYCTL}"
        log_error "可从 ${CTYUN_PROVIDER_REPO} 离线编译（本机 module cache 已含全部依赖，GOPROXY=off 可过）"
        rc=1
    else
        log_success "ctyun-relayctl 就绪"
    fi

    log_info "[5/6] 校验 provider 仓库与 runbook..."
    if [ ! -d "${CTYUN_PROVIDER_REPO}" ]; then
        log_error "provider 仓库不存在: ${CTYUN_PROVIDER_REPO}"
        log_error "设置 CTYUN_PROVIDER_REPO 指向 cluster-api-provider-ctyun-relay 的 checkout"
        rc=1
    else
        log_success "provider 仓库就绪"
    fi

    log_info "[6/6] 校验安装器与平台密码..."
    _ctyun_require INSTALLER_TAR "安装器 tar 路径" || rc=1
    if [ -z "${PLATFORM_PASSWORD:-}" ]; then
        log_error "缺少 PLATFORM_PASSWORD。安装器密码有复杂度正则，纯字母数字会被拒："
        log_error "  ^(?![\\dA-Za-z]+\$)(?![!#\$%&()*+=?@A-Z^_a-z~-]+\$)(?![\\d!#\$%&()*+=?@^_~-]+\$)[\\w!#\$%&()*+=?@^~-]{8,32}\$"
        rc=1
    fi

    return "${rc}"
}

# ==============================================================================
# 供给主流程
# ==============================================================================

# 在 IP 池里自动分配一个地址（不要指定具体 IP，池内稀疏，指定大概率 409）
_ctyun_reserve_ip() {
    local subnet_id="$1"
    "${RELAYCTL}" ip-reserve \
        -credentials "${CRED_FILE}" \
        -subnet-id "${subnet_id}" 2>&1 | tee -a "${CTYUN_STATE_DIR}/provision.log" \
        | sed -n 's/.*ip=\([0-9.]*\).*/\1/p' | head -1
}

# 创建 bootstrap 机并等待 SSH 可用
_ctyun_create_bootstrap() {
    local ip="$1"
    log_info "创建 bootstrap 机（${FLAVOR_BOOTSTRAP}, ${MICROOS_IMAGE_NAME}, ip=${ip}）..."
    "${RELAYCTL}" create \
        -credentials "${CRED_FILE}" \
        -name "acp-${ACP_VERSION}-registry-bootstrap" \
        -flavor "${FLAVOR_BOOTSTRAP}" \
        -image "${MICROOS_IMAGE_NAME}" \
        -subnet-id "${CTYUN_SUBNET_DEV}" \
        -fixed-ip "${ip}" \
        -security-group-id "${CTYUN_SG_ID}" \
        -az "${CTYUN_AZ}" \
        -retention-hours 8 2>&1 | tee -a "${CTYUN_STATE_DIR}/provision.log"

    # Ecs.Order.ProcFailed 的坑：那是「已创建但返回报错」，先按 owner 查实例是否真开了
    log_warn "若返回 Ecs.Order.ProcFailed，先查实例是否已创建，不要盲目重试（会开出删不掉的孤儿）"
}

# 通过 SSH 在 bootstrap 机上执行安装器准备
_ctyun_bootstrap_setup() {
    local ip="$1"
    log_info "在 bootstrap 机上准备安装器..."
    # 内网 DNS 必须改（踩坑 4）
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=15 "boot@${ip}" \
        "sudo sh -c 'echo \"nameserver 10.64.0.145\" > /etc/resolv.conf' && getent hosts package-minio.alauda.cn" \
        || { log_error "内网 DNS 设置失败（必须用 10.64.0.145）"; return 1; }
    log_success "bootstrap 机 DNS 就绪"
}

# 收集供给产物：平台地址、账号、密码
_ctyun_collect_outputs() {
    local cp_ip="$1"
    export PLATFORM_ADDRESS="https://${cp_ip}"
    export PLATFORM_USERNAME="${PLATFORM_USERNAME}"
    # PLATFORM_PASSWORD 由调用方在环境里提供（不落盘、不打印）
    log_info "平台地址: ${PLATFORM_ADDRESS}"
    log_info "平台账号: ${PLATFORM_USERNAME}"
}

provision_ctyun() {
    mkdir -p "${CTYUN_STATE_DIR}"
    : > "${CTYUN_STATE_DIR}/instances.tsv"
    printf '# instanceID\tprivateIP\tname\trole\tcreatedAt\n' >> "${CTYUN_STATE_DIR}/instances.tsv"

    log_header "天翼云（贵州3）环境供给"
    log_warn "时间盒：个人账号 relay TTL 硬性 8h，全流程约 55–65 分钟"

    _ctyun_check_prereqs || return 1

    log_header "第 1 步：预约固定 IP"
    local boot_ip cp_ip
    boot_ip="$(_ctyun_reserve_ip "${CTYUN_SUBNET_DEV}")"
    [ -n "${boot_ip}" ] || { log_error "bootstrap IP 预约失败"; return 1; }
    log_success "bootstrap IP: ${boot_ip}"

    cp_ip="$(_ctyun_reserve_ip "${CTYUN_SUBNET_DEV}")"
    [ -n "${cp_ip}" ] || { log_error "控制面 IP 预约失败"; return 1; }
    log_success "控制面 IP: ${cp_ip}"

    log_header "第 2 步：创建 bootstrap 机"
    _ctyun_create_bootstrap "${boot_ip}" || return 1
    printf 'pending\t%s\tacp-bootstrap\tbootstrap\t%s\n' "${boot_ip}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        >> "${CTYUN_STATE_DIR}/instances.tsv"

    log_header "第 3 步：bootstrap 机环境准备"
    _ctyun_bootstrap_setup "${boot_ip}" || return 1

    log_header "第 4 步：安装 ACP"
    log_warn "此步骤耗时最长（installer 解压 + setup.sh + provider 推送 + global 集群 + 安装器部署），"
    log_warn "约 50–60 分钟。已实测过的完整流程见 runbook，请按 runbook 逐步执行。"
    log_error "本实现尚未把第 4 步完全脚本化——为避免给出未验证的自动化，这里停下来。"
    log_error "请手动完成第 4 步后，用 --status 确认，或设置 CTYUN_STEP4_SCRIPT 指向你的脚本。"
    if [ -n "${CTYUN_STEP4_SCRIPT:-}" ] && [ -x "${CTYUN_STEP4_SCRIPT}" ]; then
        log_info "使用外部脚本: ${CTYUN_STEP4_SCRIPT}"
        "${CTYUN_STEP4_SCRIPT}" || return 1
    else
        return 1
    fi

    log_header "第 5 步：收集供给产物"
    _ctyun_collect_outputs "${cp_ip}" || return 1

    cat > "${CTYUN_STATE_DIR}/summary.txt" <<EOF
provisioned_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
bootstrap_ip=${boot_ip}
control_plane_ip=${cp_ip}
platform_address=https://${cp_ip}
acp_version=${ACP_VERSION}
EOF
    log_success "供给台账: ${CTYUN_STATE_DIR}/summary.txt"
    return 0
}

provision_ctyun_cleanup() {
    if [ ! -f "${CTYUN_STATE_DIR}/instances.tsv" ]; then
        log_warn "无供给台账（${CTYUN_STATE_DIR}/instances.tsv），无可释放内容"
        return 0
    fi
    log_header "释放天翼云环境"
    log_warn "relay 实例会在 TTL（8h）到期后自动回收；如需提前释放，逐台执行："
    log_warn "  ${RELAYCTL} delete -credentials ${CRED_FILE} -instance-id <id>"
    log_warn "以及释放 IP 租约："
    log_warn "  ${RELAYCTL} ip-release -credentials ${CRED_FILE} -ip <ip>"
    echo ""
    log_info "台账内容："
    cat "${CTYUN_STATE_DIR}/instances.tsv" | sed 's/^/  /'
    return 0
}
