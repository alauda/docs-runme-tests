#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031

# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# NOTE: This file is based on https://github.com/istio/istio.io/blob/master/tests/util/verify.sh.

# 去掉输出里的 ANSI 转义序列（CSI 形式：ESC [ 参数 终止字母）。
#
# 为什么断言必须过这一道：runme 用 PTY 执行代码块，于是块里的工具会认为自己在终端上，
# 带 `--color=auto` 的 grep（Ubuntu / macOS 的交互式 shell 都默认给 grep 加这个别名）
# 会给**匹配到的那段文本**套上颜色码：
#   INF <ESC>[01;31m<ESC>[KDiscovered cluster<ESC>[m<ESC>[K: Name=[cluster1], ...
# 关键字若跨过被着色的那段（如 `Discovered cluster: Name=[cluster1]`），就会被从中间
# 截断，substring 断言必然失败，而日志打出来看起来完全正常——极难排查。
#
# 仅在确实含 ESC 时才起一个 sed 子进程，其余情况原样返回，不影响既有断言的行为
# （命令替换会吃掉尾部换行，所以不能无条件走这条路）。
# 写法兼容 BSD sed（macOS）：ESC 用字面量字节，只用 BRE，不用 -E / -i。
__strip_ansi() {
    case "$1" in
        *$'\033'*) printf '%s' "$1" | sed "s/$(printf '\033')\[[0-9;]*[a-zA-Z]//g" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Returns 0 if $out and $expected are the same.  Otherwise, returns 1.
__cmp_same() {
    local out="${1//$'\r'}"
    local expected=$2
    case "$out" in *$'\033'*) out=$(__strip_ansi "$out") ;; esac

    if [[ "$out" != "$expected" ]]; then
        return 1
    fi

    return 0
}

# Returns 0 if $out contains the substring $expected.  Otherwise, returns 1.
__cmp_contains() {
    local out="${1//$'\r'}"
    local expected=$2
    case "$out" in *$'\033'*) out=$(__strip_ansi "$out") ;; esac

    if [[ "$out" != *"$expected"* ]]; then
        return 1
    fi

    return 0
}

# Returns 0 if $out does not contain the substring $expected.  Otherwise,
# returns 1.
__cmp_not_contains() {
    local out="${1//$'\r'}"
    local expected=$2
    case "$out" in *$'\033'*) out=$(__strip_ansi "$out") ;; esac

    if [[ "$out" == *"$expected"* ]]; then
        return 1
    fi

    return 0
}

# Returns 0 if $out contains the lines in $expected where "..." on a line
# matches one or more lines containing any text.  Otherwise, returns 1.
__cmp_elided() {
    local out="${1//$'\r'}"
    local expected=$2
    case "$out" in *$'\033'*) out=$(__strip_ansi "$out") ;; esac

    local contains=""
    while IFS=$'\n' read -r line; do
        if [[ "$line" =~ ^[[:space:]]*\.\.\.[[:space:]]*$ ]]; then
            if [[ "$contains" != "" && "$out" != *"$contains"* ]]; then
                return 1
            fi
            contains=""
        else
            if [[ "$contains" != "" ]]; then
                contains+=$'\n'
            fi
            contains+="$line"
        fi
    done <<< "$expected"
    if [[ "$contains" != "" && "$out" != *"$contains"* ]]; then
        return 1
    fi

    return 0
}

# Returns 0 if $out matches the regex string $expected.  Otherwise, returns 1.
__cmp_regex() {
    local out="${1//$'\r'}"
    local expected=$2
    case "$out" in *$'\033'*) out=$(__strip_ansi "$out") ;; esac

    if [[ "$out" =~ $expected ]]; then
        return 0
    fi

    return 1
}

# Returns 0 if the first line of $out matches the first line in $expected.
# Otherwise, returns 1.
__cmp_first_line() {
    local out=$1
    local expected=$2
    case "$out" in *$'\033'*) out=$(__strip_ansi "$out") ;; esac

    IFS=$'\n\r' read -r out_first_line <<< "$out"
    IFS=$'\n' read -r expected_first_line <<< "$expected"

    if [[ "$out_first_line" != "$expected_first_line" ]]; then
        return 1
    fi

    return 0
}

# Returns 0 if $out is "like" $expected. Like implies:
#   1. Same number of lines
#   2. Same number of whitespace-seperated tokens per line
#   3. Tokens can only differ in the following ways:
#        - different elapsed time values (e.g. 25s, 2m30s).
#        - different ip values. Disallows <none> and <pending> by
#          default. This can be customized by setting the
#          CMP_MATCH_IP_NONE and CMP_MATCH_IP_PENDING environment
#          variables, respectively.
#        - prefix match ending with a dash character
#        - expected ... is a wildcard token, matches anything
#        - different dates in YYYY-MM-DD (e.g. 2024-04-17)
#        - different times HH:MM:SS.MS (e.g. 22:14:45.964722028)
# Otherwise, returns 1.
__cmp_like() {
    local out="${1//$'\r'}"
    local expected=$2
    local ipregex="^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"
    local durationregex="^([0-9]+[smhd])+$"
    local versionregex="^[0-9]+\.[0-9]+\.[0-9]+$"
    local dateregex="^[0-9]{4}\-(0?[1-9]|1[012])\-(0?[1-9]|[12][0-9]|3[01])$"
    local timeregex="^(2[0-3]|[01]?[0-9]):([0-5]?[0-9]):([0-5]?[0-9]).[0-9]+$"

    if [[ "$out" != "$expected" ]]; then
        local olines=()
        while read -r line; do
            olines+=("$line")
        done <<< "$out"

        local elines=()
        while read -r line; do
            elines+=("$line")
        done <<< "$expected"

        if [[ ${#olines[@]} -ne ${#elines[@]} ]]; then
            return 1
        fi

        for i in "${!olines[@]}"; do
            # Get the next line from expected and output.
            local oline=${olines[i]}
            local eline=${elines[i]}

            # Optimization: if the lines match exactly, it's a match.
            if [[ "$oline" == "$eline" ]]; then
                continue
            fi

            # Split the expected and output lines into tokens.
            read -r -a otokens <<< "$oline"
            read -r -a etokens <<< "$eline"

            # Make sure the number of tokens match.
            if [[ ${#otokens[@]} -ne ${#etokens[@]} ]]; then
                return 1
            fi

            # Iterate and compare tokens.
            for j in "${!otokens[@]}"; do
                local etok=${etokens[j]}

                # If using wildcard, skip the match for this token.
                if [[ "$etok" == "..." ]]; then
                    continue
                fi

                # Get the token from the actual output.
                local otok=${otokens[j]}

                # Check for an exact token match.
                if [[ "$otok" == "$etok" ]]; then
                    continue
                fi

                # Check for elapsed time tokens.
                if [[ "$otok" =~ $durationregex && "$etok" =~ $durationregex ]]; then
                    continue
                fi

                # Check for version tokens.
                if [[ "$otok" =~ $versionregex && "$etok" =~ $versionregex ]]; then
                    continue
                fi

                # Check for date tokens.
                if [[ "$otok" =~ $dateregex && "$etok" =~ $dateregex ]]; then
                    continue
                fi

                # Check for hms time tokens.
                if [[ "$otok" =~ $timeregex && "$etok" =~ $timeregex ]]; then
                    continue
                fi

                # Check for IP addresses.
                if [[ "$etok" =~ $ipregex ]]; then
                    if [[ "$otok" =~ $ipregex ]]; then
                      # We got an IP address. It's a match.
                      continue
                    fi

                    if [[ "$otok" == "<pending>" && "${CMP_MATCH_IP_PENDING:-false}" == "true" ]]; then
                      # We're configured to allow <pending>. Consider this a match.
                      continue
                    fi

                    if [[ "$otok" == "<none>" && "${CMP_MATCH_IP_NONE:-false}" == "true" ]]; then
                      # We're configured to allow <none>. Consider this a match.
                      continue
                    fi
                fi

                local comm=""
                for ((k=0; k < ${#otok}; k++)) do
                    if [ "${otok:$k:1}" != "${etok:$k:1}" ]; then
                        break
                    fi
                    comm="${comm}${otok:$k:1}"
                done
                if ! [[ "$comm" =~ ^([a-zA-Z0-9_\/]+-)+ ]]; then
                    return 1
                fi
            done
        done
    fi

    return 0
}

# Returns 0 if $out "conforms to" $expected. Conformance implies:
#   1. For each line in $expected with the prefix "+ " there must be at least one
#      line in $output containing the following string.
#   2. For each line in $expected with the prefix "- " there must be no line in
#      $output containing the following string.
# Otherwise, returns 1.
__cmp_lines() {
    local out=$1
    local expected=$2

    while IFS=$'\n' read -r line; do
        if [[ "${line:0:2}" == "+ " ]]; then
            __cmp_contains "$out" "${line:2}"
        elif [[ "${line:0:2}" == "- " ]]; then
            __cmp_not_contains "$out" "${line:2}"
        else
            continue
        fi
        # shellcheck disable=SC2181
        if [[ "$?" -ne 0 ]]; then
            return 1
        fi
    done <<< "$expected"

    return 0
}
