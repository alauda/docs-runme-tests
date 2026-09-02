#!/usr/bin/env bash
# 依据当前分支与 commit 计算镜像 tag 列表（逗号分隔），供 .tekton/image-build.yaml
# 构建流水线的前置步骤调用。
# 用法: bash lynx/compute-tags.sh <branch> <full-commit-sha>
#
# 规则：
#   - main（docs-runme-tests 自身主干分支） -> latest,main-<短 commit>
#   - 其余分支（包括 release-mesh-x.y）    -> <净化后的分支名>-<短 commit>，仅此一个
#
# 特性分支为什么也要能构建：本仓库的改动经常需要文档仓库的同批改动才完整
# （例如文档代码块改成 runme_run_with_assets 才能离线跑）。合入前必须能在 PR 上
# `/image-build` 出一份四仓一致的镜像真跑一遍——用 lynx/docs-refs.tsv 指定
# 文档仓库的特性分支/SHA，用这里的分支 tag 拿到不会覆盖主干的镜像地址。
# 特性分支和发版分支都不产出浮动 tag，避免污染 dailybuild 在用的镜像。
#
# 分支名净化：镜像 tag 只允许 [A-Za-z0-9_.-]，且不能以 . 或 - 开头，最长 128 字符。
# 特性分支名里的 `/`（feat/xxx）必须替换掉，否则会被当成镜像仓库路径分隔符。
#
# 兼容 bash 3.2：不使用 declare -A / mapfile / readarray。
set -u

branch="${1:?用法: compute-tags.sh <branch> <commit>}"
commit="${2:?用法: compute-tags.sh <branch> <commit>}"
short="${commit:0:7}"

# 把分支名净化成合法镜像 tag：非 [A-Za-z0-9_.-] 一律换成 -，去掉开头的 . 与 -，
# 截断到 128 字符（再减去后面 "-<7位短 commit>" 占的 8 位，留到 120）。
_sanitize_tag() {
    local s="$1"
    # 用 tr 而不是 ${s//[!A-Za-z0-9_.-]/-}：bash 3.2 的模式替换里 [!...] 取反类
    # 行为不一致，tr 的语义在各平台都确定。
    s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9_.-' '-')"
    # tr -c 会把末尾的换行也算作"补集字符"换成 -，这里去掉
    s="${s%-}"
    while [ -n "$s" ]; do
        case "$s" in
            [.-]*) s="${s#?}" ;;
            *) break ;;
        esac
    done
    printf '%s' "${s:0:120}"
}

# docs-runme-tests 自身主干分支是 main（已用 git ls-remote --symref 核实，本地也只有
# main 分支），不是 master——不要因为 Dockerfile 里 MESH_DOCS_REF 等文档仓库引用分支
# 默认值是 master 就顺手改回来，那是 servicemesh2-docs 自己的默认分支，两回事。
if [ "$branch" = "main" ]; then
    printf 'latest,main-%s\n' "$short"
    exit 0
fi

sanitized="$(_sanitize_tag "$branch")"
if [ -z "$sanitized" ]; then
    printf '错误: 分支名 %s 净化后为空，无法作为镜像 tag\n' "$branch" >&2
    exit 1
fi
printf '%s-%s\n' "$sanitized" "$short"
