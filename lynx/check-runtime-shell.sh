#!/usr/bin/env bash
# 校验：镜像里 runme 真的用 bash 执行 ```bash 代码块，且文档用到的 column 可用
#
# 为什么需要这条构建期闸门：
#   runme 用 $SHELL 决定代码块的解释器，$SHELL 为空时退回 /usr/bin/sh —— Ubuntu 上
#   是 dash。dash 不支持 $'\t'、数组、[[ ]] 等 bash 写法，文档里
#   `... | column -t -s $'\t'`（install-mesh、kiali 两篇的「检查可用版本」）
#   会被 dash 拆成字面量 $\t，命令直接失败。
#   本地手工跑时登录 shell 自带 SHELL=/bin/bash，这个坑只在容器里显形，
#   check-shell-compat.sh 扫的是 *.sh 脚本、看不到 mdx 里的代码块，因此单独加这条。
#   column 来自 bsdextrautils，不在 ubuntu:22.04 基础镜像里，同样只在容器里缺。
#
# 用法: bash lynx/check-runtime-shell.sh
#       需要 bin/runme 已就位（构建期在下载 runme 之后调用）。
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNME_BIN="${FRAMEWORK_ROOT}/bin/runme"

fail() { printf '错误: %s\n' "$1" >&2; exit 1; }

# ── 1. SHELL 必须指向 bash ───────────────────────────────────────────────
[ -n "${SHELL:-}" ] || fail 'SHELL 未设置，runme 会退回 dash 执行文档代码块（Dockerfile 里 ENV SHELL=/bin/bash）'
case "${SHELL}" in
    */bash) ;;
    *) fail "SHELL=${SHELL} 不是 bash，runme 会用它执行文档代码块" ;;
esac
[ -x "${SHELL}" ] || fail "SHELL=${SHELL} 不可执行"

# ── 2. column 必须存在且支持 -t -s <TAB> ────────────────────────────────
command -v column >/dev/null 2>&1 || fail 'column 不存在（Ubuntu 上由 bsdextrautils 提供），install-mesh / kiali 的「检查可用版本」会失败'
tab="$(printf '\t')"
printf 'A%sB\n' "${tab}" | column -t -s "${tab}" >/dev/null 2>&1 \
    || fail 'column -t -s <TAB> 执行失败'

# ── 3. 端到端：让 runme 真跑一个含 bash 专有语法的代码块 ────────────────
[ -x "${RUNME_BIN}" ] || fail "未找到 ${RUNME_BIN}（本检查须在下载 runme 之后执行）"

canary="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${canary}'" EXIT
# runme 按 CWD 所在 git 仓库扫描代码块，canary 目录必须是个 git 仓库
git -C "${canary}" init -q
# 三处 bash 专有语法：数组、[[ ]]、$'\t' 转义。
# $'..' 只在非双引号语境下生效，所以下面必须原样保持不加引号地传给 printf；
# dash 会把它当成字面量 $\t，正是本检查要抓的差异。
cat > "${canary}/canary.md" <<'CANARY'
# runme shell canary

```bash {name=canary:probe}
arr=(a b); [[ ${#arr[@]} -eq 2 ]] && printf 'ok%send' $'\t'
```
CANARY

got="$(cd "${canary}" && "${RUNME_BIN}" run canary:probe 2>&1)" \
    || fail "runme 执行 canary 代码块失败: ${got}"
want="$(printf 'ok\tend')"
[ "${got}" = "${want}" ] \
    || fail "runme 未用 bash 执行代码块（期望 $(printf '%q' "${want}")，实际 $(printf '%q' "${got}")）；检查 Dockerfile 的 ENV SHELL"

printf 'runtime shell 校验通过：SHELL=%s，runme 以 bash 执行代码块，column 可用\n' "${SHELL}"
