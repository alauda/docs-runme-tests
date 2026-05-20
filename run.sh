#!/usr/bin/env bash
# 文档自动化测试执行引擎（项目感知）
#
# 支持测试多个文档仓库（mesh / otel / tracing ...），仓库通过 repos.conf 注册。
# 单测脚本 runme-test_*.sh 仍与各自 .mdx 同仓同目录，引擎负责发现、初始化与执行。

set -e

# ── 框架路径 ──────────────────────────────────────────────────────────────────
FRAMEWORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FRAMEWORK_ROOT
FRAMEWORK_DIR="$FRAMEWORK_ROOT/framework"
PROJECTS_DIR="$FRAMEWORK_ROOT/projects"
BIN_DIR="$FRAMEWORK_ROOT/bin"
REPOS_CONF="$FRAMEWORK_ROOT/repos.conf"

# ── 加载框架函数库（顺序固定：common → verify → kubeconfig → tools）──────────────
source "$FRAMEWORK_DIR/common.sh"
source "$FRAMEWORK_DIR/verify.sh"
source "$FRAMEWORK_DIR/kubeconfig.sh"
source "$FRAMEWORK_DIR/tools.sh"

# 将 bin 目录加入 PATH（runme / violet / istioctl）
export PATH="$BIN_DIR:$PATH"

# ── 默认参数 ──────────────────────────────────────────────────────────────────
PROJECT=""
RUN_FILES=()
INIT_CLUSTERS=()
NO_CLEANUP=false
CLEANUP_ONLY=false
INIT_ONLY=false
FORCE_INIT=false
SKIP_OPERATOR_AND_CRDS=false

# 已注册（且仓库目录存在）的项目名列表（load_repos_conf 填充）
# 注：用索引数组而非关联数组（declare -A），以兼容 macOS 自带的 Bash 3.2。
REGISTERED_PROJECTS=()

# 返回项目对应的文档仓库根（取自 load_repos_conf 导出的 <NAME>_REPO_ROOT 环境变量）
# 用法: repo="$(_repo_root_of mesh)"
_repo_root_of() {
    local up
    up="$(echo "$1" | tr '[:lower:]' '[:upper:]')_REPO_ROOT"
    printf '%s' "${!up:-}"
}

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 [选项]

选项:
  --project <name>      指定文档项目（mesh / otel / tracing ...，见 repos.conf）
                        - --init-only 时必须指定
                        - --file 模式可省略，引擎会按 repos.conf 自动查找；
                          若脚本在多个项目重名则报错要求显式指定
  --file <name>         测试指定文档（可指定多次，默认不执行初始化）
  --cluster <name>      指定要初始化的集群名称（可指定多次）
                        - 仅与 --init-only / --force-init 配合使用
                        - 未指定时默认使用 \$SINGLE_CLUSTER_NAME
  --no-cleanup          不执行 cleanup 操作
  --cleanup-only        只执行 cleanup 操作
  --init-only           只执行环境初始化，不运行测试（必须配合 --project）
  --force-init          强制执行环境初始化（用于 --file 模式）
  --skip-operator-and-crds
                        轻量清理开关，导出给测试脚本读取
  -h, --help            显示此帮助信息

示例:
  # 初始化 mesh 项目环境
  $0 --project mesh --init-only

  # 测试某篇文档（自动查找所属项目，默认不初始化）
  $0 --file install-mesh

  # 显式指定项目并强制初始化
  $0 --project tracing --file installing-distributed-tracing --force-init

通用必需环境变量:
  RUNME_VERSION PLATFORM_ADDRESS ACP_API_TOKEN PLATFORM_USERNAME PLATFORM_PASSWORD
项目专属环境变量由各项目 project.sh 的 project_check_env 校验。
EOF
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --project)
                PROJECT="$2"
                shift 2
                ;;
            --file)
                RUN_FILES+=("$2")
                shift 2
                ;;
            --cluster)
                INIT_CLUSTERS+=("$2")
                shift 2
                ;;
            --no-cleanup)
                NO_CLEANUP=true
                shift
                ;;
            --cleanup-only)
                CLEANUP_ONLY=true
                shift
                ;;
            --init-only)
                INIT_ONLY=true
                shift
                ;;
            --force-init)
                FORCE_INIT=true
                shift
                ;;
            --skip-operator-and-crds)
                SKIP_OPERATOR_AND_CRDS=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# 通用环境变量校验（项目专属变量由 project_check_env 负责）
check_env() {
    local required_vars=(
        "RUNME_VERSION"
        "PLATFORM_ADDRESS"
        "ACP_API_TOKEN"
        "PLATFORM_USERNAME"
        "PLATFORM_PASSWORD"
    )
    local missing_vars=()
    local var
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -ne 0 ]; then
        log_error "缺少必要的环境变量: ${missing_vars[*]}"
        log_error "请参考 --help 了解所需环境变量"
        exit 1
    fi
}

# 解析 repos.conf，填充 REGISTERED_PROJECTS 并 export 各 <PROJECT>_REPO_ROOT
load_repos_conf() {
    if [ ! -f "$REPOS_CONF" ]; then
        log_error "未找到文档仓库注册表: $REPOS_CONF"
        exit 1
    fi

    local line name path upper override_var resolved
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"                 # 去注释
        line="${line//[[:space:]]/}"       # 去所有空白
        [ -z "$line" ] && continue
        name="${line%%:*}"
        path="${line#*:}"
        if [ -z "$name" ] || [ -z "$path" ]; then
            continue
        fi

        upper="$(echo "$name" | tr '[:lower:]' '[:upper:]')"
        override_var="${upper}_REPO_ROOT"
        resolved="${!override_var:-}"
        if [ -z "$resolved" ]; then
            case "$path" in
                /*) resolved="$path" ;;
                *)  resolved="$FRAMEWORK_ROOT/$path" ;;
            esac
        fi

        # 仅登记真实存在的仓库
        if [ -d "$resolved" ]; then
            resolved="$(cd "$resolved" && pwd)"
            REGISTERED_PROJECTS+=("$name")
            export "${override_var}=$resolved"
        fi
    done < "$REPOS_CONF"
}

# 查找测试脚本。
# 成功: 向 stdout 输出 "<project>|<abs-path>"，返回 0
# 失败: 返回 1（未找到）/ 2（多项目重名歧义）
# 注：结果通过 stdout 传出（而非全局变量），以便在命令替换子 shell 中调用而不丢失。
_find_test_script() {
    local file="$1"
    local p proj repo

    if [ -n "$PROJECT" ]; then
        repo="$(_repo_root_of "$PROJECT")"
        if [ -z "$repo" ]; then
            log_error "项目 '$PROJECT' 未在 repos.conf 注册，或其仓库目录不存在"
            return 1
        fi
        p=$(find "$repo/docs" -type f -name "runme-test_${file}.sh" 2>/dev/null | head -n 1)
        if [ -z "$p" ]; then
            return 1
        fi
        printf '%s|%s' "$PROJECT" "$p"
        return 0
    fi

    # 自动查找：遍历所有已注册项目
    local matches=()
    for proj in "${REGISTERED_PROJECTS[@]}"; do
        repo="$(_repo_root_of "$proj")"
        p=$(find "$repo/docs" -type f -name "runme-test_${file}.sh" 2>/dev/null | head -n 1)
        if [ -n "$p" ]; then
            matches+=("${proj}|${p}")
        fi
    done

    if [ ${#matches[@]} -eq 0 ]; then
        return 1
    fi
    if [ ${#matches[@]} -gt 1 ]; then
        log_error "测试脚本 'runme-test_${file}.sh' 在多个项目中存在，请用 --project 显式指定:"
        local m
        for m in "${matches[@]}"; do
            log_error "  - ${m%%|*}"
        done
        return 2
    fi

    printf '%s' "${matches[0]}"
    return 0
}

# 解析用于初始化的集群列表（优先 --cluster，否则 $SINGLE_CLUSTER_NAME）
resolve_init_clusters() {
    if [ ${#INIT_CLUSTERS[@]} -gt 0 ]; then
        return 0
    fi
    if [ -z "$SINGLE_CLUSTER_NAME" ]; then
        log_error "未指定 --cluster 且 SINGLE_CLUSTER_NAME 未设置"
        log_error "请使用 --cluster <name> 显式指定，或设置 SINGLE_CLUSTER_NAME 环境变量"
        exit 1
    fi
    INIT_CLUSTERS=("$SINGLE_CLUSTER_NAME")
}

# 执行单个测试脚本
run_test_script() {
    local test_script="$1"
    local script_name
    script_name=$(basename "$test_script")

    log_header "执行测试: $script_name"

    # 清除上一个测试脚本可能残留的 test_/cleanup_ 函数，
    # 避免一次传多个 --file 时 declare -F 命中旧脚本的同类函数。
    local stale
    for stale in $(declare -F | awk '$3 ~ /^(test|cleanup)_[a-z0-9_]+$/ {print $3}'); do
        unset -f "$stale"
    done

    # 加载测试脚本
    # shellcheck disable=SC1090
    source "$test_script"

    # 查找测试函数和 cleanup 函数
    local test_func cleanup_func
    test_func=$(declare -F | awk '$3 ~ /^test_[a-z0-9_]+$/ {print $3; exit}')
    cleanup_func=$(declare -F | awk '$3 ~ /^cleanup_[a-z0-9_]+$/ {print $3; exit}')

    if [ -z "$test_func" ]; then
        log_error "在 $script_name 中未找到测试函数 (test_*)"
        record_test_result 1
        return 1
    fi

    # 只执行 cleanup
    if [ "$CLEANUP_ONLY" = true ]; then
        if [ -n "$cleanup_func" ]; then
            log_info "执行 cleanup: $cleanup_func"
            if $cleanup_func; then
                log_success "Cleanup 成功"
                record_test_result 0
                return 0
            else
                log_error "Cleanup 失败"
                record_test_result 1
                return 1
            fi
        else
            log_warn "未找到 cleanup 函数"
            return 0
        fi
    fi

    # 执行测试
    log_info "执行测试函数: $test_func"
    local test_result=0
    if ! $test_func; then
        log_error "测试失败: $test_func"
        test_result=1
    else
        log_success "测试通过: $test_func"
    fi

    # 执行 cleanup
    if [ "$NO_CLEANUP" = false ] && [ -n "$cleanup_func" ]; then
        log_info "执行 cleanup: $cleanup_func"
        if ! $cleanup_func; then
            log_warn "Cleanup 失败，但不影响测试结果"
        fi
    fi

    record_test_result "$test_result"
    return "$test_result"
}

# 主函数
main() {
    parse_args "$@"

    log_info "文档自动化测试引擎"
    echo ""

    # 通用环境变量校验
    check_env

    # 解析仓库注册表
    load_repos_conf

    # ── 确定项目与测试脚本列表 ──
    local test_scripts=()
    if [ "$INIT_ONLY" = true ]; then
        if [ -z "$PROJECT" ]; then
            log_error "--init-only 必须通过 --project 指定项目"
            exit 1
        fi
    elif [ ${#RUN_FILES[@]} -gt 0 ]; then
        local file found rc fproject fpath
        for file in "${RUN_FILES[@]}"; do
            set +e
            found=$(_find_test_script "$file")
            rc=$?
            set -e
            if [ "$rc" -ne 0 ]; then
                if [ "$rc" -eq 1 ]; then
                    log_error "未找到测试脚本: runme-test_${file}.sh"
                fi
                exit 1
            fi
            fproject="${found%%|*}"
            fpath="${found#*|}"
            test_scripts+=("$fpath")
            if [ -z "$PROJECT" ]; then
                PROJECT="$fproject"
            elif [ "$PROJECT" != "$fproject" ]; then
                log_error "一次只能测试同一项目的文档（已锁定: $PROJECT，又遇到: $fproject）"
                exit 1
            fi
        done
    else
        log_error "请指定 --file 或 --init-only"
        usage
        exit 1
    fi

    # ── 解析项目仓库根 ──
    DOC_REPO_ROOT="$(_repo_root_of "$PROJECT")"
    if [ -z "$DOC_REPO_ROOT" ]; then
        log_error "项目 '$PROJECT' 未在 repos.conf 注册，或其仓库目录不存在"
        exit 1
    fi
    export DOC_REPO_ROOT PROJECT SKIP_OPERATOR_AND_CRDS

    # ── 加载项目钩子 ──
    local project_sh="$PROJECTS_DIR/$PROJECT/project.sh"
    if [ ! -f "$project_sh" ]; then
        log_error "未找到项目钩子文件: $project_sh"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$project_sh"

    # ── 项目专属环境变量校验 ──
    project_check_env || exit 1

    # ── 切换到文档仓库，使 runme 能解析其代码块 ──
    cd "$DOC_REPO_ROOT"
    log_info "项目: $PROJECT    文档仓库: $DOC_REPO_ROOT"

    # ── 环境初始化（--init-only / --force-init）──
    local should_init=false
    if [ "$INIT_ONLY" = true ] || [ "$FORCE_INIT" = true ]; then
        should_init=true
    fi

    if [ "$should_init" = true ]; then
        resolve_init_clusters
        log_info "安装通用工具 (runme / violet)..."
        check_tools
        install_runme
        install_violet
        log_info "执行 $PROJECT 项目初始化（集群: ${INIT_CLUSTERS[*]}）..."
        project_init "${INIT_CLUSTERS[@]}" || {
            log_error "$PROJECT 项目初始化失败"
            exit 1
        }
    else
        log_info "跳过环境初始化（默认不执行，可用 --force-init 强制执行）"
    fi

    # ── 轻量级准备（每次运行都执行）──
    project_prepare || {
        log_error "$PROJECT 项目准备失败"
        exit 1
    }

    if [ "$INIT_ONLY" = true ]; then
        log_success "环境初始化完成，退出（--init-only）"
        exit 0
    fi

    # ── 执行测试 ──
    echo ""
    log_info "开始执行测试..."
    echo ""

    local script
    for script in "${test_scripts[@]}"; do
        run_test_script "$script"
        echo ""
    done

    print_test_summary
}

main "$@"
