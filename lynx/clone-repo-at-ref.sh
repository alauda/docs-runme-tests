#!/usr/bin/env bash
# 按分支、tag 或 commit SHA 浅克隆一个文档仓库，并固定到 FETCH_HEAD。
#
# git clone --branch 只接受远端分支或 tag；四仓联合构建需要支持不可变 commit SHA，
# 因此这里显式 fetch 后 detached checkout。参数都作为独立 argv 传入，不拼接 shell 代码。
# 用法：bash clone-repo-at-ref.sh <repo-url> <ref> <destination>
set -euo pipefail

if [ "$#" -ne 3 ]; then
    printf '用法: %s <repo-url> <ref> <destination>\n' "$0" >&2
    exit 2
fi

repo_url="$1"
ref="$2"
destination="$3"

case "$ref" in
    '')
        printf '错误: Git ref 不能为空\n' >&2
        exit 1
        ;;
    -*)
        printf '错误: Git ref 不能以 "-" 开头：%s\n' "$ref" >&2
        exit 1
        ;;
    *[[:space:]]*)
        printf '错误: Git ref 不能包含空白：%s\n' "$ref" >&2
        exit 1
        ;;
esac

if [ -e "$destination" ]; then
    printf '错误: 目标目录已存在：%s\n' "$destination" >&2
    exit 1
fi

git init "$destination" >/dev/null
git -C "$destination" remote add origin "$repo_url"
# -- 让 ref 即使以特殊字符开头也不会被解释成 fetch 选项；上面的校验仍保留，
# 因为带有空白或非法 ref 语义的配置应尽早失败，而不是交给远端猜测。
GIT_TERMINAL_PROMPT=0 git -C "$destination" fetch --depth 1 origin -- "$ref"
git -C "$destination" checkout --detach FETCH_HEAD >/dev/null

printf '已 checkout %s -> %s\n' "$ref" "$(git -C "$destination" rev-parse HEAD)"
