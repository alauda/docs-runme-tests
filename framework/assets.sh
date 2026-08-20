#!/usr/bin/env bash
# 离线资产：把文档中引用的外部 URL 解析到镜像内预置文件
#
# 背景：mesh 文档有 46 处 `-f <外部 URL>` 的代码块（17 个去重 URL），运行时要在
# 测试机侧 curl 才能拿到 sample YAML。dailybuild 环境访问不了公网，故构建期把这些
# 文件下载进镜像，运行时按清单改走本地。
#
# 清单: lynx/assets-manifest.tsv，两列 TAB 分隔：<url> <相对 assets/ 的路径>
# 预置目录: $FRAMEWORK_ROOT/assets/
#
# 未命中清单的 URL 一律回退联网 curl，保证本地开发场景行为不变。

ASSETS_MANIFEST="${ASSETS_MANIFEST:-${FRAMEWORK_ROOT:-.}/lynx/assets-manifest.tsv}"
ASSETS_DIR="${ASSETS_DIR:-${FRAMEWORK_ROOT:-.}/assets}"

# 查询 URL 对应的本地文件路径。命中清单且文件真实存在才输出，否则输出空串。
# 返回码恒为 0——「没有预置」是正常情况，不是错误。
# 用法: p=$(asset_local_path <url>)
asset_local_path() {
    local url="$1" rel
    [ -f "$ASSETS_MANIFEST" ] || return 0
    rel=$(awk -F'\t' -v u="$url" '$1 == u {print $2; exit}' "$ASSETS_MANIFEST")
    [ -n "$rel" ] || return 0
    [ -f "$ASSETS_DIR/$rel" ] || return 0
    printf '%s' "$ASSETS_DIR/$rel"
}

# 取 URL 内容：命中本地预置则 cat，否则 curl。
# 提示信息走 stderr，保证 stdout 只有文件内容（调用方常用命令替换捕获）。
fetch_url_content() {
    local url="$1" local_path
    local_path=$(asset_local_path "$url")
    if [ -n "$local_path" ]; then
        log_info "使用预置资产: $url -> $local_path" >&2
        cat "$local_path"
        return $?
    fi
    curl -fsSL "$url"
}

# 把命令串里命中清单的 URL 替换为本地文件路径（未命中的原样保留）
# 用法: cmd=$(rewrite_urls_to_assets "$cmd")
rewrite_urls_to_assets() {
    local cmd="$1" url local_path
    # 用 while-read 而非 mapfile，兼容 macOS 自带的 Bash 3.2
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        local_path=$(asset_local_path "$url")
        [ -n "$local_path" ] || continue
        cmd="${cmd//$url/$local_path}"
    done < <(printf '%s' "$cmd" | grep -oE 'https?://[^[:space:]"'"'"']+' | sort -u)
    printf '%s' "$cmd"
}

# 执行 runme 代码块，先把其中的外部 URL 换成预置资产
# 用法: runme_run_with_assets <block-name>
# 说明: 用于那些直接 `runme run` 执行 `kubectl apply -f <url>` 的块。走
#       kubectl_apply_with_mirror 的块不需要改调用方——该函数内部已改用
#       fetch_url_content。
runme_run_with_assets() {
    local block="$1" content
    content=$(runme print "$block" 2>/dev/null)
    if [ -z "$content" ]; then
        log_error "无法获取代码块内容: $block"
        return 1
    fi
    content=$(rewrite_urls_to_assets "$content")
    eval "$content"
}
