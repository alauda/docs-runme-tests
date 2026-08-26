#!/usr/bin/env bash
# lynx 内置变量 → 框架变量映射
#
# lynx 会替换测试项 envs 里的 $API_URL / $USERNAME / $PASSWORD / $REGION_NAME /
# $GLOBAL_EXTERNAL_IPPOOL 等内置变量，但**不替换 $TOKEN**（virt-readiness 实测记录：
# $TOKEN 以字面量抵达）。所以凭据一律走账号密码，由 framework/acp-auth.sh 经 dex 换 token。
#
# 所有赋值都用 := ——已显式设置的值优先，便于本地调试时逐个覆盖。

lynx_adapt_env() {
    # ── 平台凭据 ──
    : "${PLATFORM_ADDRESS:=${API_URL:-}}"
    : "${PLATFORM_USERNAME:=${USERNAME:-}}"
    : "${PLATFORM_PASSWORD:=${PASSWORD:-}}"
    export PLATFORM_ADDRESS PLATFORM_USERNAME PLATFORM_PASSWORD

    # ── 被测集群 ──
    : "${SINGLE_CLUSTER_NAME:=${REGION_NAME:-}}"
    export SINGLE_CLUSTER_NAME

    # ── 报告输出目录（lynx 注入；未注入时给镜像内缺省值）──
    : "${TEST_RESULT_DIR:=/app/report}"
    mkdir -p "$TEST_RESULT_DIR" 2>/dev/null || true
    export TEST_RESULT_DIR

    # ── 镜像构建期信息（RUNME_VERSION 是 run.sh check_env 的必需项）──
    if [ -f "${FRAMEWORK_ROOT:-.}/.image-info" ]; then
        # shellcheck disable=SC1090,SC1091
        . "${FRAMEWORK_ROOT}/.image-info"
    fi
    export RUNME_VERSION DOCS_TEST_IMAGE_TAG MESH_DOCS_REF OTEL_DOCS_REF TRACING_DOCS_REF
    export MESH_DOCS_SHA OTEL_DOCS_SHA TRACING_DOCS_SHA

    # ── 外部地址池：$GLOBAL_EXTERNAL_IPPOOL 是逗号分隔的裸 IP（ares 会带引号，需剥掉），
    #    按当前 region 组装成框架需要的 JSON 格式。IPv6 走 GLOBAL_EXTERNAL_IPPOOL_V6。──
    if [ -z "${METALLB_EXTERNAL_ADDRESSES_JSON:-}" ] && \
       { [ -n "${GLOBAL_EXTERNAL_IPPOOL:-}" ] || [ -n "${GLOBAL_EXTERNAL_IPPOOL_V6:-}" ]; }; then
        local v4 v6
        v4="${GLOBAL_EXTERNAL_IPPOOL:-}"; v4="${v4//\"/}"
        v6="${GLOBAL_EXTERNAL_IPPOOL_V6:-}"; v6="${v6//\"/}"
        METALLB_EXTERNAL_ADDRESSES_JSON=$(jq -nc \
            --arg c "${SINGLE_CLUSTER_NAME:-}" --arg v4 "$v4" --arg v6 "$v6" '
            [ { cluster: $c,
                ipv4Addresses: ($v4 | split(",") | map(select(length > 0) | . + "/32")),
                ipv6Addresses: ($v6 | split(",") | map(select(length > 0) | . + "/128")) } ]')
        export METALLB_EXTERNAL_ADDRESSES_JSON
    fi

    # ── 安全缺省（模板未显式给出时）──
    : "${GLOBAL_CLUSTER_NAME:=global}"
    : "${ACP_KUBECONFIG_MODE:=direct}"
    : "${IS_DUAL_STACK:=false}"
    # lynx 场景默认不因用例失败而非 0 退出：结果由 allure 报告承载，
    # 否则 lynx 会把「测试有失败」误判成「测试任务 Error」。
    : "${EXIT_ON_TEST_FAILURE:=false}"
    export GLOBAL_CLUSTER_NAME ACP_KUBECONFIG_MODE IS_DUAL_STACK EXIT_ON_TEST_FAILURE
}
