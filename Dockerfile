# 文档自动化测试镜像
#
# 交付给 lynx 的产物：入口 docs-test <init|mesh|otel|tracing>，报告写到 $TEST_RESULT_DIR。
# 运行时零外网依赖——runme / violet / istioctl 与文档引用的 sample YAML 全部构建期落盘。
#
# 不复用 automation/ares:base-api-latest：那是 python/pytest 栈，我们一行 Python 都不跑，
# 却会把镜像撑到 1G 以上。
FROM ubuntu:22.04

# 三个文档仓库的默认分支并不一致：mesh 是 master，otel 与 tracing 是 main——
# 这是各仓库自身历史造成的，不是笔误，后续维护请勿"顺手统一"改回同一个值。
ARG MESH_DOCS_REF=master
ARG OTEL_DOCS_REF=main
ARG TRACING_DOCS_REF=main
ARG RUNME_VERSION=3.16.11
ARG ALLURE_VERSION=2.24.1
ARG KUBECTL_VERSION=v1.31.4
ARG IMAGE_TAG=dev
ARG TARGETARCH=amd64
# 文档仓库若为私有仓库，构建时传入只读 token（公开仓库留空即可）
ARG GIT_TOKEN=""

LABEL io.alauda.docs.mesh-ref="${MESH_DOCS_REF}" \
      io.alauda.docs.otel-ref="${OTEL_DOCS_REF}" \
      io.alauda.docs.tracing-ref="${TRACING_DOCS_REF}" \
      io.alauda.runme-version="${RUNME_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8

# 基础工具 + JRE（allure CLI 需要）
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git jq openssl tzdata bash coreutils gawk sed tar gzip \
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
# 注意：这里特意用 set -eu，不加 -x（其它 RUN 块都是 set -eux）——AUTH 在
# GIT_TOKEN 非空时会拼出内嵌 token 的完整 clone URL，-x 回显命令会把 token 明文
# 打进构建日志。README 里写了私有仓库场景要传 --build-arg GIT_TOKEN=<只读 token>，
# 真有人这么传时这里绝不能开 -x；以后不要为了「统一风格」把 -x 加回来。
RUN set -eu; \
    if [ -n "${GIT_TOKEN}" ]; then AUTH="oauth2:${GIT_TOKEN}@"; else AUTH=""; fi; \
    git clone --depth 1 --branch "${MESH_DOCS_REF}"    "https://${AUTH}github.com/alauda/servicemesh2-docs.git"        /app/servicemesh2-docs; \
    git clone --depth 1 --branch "${OTEL_DOCS_REF}"    "https://${AUTH}github.com/alauda/opentelemetry-docs.git"       /app/opentelemetry-docs; \
    git clone --depth 1 --branch "${TRACING_DOCS_REF}" "https://${AUTH}github.com/alauda/distributed-tracing-docs.git" /app/distributed-tracing-docs

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

# case_id 清单自检
RUN set -eux; cd /app/docs-runme-tests; bash lynx/check-case-ids.sh

# 构建期信息：入口据此回填 RUNME_VERSION 等（RUNME_VERSION 是 run.sh check_env 的必需项）
RUN set -eux; \
    printf 'RUNME_VERSION=%s\nDOCS_TEST_IMAGE_TAG=%s\nMESH_DOCS_REF=%s\nOTEL_DOCS_REF=%s\nTRACING_DOCS_REF=%s\n' \
        "${RUNME_VERSION}" "${IMAGE_TAG}" "${MESH_DOCS_REF}" "${OTEL_DOCS_REF}" "${TRACING_DOCS_REF}" \
        > /app/docs-runme-tests/.image-info

RUN set -eux; \
    chmod +x /app/docs-runme-tests/lynx/entrypoint.sh; \
    ln -s /app/docs-runme-tests/lynx/entrypoint.sh /usr/local/bin/docs-test

WORKDIR /app/docs-runme-tests
ENTRYPOINT ["/app/docs-runme-tests/lynx/entrypoint.sh"]
