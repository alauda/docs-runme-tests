#!/usr/bin/env bash
# 依据当前分支与 commit 计算镜像 tag 列表（逗号分隔），供 .tekton/image-build.yaml
# 构建流水线的前置步骤调用。
# 用法: bash lynx/compute-tags.sh <branch> <full-commit-sha>
#
# 规则：
#   - main（docs-runme-tests 自身主干分支）        -> latest,main-<短 commit>
#   - release-mesh-x.y（需登记在 release-matrix.tsv） -> release-<ACP大版本>,release-mesh-x.y-<短 commit>
#   - 其余未登记分支                                -> 报错，rc=1
#
# 兼容 bash 3.2：不使用 declare -A / mapfile / readarray。
set -u

branch="${1:?用法: compute-tags.sh <branch> <commit>}"
commit="${2:?用法: compute-tags.sh <branch> <commit>}"
short="${commit:0:7}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATRIX="$SCRIPT_DIR/release-matrix.tsv"

# docs-runme-tests 自身主干分支是 main（已用 git ls-remote --symref 核实，本地也只有
# main 分支），不是 master——不要因为 Dockerfile 里 MESH_DOCS_REF 等文档仓库引用分支
# 默认值是 master 就顺手改回来，那是 servicemesh2-docs 自己的默认分支，两回事。
if [ "$branch" = "main" ]; then
    printf 'latest,main-%s\n' "$short"
    exit 0
fi

acp_version="$(awk -F'\t' -v b="$branch" '!/^#/ && $1 == b {print $2; exit}' "$MATRIX")"
if [ -z "$acp_version" ]; then
    printf '错误: 分支 %s 未在 %s 中登记对应的 ACP 大版本\n' "$branch" "$MATRIX" >&2
    exit 1
fi
printf 'release-%s,%s-%s\n' "$acp_version" "$branch" "$short"
