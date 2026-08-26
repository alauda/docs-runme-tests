# 文档自动化测试镜像
#
# 交付给 lynx 的产物：入口 docs-test <init|mesh|otel|tracing>，报告写到 $TEST_RESULT_DIR。
# 运行时零外网依赖——runme / violet / istioctl 与文档引用的 sample YAML 全部构建期落盘。
#
# 不复用 automation/ares:base-api-latest：那是 python/pytest 栈，我们一行 Python 都不跑，
# 却会把镜像撑到 1G 以上。Edge 构建节点不保证能访问 Docker Hub，因此使用公司
# Harbor 中同步的同版本 Ubuntu 基础镜像。
FROM build-harbor.alauda.cn/ops/ubuntu:22.04

# 三个文档仓库的默认分支并不一致：mesh 是 master，otel 与 tracing 是 main——
# 这是各仓库自身历史造成的，不是笔误，后续维护请勿"顺手统一"改回同一个值。
#
# 这三个 ARG 的默认值只给本地 `docker build` 兜底。镜像构建流水线会从
# lynx/docs-refs.tsv 读取实际要用的 ref 并以 --build-arg 覆盖——需要让本仓库改动
# 与文档仓库的配套改动进同一份镜像时（例如文档代码块刚改成 runme_run_with_assets），
# 改 lynx/docs-refs.tsv，不要改这里。
ARG MESH_DOCS_REF=master
ARG OTEL_DOCS_REF=main
ARG TRACING_DOCS_REF=main
ARG RUNME_VERSION=3.16.11
ARG ALLURE_VERSION=2.24.1
# kubectl 不能低于 v1.34：v1.34 起删除命名空间级资源的输出从
# `xxx "name" deleted` 变成 `xxx "name" deleted from <ns> namespace`，
# 而 servicemesh2-docs 的三处「Example output」按新格式写（uninstalling-alauda-service-mesh
# 与 -in-ambient-mode）。用 v1.31.4 时 __cmp_contains 匹配不到，卸载测试必失败。
# 反向兼容没问题：distributed-tracing-docs 里按旧格式写的四处期待输出是新输出的前缀，
# __cmp_contains 依然命中。顺带修掉 v1.31 对 1.34.x 集群超出 ±1 版本偏斜的问题。
ARG KUBECTL_VERSION=v1.34.1
ARG IMAGE_TAG=dev
ARG TARGETARCH=amd64

LABEL io.alauda.docs.mesh-ref="${MESH_DOCS_REF}" \
      io.alauda.docs.otel-ref="${OTEL_DOCS_REF}" \
      io.alauda.docs.tracing-ref="${TRACING_DOCS_REF}" \
      io.alauda.runme-version="${RUNME_VERSION}"

# SHELL 必须显式设置：runme 执行 ```bash 代码块时用 $SHELL 决定解释器，
# 该变量为空就退回 /usr/bin/sh —— Ubuntu 上那是 dash。dash 不认 bash 的
# $'\t'、数组、[[ ]] 等写法，文档里 `column -t -s $'\t'` 会被拆成字面量 `$\t`，
# install-mesh / kiali 两篇的「检查可用版本」直接失败。
# 本地手工跑时登录 shell 已经带了 SHELL=/bin/bash，所以这个坑只在容器里显形，
# 已在 4.3.1 测试环境实测复现，别删。
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    SHELL=/bin/bash

# 基础工具 + JRE（allure CLI 需要）
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git jq openssl tzdata bash coreutils gawk sed tar gzip \
        bsdextrautils gettext-base \
        default-jre-headless; \
    rm -rf /var/lib/apt/lists/*

# kubectl
RUN set -eux; \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
        -o /usr/local/bin/kubectl; \
    chmod +x /usr/local/bin/kubectl; \
    kubectl version --client

# allure CLI（与 ares 基础镜像同版本）
RUN set -eux; \
    curl -fsSL "https://github.com/allure-framework/allure2/releases/download/${ALLURE_VERSION}/allure-${ALLURE_VERSION}.tgz" \
        -o /tmp/allure.tgz; \
    tar -xzf /tmp/allure.tgz -C /opt; \
    rm -f /tmp/allure.tgz; \
    ln -s "/opt/allure-${ALLURE_VERSION}/bin/allure" /usr/local/bin/allure; \
    allure --version

WORKDIR /app
COPY . /app/docs-runme-tests

# 三个文档仓库：按 ref 浅克隆，repos.conf 的相对路径 ../xxx-docs 在此布局下天然成立
#
# 一律匿名克隆，不接受任何 token 参数。三个仓库都是公开仓库（已用
# `GIT_TERMINAL_PROMPT=0 git ls-remote` 匿名实测过，三个都能读），所以不需要凭据；
# 而一旦把 token 拼进 clone URL，git 会把带凭据的地址原样写进 .git/config 的
# remote.origin.url，任何拿到镜像的人 `cat /app/*/.git/config` 就能读到——
# 这跟构建日志开不开 set -x 无关，是落盘残留（已实测复现）。
# 将来若真出现私有文档仓库，用 BuildKit 的 --mount=type=secret，别再走 build-arg。
# 用统一 helper 而不是 git clone --branch：后者对裸 commit SHA 会直接报
# "Remote branch <sha> not found"，无法复现四仓联合 PR 的准确组合。
RUN set -eux; \
    bash /app/docs-runme-tests/lynx/clone-repo-at-ref.sh \
        "https://github.com/alauda/servicemesh2-docs.git" \
        "${MESH_DOCS_REF}" /app/servicemesh2-docs; \
    bash /app/docs-runme-tests/lynx/clone-repo-at-ref.sh \
        "https://github.com/alauda/opentelemetry-docs.git" \
        "${OTEL_DOCS_REF}" /app/opentelemetry-docs; \
    bash /app/docs-runme-tests/lynx/clone-repo-at-ref.sh \
        "https://github.com/alauda/distributed-tracing-docs.git" \
        "${TRACING_DOCS_REF}" /app/distributed-tracing-docs; \
    grep -riE '(oauth2|x-access-token|ghp_|glpat-)' /app/servicemesh2-docs/.git/config \
        /app/opentelemetry-docs/.git/config /app/distributed-tracing-docs/.git/config \
        && { echo "clone URL 里出现了凭据，拒绝产出该镜像" >&2; exit 1; } || true

# runme / violet：预置到 bin/，运行时 _install_tool 的版本校验会直接命中并跳过下载
RUN set -eux; \
    cd /app/docs-runme-tests; \
    case "${TARGETARCH}" in \
      amd64) RUNME_ARCH=x86_64; VIOLET_ARCH=amd64 ;; \
      arm64) RUNME_ARCH=arm64;  VIOLET_ARCH=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p bin; \
    curl -fsSL "https://downloads.runme.dev/runme/${RUNME_VERSION}/runme_linux_${RUNME_ARCH}.tar.gz" -o /tmp/runme.tgz; \
    tar -xzf /tmp/runme.tgz -C bin; \
    rm -f /tmp/runme.tgz; \
    chmod +x bin/runme; \
    curl -fsSL "http://package-minio.alauda.cn:9199/packages/violet/latest/violet_linux_${VIOLET_ARCH}" -o bin/violet; \
    chmod +x bin/violet; \
    bin/runme --version | grep -q "runme version ${RUNME_VERSION}"; \
    bin/violet version | grep -q "Version: v"

# istioctl：版本从 mesh 文档的 runme 块推导，保证与 install_istioctl 的校验一致
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ISTIO_ARCH=amd64 ;; \
      arm64) ISTIO_ARCH=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    cd /app/servicemesh2-docs; \
    ISTIO_VERSION="$(/app/docs-runme-tests/bin/runme print multi-primary-multi-network:set-istio-version \
        | grep -oE 'ISTIO_VERSION=[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | cut -d= -f2)"; \
    test -n "${ISTIO_VERSION}"; \
    echo "istioctl 目标版本: ${ISTIO_VERSION}"; \
    curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-linux-${ISTIO_ARCH}.tar.gz" \
        -o /tmp/istioctl.tgz; \
    tar -xzf /tmp/istioctl.tgz -C /app/docs-runme-tests/bin; \
    rm -f /tmp/istioctl.tgz; \
    chmod +x /app/docs-runme-tests/bin/istioctl; \
    /app/docs-runme-tests/bin/istioctl version --remote=false | grep -q "client version: ${ISTIO_VERSION}"

# 离线资产：先校验清单覆盖了文档里的每个外部 URL，再逐条下载。
# 任一条缺失或下载失败即构建失败——不允许产出「缺资产的镜像」。
RUN set -eux; \
    cd /app/docs-runme-tests; \
    bash lynx/check-manifest.sh; \
    while IFS="$(printf '\t')" read -r url rel; do \
      case "${url}" in ''|'#'*) continue ;; esac; \
      mkdir -p "assets/$(dirname "${rel}")"; \
      curl -fsSL "${url}" -o "assets/${rel}"; \
      test -s "assets/${rel}"; \
    done < lynx/assets-manifest.tsv; \
    echo "已预置资产: $(find assets -type f | wc -l) 个"

# case_id 清单、文档 ref 清单、shell 兼容性自检、运行时 shell 自检
# check-runtime-shell.sh 必须放在 runme 落盘之后：它会真跑一个含 bash 专有语法的
# canary 代码块，确认 runme 用的是 bash 而不是 dash（见该脚本头部注释）。
RUN set -eux; \
    cd /app/docs-runme-tests; \
    bash lynx/check-case-ids.sh; \
    bash lynx/check-docs-refs.sh; \
    bash lynx/check-shell-compat.sh; \
    bash lynx/check-runtime-shell.sh

# 构建期信息：入口据此回填 RUNME_VERSION 等（RUNME_VERSION 是 run.sh check_env 的必需项）
# 同时落盘三个文档仓库的解析后 commit SHA：ref 可以是会移动的分支名，SHA 才能唯一
# 回答"这份镜像里到底是哪一组四仓组合"，排查 dailybuild 失败时第一步就要看它。
RUN set -eux; \
    printf 'RUNME_VERSION=%s\nDOCS_TEST_IMAGE_TAG=%s\nMESH_DOCS_REF=%s\nOTEL_DOCS_REF=%s\nTRACING_DOCS_REF=%s\nMESH_DOCS_SHA=%s\nOTEL_DOCS_SHA=%s\nTRACING_DOCS_SHA=%s\n' \
        "${RUNME_VERSION}" "${IMAGE_TAG}" "${MESH_DOCS_REF}" "${OTEL_DOCS_REF}" "${TRACING_DOCS_REF}" \
        "$(git -C /app/servicemesh2-docs        rev-parse HEAD)" \
        "$(git -C /app/opentelemetry-docs       rev-parse HEAD)" \
        "$(git -C /app/distributed-tracing-docs rev-parse HEAD)" \
        > /app/docs-runme-tests/.image-info; \
    cat /app/docs-runme-tests/.image-info

RUN set -eux; \
    chmod +x /app/docs-runme-tests/lynx/entrypoint.sh; \
    ln -s /app/docs-runme-tests/lynx/entrypoint.sh /usr/local/bin/docs-test

WORKDIR /app/docs-runme-tests
ENTRYPOINT ["/app/docs-runme-tests/lynx/entrypoint.sh"]
