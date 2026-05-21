#!/usr/bin/env bash
# 通用工具与插件包管理函数库
#
# 提供：必备工具检查、runme/violet 工具安装、ACP 插件包下载/检查/上传。
# 由 run.sh 引擎在 source common.sh / verify.sh / kubeconfig.sh 之后加载。

__TOOLS_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# bin/ 与 package/ 均位于框架仓库根目录（framework/ 的上一级）
BIN_DIR="${BIN_DIR:-$(cd "$__TOOLS_SH_DIR/.." && pwd)/bin}"
PKG_DIR="${PKG_DIR:-$(cd "$__TOOLS_SH_DIR/.." && pwd)/package}"

mkdir -p "$BIN_DIR" "$PKG_DIR"

# 检查必要工具
check_tools() {
    log_info "检查必要工具..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 工具未找到，请先安装 kubectl"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        log_error "curl 工具未找到，请先安装 curl"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq 工具未找到，请先安装 jq"
        exit 1
    fi

    log_success "所有必要工具检查通过"
}

# ==============================================================================
# 工具安装公共函数
# ==============================================================================

# 检测操作系统和架构,根据传入的命名约定设置全局变量
# 用法: _detect_os_arch <darwin_name> <linux_name> <amd64_name> <arm64_name>
# 输出: 设置 DETECTED_OS / DETECTED_ARCH 两个全局变量
# 失败 (不支持的平台): exit 1
# 示例:
#   _detect_os_arch darwin linux x86_64 arm64    # runme:    runme_${os}_${arch}.tar.gz
#   _detect_os_arch darwin linux amd64  arm64    # violet:   violet_${os}_${arch}
#   _detect_os_arch osx    linux amd64  arm64    # istioctl: istioctl-${ver}-${os}-${arch}.tar.gz
_detect_os_arch() {
    local darwin_name="$1" linux_name="$2"
    local amd_name="$3" arm_name="$4"

    case "$(uname -s)" in
        Darwin) DETECTED_OS="$darwin_name" ;;
        Linux)  DETECTED_OS="$linux_name" ;;
        *)
            log_error "不支持的操作系统: $(uname -s)"
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) DETECTED_ARCH="$amd_name" ;;
        arm64|aarch64) DETECTED_ARCH="$arm_name" ;;
        *)
            log_error "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac
}

# 通用工具安装(下载 → 解压 → 验证),适用于 runme/violet/istioctl 等单二进制工具
# 用法: _install_tool <name> <version_cmd_args> <version_pattern> <url> <is_archive>
# 参数:
#   name              - 工具名 (binary 的最终文件名,放置在 BIN_DIR/<name>)
#   version_cmd_args  - 取版本命令的参数 (如 "--version" / "version --remote=false")
#   version_pattern   - 版本输出需包含的字符串 (如 "runme version 1.2.3" / "Version: v")
#   url               - 下载 URL
#   is_archive        - "true" 表示 URL 是 tar.gz 需解压,"false" 表示直接是二进制
# 行为:
#   - 已安装且匹配:   log_success + return 0
#   - 不存在或不匹配: 重新下载安装,失败则 exit 1
_install_tool() {
    local name="$1"
    local version_cmd_args="$2"
    local version_pattern="$3"
    local url="$4"
    local is_archive="$5"
    local bin_path="$BIN_DIR/$name"

    log_info "检查 $name 工具 (期望版本含: $version_pattern)..."

    # 已存在则做一次版本校验,匹配则直接返回
    if [ -f "$bin_path" ]; then
        local current
        # shellcheck disable=SC2086
        current=$("$bin_path" $version_cmd_args 2>&1 || echo "")
        if echo "$current" | grep -q "$version_pattern"; then
            log_success "$name 已安装"
            return 0
        fi
        log_warn "$name 版本不匹配,重新安装 (当前输出: ${current:-空})"
    fi

    log_info "下载 $name: $url"
    if [ "$is_archive" = "true" ]; then
        local tarball="$BIN_DIR/${name}.tar.gz"
        curl -fsSL "$url" -o "$tarball" || {
            log_error "下载 $name 失败: $url"
            exit 1
        }
        log_info "解压 $name..."
        tar -xzf "$tarball" -C "$BIN_DIR" || {
            log_error "解压 $name 失败"
            exit 1
        }
        rm -f "$tarball"
    else
        curl -fsSL "$url" -o "$bin_path" || {
            log_error "下载 $name 失败: $url"
            exit 1
        }
    fi

    chmod +x "$bin_path"

    # 验证安装
    local actual
    # shellcheck disable=SC2086
    actual=$("$bin_path" $version_cmd_args 2>&1 || echo "")
    if echo "$actual" | grep -q "$version_pattern"; then
        log_success "$name 安装成功"
    else
        log_error "$name 安装验证失败 (输出: $actual)"
        exit 1
    fi
}

# ==============================================================================
# 具体工具安装函数 (基于 _detect_os_arch + _install_tool 公共逻辑)
# ==============================================================================

# 安装 runme 工具 (版本由 RUNME_VERSION 环境变量指定)
install_runme() {
    _detect_os_arch darwin linux x86_64 arm64
    local url="https://downloads.runme.dev/runme/${RUNME_VERSION}/runme_${DETECTED_OS}_${DETECTED_ARCH}.tar.gz"
    _install_tool runme "--version" "runme version ${RUNME_VERSION}" "$url" true
}

# 安装 violet 工具 (固定 latest,无具体版本号校验)
install_violet() {
    _detect_os_arch darwin linux amd64 arm64
    local url="http://package-minio.alauda.cn:9199/packages/violet/latest/violet_${DETECTED_OS}_${DETECTED_ARCH}"
    # violet 的版本输出不包含具体版本号,改为验证输出中包含 "Version: v" 来确认工具可用
    _install_tool violet "version" "Version: v" "$url" false
}

# 下载插件包
download_package() {
    local url="$1"
    local filename
    filename=$(basename "$url")

    if [ -f "$PKG_DIR/$filename" ]; then
        log_info "插件包已存在: $filename"
        return 0
    fi

    log_info "下载插件包: $filename"
    curl -fsSL "$url" -o "$PKG_DIR/$filename" || {
        log_error "下载插件包失败: $url"
        return 1
    }

    log_success "下载完成: $filename"
}

# 检查插件是否已上传
check_package_uploaded() {
    local cluster="$1"
    local package_url="$2"

    # 解析 ArtifactVersion 名称
    local artifact_version
    artifact_version=$(parse_artifact_version_from_package "$package_url")

    # 两种可能的名称：原始名称 和 带 operatorhub- 前缀的名称
    local artifact_version_prefixed="operatorhub-${artifact_version}"

    log_info "检查插件是否已上传到集群 $cluster: $artifact_version 或 $artifact_version_prefixed"

    # 依次检查两种名称
    local name
    for name in "$artifact_version" "$artifact_version_prefixed"; do
        # 检查资源是否存在
        if ! kubectl --context="$cluster" get artifactversion -n cpaas-system "$name" &> /dev/null; then
            continue
        fi

        # 检查状态
        local reason
        reason=$(kubectl --context="$cluster" get artifactversion -n cpaas-system "$name" -o jsonpath='{.status.reason}' 2>/dev/null || echo "")

        if [ "$reason" = "Success" ]; then
            log_success "插件已上传: $name"
            return 0
        fi
    done

    return 1
}

# 上传插件包到集群
upload_package() {
    local cluster="$1"
    local package_url="$2"
    local filename
    filename=$(basename "$package_url")

    log_info "上传插件包到集群 $cluster: $filename"

    "$BIN_DIR/violet" push "$PKG_DIR/$filename" \
        --platform-address="$PLATFORM_ADDRESS" \
        --platform-username="$PLATFORM_USERNAME" \
        --platform-password="$PLATFORM_PASSWORD" \
        --clusters="$cluster" || {
        log_error "上传插件包失败: $filename -> $cluster"
        return 1
    }

    log_success "上传成功: $filename -> $cluster"
}
