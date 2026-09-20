#!/usr/bin/env bash
# 环境供给入口（可选机制）
#
# ── 这个脚本解决什么问题 ──────────────────────────────────────────────────────
# 框架默认假设 ACP 环境**已经存在**：你在环境里导出 PLATFORM_ADDRESS /
# PLATFORM_USERNAME / PLATFORM_PASSWORD，run.sh 就直接开工。
#
# 但环境不总是现成的（dailybuild 被占用、版本要换、要验一个还没上 dailybuild 的
# 版本）。本脚本提供「现场造一套」的补充路径：
#
#   1. 若当前已有可用环境（PLATFORM_* 齐全且平台可达）→ 直接返回，什么都不做
#   2. 否则调用项目的 project_provision 钩子造一套
#   3. 把结果写进 tmp/provisioned.env，run.sh 会自动加载（见 run.sh 顶部）
#
# ── 不破坏原有行为 ────────────────────────────────────────────────────────────
#   - 不调用本脚本时，run.sh 的行为与改动前完全一致
#   - tmp/provisioned.env 不存在时，run.sh 的加载逻辑是 no-op
#   - 已有环境时本脚本是 no-op，不会误造第二套
#   - 未实现 project_provision 的项目调用本脚本会明确报错，而不是静默跳过
#
# ── 用法 ─────────────────────────────────────────────────────────────────────
#   ./provision.sh --project registry              # 没环境就造，有环境就跳过
#   ./provision.sh --project registry --force      # 强制重造
#   ./provision.sh --project registry --status     # 只看状态，不动手
#   ./provision.sh --project registry --cleanup    # 释放本脚本造出来的环境
#
# 产物: tmp/provisioned.env  （run.sh 自动加载；也可手动 source）

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="${SCRIPT_DIR}"
PROJECTS_DIR="${FRAMEWORK_ROOT}/projects"
REPOS_CONF="${FRAMEWORK_ROOT}/repos.conf"
PROVISION_ENV_FILE="${FRAMEWORK_ROOT}/tmp/provisioned.env"
PROVISION_STATE_DIR="${FRAMEWORK_ROOT}/tmp/provision"

# shellcheck source=framework/common.sh
source "${FRAMEWORK_ROOT}/framework/common.sh"
# shellcheck source=framework/acp-auth.sh
source "${FRAMEWORK_ROOT}/framework/acp-auth.sh"

PROJECT=""
FORCE=false
STATUS_ONLY=false
CLEANUP_ONLY=false

usage() {
    cat <<'EOF'
环境供给入口

用法: ./provision.sh --project <name> [选项]

选项:
  --project <name>     文档项目名（必须已在 repos.conf 注册）
  --force              已有可用环境时也重新造一套
  --status             只报告当前环境状态，不做任何变更
  --cleanup            释放本脚本造出来的环境（依赖 tmp/provision/ 下的台账）
  -h, --help           显示本帮助

说明:
  未实现 project_provision 钩子的项目不支持本机制，会明确报错。
  产物写入 tmp/provisioned.env，run.sh 在启动时自动加载（文件不存在则为 no-op）。
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --project) PROJECT="${2:-}"; shift 2 ;;
            --force) FORCE=true; shift ;;
            --status) STATUS_ONLY=true; shift ;;
            --cleanup) CLEANUP_ONLY=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) log_error "未知参数: $1"; usage; exit 1 ;;
        esac
    done

    if [ -z "${PROJECT}" ]; then
        log_error "--project 是必填项"
        usage
        exit 1
    fi
}

# 项目是否已注册（且仓库目录存在）
_project_registered() {
    [ -f "${REPOS_CONF}" ] || return 1
    local line name path repo
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [ -n "${line}" ] || continue
        name="${line%%:*}"
        path="${line#*:}"
        case "${path}" in
            /*) repo="${path}" ;;
            *)  repo="${FRAMEWORK_ROOT}/${path}" ;;
        esac
        if [ "${name}" = "${PROJECT}" ] && [ -d "${repo}" ]; then
            return 0
        fi
    done < "${REPOS_CONF}"
    return 1
}

# 当前是否已有可用环境：三个必需变量齐全，且平台地址可连通
_has_usable_env() {
    if [ -z "${PLATFORM_ADDRESS:-}" ] || [ -z "${PLATFORM_USERNAME:-}" ] || [ -z "${PLATFORM_PASSWORD:-}" ]; then
        return 1
    fi
    # 平台可达性：只做 TCP/HTTP 层探测，不要求认证通过
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        "${PLATFORM_ADDRESS}" 2>/dev/null || echo 000)"
    case "${code}" in
        000) return 1 ;;
        *)   return 0 ;;
    esac
}

_report_status() {
    log_header "环境供给状态（项目: ${PROJECT}）"
    if _has_usable_env; then
        log_success "已有可用环境: ${PLATFORM_ADDRESS}"
    else
        log_warn "没有可用环境（PLATFORM_ADDRESS/USERNAME/PASSWORD 不齐全或平台不可达）"
    fi
    if [ -f "${PROVISION_ENV_FILE}" ]; then
        log_info "存在供给产物: ${PROVISION_ENV_FILE}"
        log_info "  内容摘要:"
        sed 's/=.*/=<已设置>/' "${PROVISION_ENV_FILE}" | sed 's/^/    /'
    else
        log_info "无供给产物（${PROVISION_ENV_FILE} 不存在）"
    fi
    if [ -d "${PROVISION_STATE_DIR}" ] && [ -n "$(ls -A "${PROVISION_STATE_DIR}" 2>/dev/null)" ]; then
        log_info "供给台账（可 cleanup 释放）:"
        ls -1 "${PROVISION_STATE_DIR}" | sed 's/^/    /'
    fi
}

# 加载项目钩子。返回 1 表示项目未注册；返回 2 表示未实现 project_provision
_load_project_hooks() {
    _project_registered || return 1
    local project_sh="${PROJECTS_DIR}/${PROJECT}/project.sh"
    if [ ! -f "${project_sh}" ]; then
        log_error "未找到项目钩子文件: ${project_sh}"
        return 1
    fi
    # shellcheck disable=SC1090
    source "${project_sh}"
    if ! declare -F project_provision >/dev/null 2>&1; then
        return 2
    fi
    return 0
}

# 从钩子导出的变量生成 provisioned.env
_write_provisioned_env() {
    mkdir -p "$(dirname "${PROVISION_ENV_FILE}")"
    umask 077
    {
        printf '# 由 provision.sh 生成于 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# 项目: %s\n' "${PROJECT}"
        printf '# 释放方式: ./provision.sh --project %s --cleanup\n' "${PROJECT}"
        printf 'PLATFORM_ADDRESS=%s\n' "${PLATFORM_ADDRESS:-}"
        printf 'PLATFORM_USERNAME=%s\n' "${PLATFORM_USERNAME:-}"
        printf 'PLATFORM_PASSWORD=%s\n' "${PLATFORM_PASSWORD:-}"
        [ -n "${PLATFORM_CA:-}" ] && printf 'PLATFORM_CA=%s\n' "${PLATFORM_CA}"
        [ -n "${GLOBAL_CLUSTER_NAME:-}" ] && printf 'GLOBAL_CLUSTER_NAME=%s\n' "${GLOBAL_CLUSTER_NAME}"
        [ -n "${SINGLE_CLUSTER_NAME:-}" ] && printf 'SINGLE_CLUSTER_NAME=%s\n' "${SINGLE_CLUSTER_NAME}"
    } > "${PROVISION_ENV_FILE}"
    chmod 600 "${PROVISION_ENV_FILE}"
    log_success "环境供给产物已写入: ${PROVISION_ENV_FILE}"
}

main() {
    parse_args "$@"

    if ! _project_registered; then
        log_error "项目 '${PROJECT}' 未在 repos.conf 注册，或其文档仓库目录不存在"
        exit 1
    fi

    if [ "${STATUS_ONLY}" = true ]; then
        _report_status
        exit 0
    fi

    # 加载钩子（cleanup 也需要它）
    set +e
    _load_project_hooks
    hook_rc=$?
    set -e
    case "${hook_rc}" in
        0) ;;
        1) exit 1 ;;
        2)
            log_error "项目 '${PROJECT}' 未实现 project_provision 钩子，不支持环境供给"
            log_error "请在 projects/${PROJECT}/project.sh 中实现 project_provision()，"
            log_error "或改用已有环境：导出 PLATFORM_ADDRESS / PLATFORM_USERNAME / PLATFORM_PASSWORD"
            exit 1
            ;;
    esac

    if [ "${CLEANUP_ONLY}" = true ]; then
        if declare -F project_provision_cleanup >/dev/null 2>&1; then
            project_provision_cleanup || exit 1
        else
            log_warn "项目 '${PROJECT}' 未实现 project_provision_cleanup，无可释放内容"
        fi
        rm -f "${PROVISION_ENV_FILE}"
        log_success "已清理供给产物"
        exit 0
    fi

    if _has_usable_env && [ "${FORCE}" != true ]; then
        log_success "已有可用环境（${PLATFORM_ADDRESS}），跳过供给"
        log_info "如需强制重造，加 --force"
        exit 0
    fi

    if [ "${FORCE}" = true ] && _has_usable_env; then
        log_warn "--force：已有环境可用，仍将执行供给（不会自动释放旧环境）"
    fi

    mkdir -p "${PROVISION_STATE_DIR}"

    log_header "开始为项目 '${PROJECT}' 供给环境"
    if ! project_provision; then
        log_error "环境供给失败"
        exit 1
    fi

    if [ -z "${PLATFORM_ADDRESS:-}" ] || [ -z "${PLATFORM_USERNAME:-}" ] || [ -z "${PLATFORM_PASSWORD:-}" ]; then
        log_error "project_provision 返回成功，但未导出完整的 PLATFORM_ADDRESS / PLATFORM_USERNAME / PLATFORM_PASSWORD"
        exit 1
    fi

    _write_provisioned_env
    log_success "环境供给完成"
    echo ""
    log_info "下一步: ./run.sh --project ${PROJECT} --init-only"
    log_info "（run.sh 会自动加载 ${PROVISION_ENV_FILE}）"
}

main "$@"
