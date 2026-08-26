#!/usr/bin/env bash
# CASE_TYPE 表达式求值
#
# 语法（ares pytest -m 语义的子集）：只支持 and 连接的合取式与 not 取反，
# 例如 "smoke and not egress"。不支持 or 与括号——需要并集时多开一个 lynx 测试项。
#
# 保留标签 always：带该标签的 Case 恒被选中，不参与表达式求值。用于环境初始化
# 这类「任何子集都必须先跑」的前置 Case。

# _case_type_matches <case_type_expr> <tag>...
# 返回: 0=选中  1=未选中  2=表达式非法
_case_type_matches() {
    local expr="$1"; shift
    local tags=" $* "

    # 保留标签 always：无条件选中
    case "$tags" in *" always "*) return 0 ;; esac

    # 空表达式（或全空白）= 全选
    case "$expr" in
        *[![:space:]]*) : ;;
        *) return 0 ;;
    esac

    # or / 括号：明确不支持，报非法而不是静默误判
    case " $expr " in
        *" or "*|*"("*|*")"*)
            printf '不支持的 CASE_TYPE 表达式（仅支持 and / not 合取式）: %s\n' "$expr" >&2
            return 2
            ;;
    esac

    local negate=0 token
    for token in $expr; do
        case "$token" in
            and) continue ;;
            not) negate=1; continue ;;
            *)
                if [ "$negate" -eq 1 ]; then
                    case "$tags" in *" $token "*) return 1 ;; esac
                else
                    case "$tags" in
                        *" $token "*) : ;;
                        *) return 1 ;;
                    esac
                fi
                negate=0
                ;;
        esac
    done
    return 0
}
