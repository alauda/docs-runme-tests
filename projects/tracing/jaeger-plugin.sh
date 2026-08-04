#!/usr/bin/env bash
# Alauda Build of Jaeger v2 集群插件安装模块（tracing 两篇安装文档的共享测试逻辑）
#
# 两篇安装文档（installing-distributed-tracing-elasticsearch / -opensearch）的
# 「Installing the Alauda Build of Jaeger v2 Cluster Plugin > Installing via the CLI」
# 章节内容完全一致（仅 runme 代码块前缀不同），故安装逻辑抽象于此，由两个测试脚本
# 以各自前缀调用，防止重复：
#   tracing_install_jaeger_plugin <runme_prefix> [target_cluster]
#
# 与 framework/common.sh 的通用 install_cluster_plugin 的关系：
#   - 上架与幂等模式一致：violet push 到 Global（已上架跳过）、按 label 复用已存在的
#     ModuleInfo（平台会按内容将其重命名为 <cluster>-<hash>，不能按名字查）、等待
#     phase=Running；并复用同组辅助函数（_wait_for_moduleconfig /
#     _wait_for_moduleinfo_running）。
#   - 差异：「查版本 / 创建 ModuleInfo / 验证」不走内联渲染，而是执行文档 CLI 章节的
#     runme 代码块（含 <target-cluster> / <plugin-version> 占位符替换），以获得文档
#     代码块的测试覆盖。仅覆盖 CLI 安装方案，Web console 章节不涉及。
#
# 依赖环境变量:
#   PKG_JAEGER_CLUSTER_PLUGIN_URL - 插件包下载地址（project_check_env 强制校验；
#                                   未上架时自动下载并 violet push 到 Global）
#   SINGLE_CLUSTER_NAME           - 默认目标集群（可用第二参数覆盖）

# 全局侧步骤：上架 + 文档代码块 1-3（查已发布版本、创建 ModuleInfo、验证 Running）。
# 集群插件资源（ModuleConfig / ModuleInfo）仅存于 Global 集群，故单独成函数，
# 函数内 local export KUBECONFIG 指向 Global，返回后自动还原调用方 KUBECONFIG。
# 用法: _tracing_jaeger_plugin_install_via_global <runme_prefix> <target_cluster> <global_kubeconfig>
_tracing_jaeger_plugin_install_via_global() {
    local runme_prefix="$1" target_cluster="$2" global_kc="$3"
    local module_name="jaeger-cluster-plugin"
    local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"

    local KUBECONFIG="$global_kc"
    export KUBECONFIG

    # 1. 上架插件包（对应文档 note：从 Customer Portal 下载后用 violet 上架平台。
    #    ModuleConfig 已存在说明已上架，跳过；violet 对已存在的包/镜像会自动跳过）
    if kubectl get moduleconfigs -l "cpaas.io/module-name=${module_name}" -o name 2>/dev/null | grep -q .; then
        log_info "插件 $module_name 已上架（ModuleConfig 存在），跳过 push"
    else
        log_info "上架插件包到 Global 集群: $(basename "$PKG_JAEGER_CLUSTER_PLUGIN_URL")"
        download_package "$PKG_JAEGER_CLUSTER_PLUGIN_URL" || return 1
        upload_package "$global_cluster" "$PKG_JAEGER_CLUSTER_PLUGIN_URL" || return 1
        # 上架成功后平台异步创建 ModulePlugin / ModuleConfig，等待 ModuleConfig 出现
        if ! _wait_for_moduleconfig "$module_name"; then
            log_error "等待 ModuleConfig 超时: module-name=$module_name (上架后平台未在预期时间内创建 ModuleConfig)"
            return 1
        fi
    fi

    # 2. 文档代码块 1: 查询已发布的插件版本
    log_info "查询已发布的插件版本 (${runme_prefix}:list-jaeger-plugin-versions)"
    local versions_output
    versions_output=$(runme run "${runme_prefix}:list-jaeger-plugin-versions" 2>&1) || {
        log_error "查询插件版本失败"
        log_error "输出: $versions_output"
        return 1
    }
    echo "$versions_output"

    # 3. 从代码块输出解析目标版本（对齐 _cluster_plugin_resolve_version 策略：
    #    优先用包名解析出的 vX.Y.Z 匹配已发布版本，否则取最高版本）
    local versions pkg_version version
    versions=$(echo "$versions_output" | awk 'NR>1 && $2 ~ /^v?[0-9]/ {print $2}')
    if [ -z "$versions" ]; then
        log_error "未从代码块输出解析到已发布的 $module_name 版本"
        return 1
    fi
    pkg_version=$(basename "$PKG_JAEGER_CLUSTER_PLUGIN_URL" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -n "$pkg_version" ] && echo "$versions" | grep -qx "$pkg_version"; then
        version="$pkg_version"
    else
        version=$(echo "$versions" | sort -V | tail -n 1)
    fi
    log_success "目标版本: $version"

    # 4. 幂等检查：按 label 定位已存在的 ModuleInfo，存在则复用、跳过创建
    #    （避免重复创建触发重复安装；两篇安装文档的测试先后执行时第二次走此分支）
    local selector="cpaas.io/module-name=${module_name},cpaas.io/cluster-name=${target_cluster}"
    local existing_name
    existing_name=$(kubectl get moduleinfo -l "$selector" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$existing_name" ]; then
        log_info "检测到已存在的 ModuleInfo: $existing_name，复用并等待就绪"
    else
        # 文档代码块 2: 替换 <target-cluster> / <plugin-version> 占位符后创建 ModuleInfo
        log_info "创建 ModuleInfo 安装插件到 $target_cluster (${runme_prefix}:create-jaeger-plugin-moduleinfo)"
        local create_cmd
        create_cmd=$(runme print "${runme_prefix}:create-jaeger-plugin-moduleinfo") || {
            log_error "获取 ModuleInfo 创建代码块失败"
            return 1
        }
        create_cmd="${create_cmd//<target-cluster>/$target_cluster}"
        create_cmd="${create_cmd//<plugin-version>/$version}"
        eval "$create_cmd" || {
            log_error "创建 ModuleInfo 失败"
            return 1
        }
    fi

    # 5. 等待插件安装完成（文档：STATUS 列变为 Running 即安装成功）
    log_info "等待集群插件安装完成 (phase=Running)"
    if ! _wait_for_moduleinfo_running "$module_name" "$target_cluster"; then
        log_error "集群插件 $module_name 安装超时或失败"
        kubectl get moduleinfo -l "$selector" 2>/dev/null || true
        return 1
    fi

    # 6. 文档代码块 3: 验证 ModuleInfo 状态。NAME（<cluster>-<hash>）与 AGE 为动态值，
    #    用 __cmp_lines 校验关键字段
    log_info "验证插件安装状态 (${runme_prefix}:verify-jaeger-plugin-moduleinfo)"
    local verify_output
    verify_output=$(runme run "${runme_prefix}:verify-jaeger-plugin-moduleinfo" 2>&1) || {
        log_error "验证 ModuleInfo 失败"
        log_error "输出: $verify_output"
        return 1
    }
    if ! __cmp_lines "$verify_output" "$(cat <<EOF
+ ${target_cluster}
+ Running
EOF
)"; then
        log_error "ModuleInfo 状态验证失败（期待包含 ${target_cluster} 与 Running）"
        log_error "实际输出: $verify_output"
        return 1
    fi
    log_success "ModuleInfo 状态验证通过 (STATUS=Running)"
    return 0
}

# 安装 Alauda Build of Jaeger v2 集群插件（执行文档 CLI 章节的 runme 代码块）
# 用法: tracing_install_jaeger_plugin <runme_prefix> [target_cluster]
# 参数:
#   runme_prefix   - 文档代码块前缀（install-tracing-elasticsearch / install-tracing-opensearch）
#   target_cluster - 插件落地的目标集群，默认 $SINGLE_CLUSTER_NAME（即当前被测业务集群）
# NOTE: 依赖 Global 集群独立 kubeconfig 已生成（tracing project_init 的 ensure_kubeconfig
#       会追加 Global）；调用方 KUBECONFIG 需指向目标业务集群（文档代码块 4 在其上执行）
tracing_install_jaeger_plugin() {
    local runme_prefix="$1"
    local target_cluster="${2:-${SINGLE_CLUSTER_NAME:-}}"

    if [ -z "$runme_prefix" ] || [ -z "$target_cluster" ]; then
        log_error "tracing_install_jaeger_plugin: 缺少必要参数"
        log_error "用法: tracing_install_jaeger_plugin <runme_prefix> [target_cluster]（默认 \$SINGLE_CLUSTER_NAME）"
        return 1
    fi
    if [ -z "${PKG_JAEGER_CLUSTER_PLUGIN_URL:-}" ]; then
        log_error "缺少环境变量 PKG_JAEGER_CLUSTER_PLUGIN_URL（Jaeger v2 集群插件包下载地址）"
        return 1
    fi

    local global_cluster="${GLOBAL_CLUSTER_NAME:-global}"
    local global_kc="$KUBECONFIG_DIR/${global_cluster}.yaml"
    if [ ! -f "$global_kc" ]; then
        log_error "未找到 Global kubeconfig: $global_kc"
        log_error "请先执行 './run.sh --project tracing --init-only' 让框架拉取 ${global_cluster} 集群 kubeconfig"
        return 1
    fi

    log_info "=========================================="
    log_info "安装集群插件 jaeger-cluster-plugin 到目标集群 $target_cluster (经 Global 集群 $global_cluster 操作)"
    log_info "=========================================="

    # 全局侧：上架 + 文档代码块 1-3
    _tracing_jaeger_plugin_install_via_global "$runme_prefix" "$target_cluster" "$global_kc" || return 1

    # 目标集群侧：文档代码块 4 —— 验证插件在目标集群创建的镜像清单 ConfigMap
    # （沿用调用方 KUBECONFIG，即当前被测业务集群；后续 get-platform-config 从该
    # ConfigMap 读取 Jaeger 相关镜像地址）
    log_info "验证目标集群 ConfigMap (${runme_prefix}:verify-jaeger-plugin-configmap)"
    local cm_output
    cm_output=$(runme run "${runme_prefix}:verify-jaeger-plugin-configmap" 2>&1) || {
        log_error "验证 jaeger-cluster-plugin-manifest ConfigMap 失败"
        log_error "输出: $cm_output"
        return 1
    }
    if ! __cmp_lines "$cm_output" "$(cat <<'EOF'
+ jaeger-cluster-plugin-manifest
EOF
)"; then
        log_error "ConfigMap 验证失败（期待包含 jaeger-cluster-plugin-manifest）"
        log_error "实际输出: $cm_output"
        return 1
    fi

    log_success "=========================================="
    log_success "集群插件 jaeger-cluster-plugin 安装完成 (目标集群 $target_cluster)"
    log_success "=========================================="
    return 0
}
