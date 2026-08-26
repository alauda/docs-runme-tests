# 镜像构建与 Edge 流水线操作手册

本文专门说明 `docs-runme-tests` 镜像的本地构建、Edge 流水线、tag 规则和首次接入操作。
其他日常改动（Case、离线资产、版本升级、发版等）见
[UPDATE-README.md](UPDATE-README.md)。

## 1. 本地构建

```bash
docker build \
  --build-arg MESH_DOCS_REF=master \
  --build-arg OTEL_DOCS_REF=main \
  --build-arg TRACING_DOCS_REF=main \
  --build-arg IMAGE_TAG=local-dev \
  -t docs-runme-tests:local-dev .
```

三个文档仓库都是公开仓库，匿名克隆，**不接受任何 token 参数**——token 拼进 clone URL 后
git 会原样写进 `.git/config` 的 `remote.origin.url`，任何拿到镜像的人都能读到。
将来真出现私有文档仓库，用 BuildKit 的 `--mount=type=secret`，不要走 build-arg。

镜像自包含：三个文档仓库按 ref 浅克隆进 `/app/`，`runme` / `violet` / `istioctl` 预置到 `bin/`，
文档引用的 17 个外部 sample YAML 落到 `assets/`。构建期会跑
[UPDATE-README.md 第 0 节](UPDATE-README.md#0-改完先跑这几条)的四条自检，任一不过即构建失败。

## 2. 流水线触发与构建步骤

- push 到 `main` 或 `release-mesh-<x.y>`（提交信息含 `ci skip` 的除外）→ 自动构建
- 任意分支的 PR 上评论 `/image-build` → 手动构建

手动触发不需要打开 Edge 页面点 Hub 流水线的“执行”：在目标 GitHub PR 的评论框中单独发送
`/image-build`（前后不要附加参数）即可。PaC 会用该 PR 的 head revision 创建本仓库的
PipelineRun；`cancel-in-progress: true` 表示同一 Repository 的旧运行会被取消。评论触发不受
push 分支白名单限制，因此特性分支也能构建。若没有 PipelineRun，先检查 `Repository`、GitHub
App 的 `issue_comment` 事件和评论是否严格匹配，再看 Task 日志。

流水线保留内联 `pipelineSpec`，但每个步骤都使用 Edge Hub 的产品化 Task：

`git-clone-amd64` / `git-clone-arm64`（`catalog/git-clone:0.10`）
→ `prepare-tags` / `prepare-arch-tags` / `prepare-refs`（`catalog/run-script:0.1`）
→ `build-image-amd64` / `build-image-arm64`（`catalog/buildah:0.10`）
→ `merge-image`（`catalog/merge-image:0.2`）。Hub resolver 按 Edge 实际配置使用
`catalog`、`kind`、`name`、`version` 四个参数。两个 Buildah Task 分别调度到原生
amd64/arm64 节点，先推送 `_buildcache-<短 SHA>-amd64/arm64` 临时 tag，再由
`merge-image` 把 `compute-tags.sh` 生成的每个正式 tag 写成包含两个架构的 manifest list。
临时 tag 仅供合并使用，建议在 Harbor retention 规则中定期清理。

两个架构使用独立的 `edge-build-cache-ceph` RWO 源码 PVC；该存储类是 Edge 构建集群
现有的跨节点构建缓存，arm64 节点可以正常绑定。不要把它们改回一个共享 RWO PVC，否则
两个原生架构 Task 的挂载会互相影响。Edge 集群必须存在带
`kubernetes.io/arch: arm64` 的构建节点；若该节点有 `build-arm:NoSchedule` 或
`builder:NoSchedule` 污点，流水线已为 clone/build Task 配置对应 toleration。`buildah` 使用 Edge 内置镜像
`registry.alauda.cn:60070/devops/tektoncd/hub/buildah:v1.33`，所有 Task 按 UID 65532
运行，不需要自定义 `privileged` step。

推镜像的凭据通过 `registryconfig` 工作区绑定 `asm-dev` 中现有的
`build-harbor.kauto.docfj` Secret。已通过 `business-build` 的 Edge Web CLI 确认该 Secret
类型为 `kubernetes.io/dockerconfigjson`、数据键为 `.dockerconfigjson`，registry 是
`https://build-harbor.alauda.cn`。账号仍需对
`build-harbor.alauda.cn/asm/docs-runme-tests` 具有 push 权限。GitHub 克隆凭据由 PaC 通过
`{{ git_auth_secret }}` 自动注入 `basic-auth` 工作区。第一次构建若出现 401/403，检查该
Harbor 账号对目标项目/仓库的 push 权限，不要另建同名但内容不明的 Secret。

## 3. tag 规则与文档 ref

| 分支 | 产出的 tag |
| --- | --- |
| `main` | `latest`、`main-<短 commit>` |
| `release-mesh-x.y`（已登记） | `release-<ACP大版本>`、`release-mesh-x.y-<短 commit>` |
| `release-mesh-x.y`（未登记） | 构建失败 |
| 其余特性分支 | 只有 `<净化后的分支名>-<短 commit>`，无浮动 tag |

分支名净化：非 `[A-Za-z0-9_.-]` 换成 `-`，去掉开头的 `.` 与 `-`，截断到 120 字符。
`feat/xxx` 里的斜杠必须换掉，否则会被当成镜像仓库路径分隔符。

三个文档仓库的 ref 不是由触发事件自动猜测，而是构建 checkout 本仓库后读取
`lynx/docs-refs.tsv`，再作为 Dockerfile 的 `MESH_DOCS_REF`、`OTEL_DOCS_REF`、
`TRACING_DOCS_REF` build-arg。可填写分支名、tag 或 commit SHA；构建会先执行
`lynx/check-docs-refs.sh`。当前 `/image-build` 评论命令不接受 `mesh=...` 这类参数，
所以要控制 ref，先在本仓库 PR 修改该 TSV，再评论 `/image-build`。若要让结果可复现，
优先填完整的不可变 commit SHA；构建通过 `lynx/clone-repo-at-ref.sh` 执行浅 fetch
并 detached checkout，因此裸 SHA 也能正常工作。文档 PR 合入主干后再把对应行改回
`master`/`main`。

## 4. 首次接入 Edge 的操作清单

当前流水线目标是 Edge 的 `business-build` 集群、`asm-dev` 命名空间（控制台工作区：
`asm~business-build~asm-dev`）。本地 kubeconfig 当前未指向该集群，可在 Edge 的 Web CLI
连接 `business-build` 后执行下面的 `kubectl` 命令。当前账号已确认具备在 `asm-dev` 创建
Repository 和 PipelineRun 的权限。

1. **确认 Harbor 凭据**：流水线直接使用 `asm-dev/build-harbor.kauto.docfj`。只检查类型、
   数据键和 registry，不要打印凭据内容：

   ```bash
   kubectl -n asm-dev get secret build-harbor.kauto.docfj \
     -o custom-columns=NAME:.metadata.name,TYPE:.type
   kubectl -n asm-dev get secret build-harbor.kauto.docfj \
     -o go-template='{{range $k,$v := .data}}{{printf "%s\\n" $k}}{{end}}'
   ```

   期望输出类型为 `kubernetes.io/dockerconfigjson`，键名为 `.dockerconfigjson`。若 Secret
   被平台轮换为新名称，同步修改 `.tekton/image-build.yaml`，不要复制或提交解码后的凭据。
   如果后续改用 Connector，保留流水线里的
   `registry-config` Task 工作区不变，只把顶层 `registryconfig` 工作区替换为 CSI 绑定，
   Connector 名称以 Edge 管理员实际创建的名称为准：

   ```yaml
   - name: registryconfig
     csi:
       driver: connectors-csi
       readOnly: true
       volumeAttributes:
         connectors: "<Connector 名称>"
         configuration.names: registry-config
   ```

   Harbor/OCI forward-proxy 会重签 TLS；因此还要在 `build-image` Task 的 `params` 中加入：

   ```yaml
   - name: tlsVerify
     value: "false"
   ```

   直接使用 `config.json`/`.dockerconfigjson` Secret 时保留默认的 `tlsVerify: "true"`。

   这是 OCI Connector 的 forward-proxy 用法，镜像地址仍使用
   `build-harbor.alauda.cn/asm/docs-runme-tests`。若管理员选择 reverse-proxy，必须同时提供
   代理镜像地址并修改 `image-repo`，不能自行猜测代理 URL。`connector.name` 和
   `connector.namespace` 已弃用；多 Connector 或同命名空间 Connector 都统一按
   Edge/Connector 文档使用 `connectors` 属性；同命名空间时填写 Connector 名称，跨命名空间
   的格式以管理员在当前 Edge 版本确认的文档为准。
2. **确认构建期网络**：`Dockerfile` 的 Ubuntu 22.04 基础镜像从公司 Harbor 的
   `build-harbor.alauda.cn/ops/ubuntu:22.04` 拉取；后续仍需访问 GitHub 和公司 Minio
   下载文档仓库及工具。若 `business-build` 禁止这些公网地址，请让平台提供内网镜像/代理；
   Buildah Task 的 `registry-config` 也支持在 Secret 根目录放 `.env` 注入代理变量。不要把
   这个问题和 Harbor push 凭据混在一起排查。
3. **注册 GitHub Repository**：`business-build/alauda-dev` 中的参考 Repository
   `alauda-distributed-tracing-docs` 仅设置 `spec.url`，说明公司 PAC 已通过全局配置提供
   GitHub App/Webhook 凭据。目标命名空间按相同模式创建：

   ```yaml
   apiVersion: pipelinesascode.tekton.dev/v1alpha1
   kind: Repository
   metadata:
     name: alauda-docs-runme-tests
     namespace: asm-dev
   spec:
     url: https://github.com/alauda/docs-runme-tests
   ```

   应用前先确认尚未注册，避免同一 URL 对应多个 Repository：

   ```bash
   kubectl -n asm-dev get repository
   kubectl apply -f repository.yaml
   ```

   不要在本仓库运行 `tkn pac create repo`：该命令可能生成额外的
   `.tekton/pipelinerun.yaml`，PAC 会把它和现有的 `image-build.yaml` 一起处理。也不要把
   GitHub PAT、App 私钥或 webhook secret 写入 Repository CR 或 Git 仓库；若最小 CR 创建后
   GitHub 没有收到 Check，再由 PAC 管理员检查全局 GitHub App 是否覆盖
   `alauda/docs-runme-tests` 以及 `push`、`pull_request`、`issue_comment` 事件。

   注册完成后，先不看构建日志，直接在第一条 PipelineRun 的 YAML/详情里核对 PAC 标记：

   ```text
   app.kubernetes.io/managed-by: pipelinesascode.tekton.dev
   pipelinesascode.tekton.dev/git-provider: github
   pipelinesascode.tekton.dev/repository: alauda-docs-runme-tests
   pipelinesascode.tekton.dev/url-org: alauda
   pipelinesascode.tekton.dev/url-repository: docs-runme-tests
   pipelinesascode.tekton.dev/git-auth-secret: pac-gitauth-...
   ```

   评论 `/image-build` 产生的运行还应有
   `pipelinesascode.tekton.dev/event-type: pull_request` 和
   `pipelinesascode.tekton.dev/pull-request: <编号>`。这些标记与参考运行
   `doc-pr-build-distributed-tracing-2x745` 的实际页面一致；缺少它们时，先排查
   Repository/Webhook 注册，不要先改 Task 参数。

代码推送到 GitHub 后，建议先在一个 PR 上评论 `/image-build` 验证，确认 Edge 中出现
`git-clone-amd64`、`git-clone-arm64`、`prepare-tags`、`prepare-arch-tags`、
`prepare-refs`、`build-image-amd64`、`build-image-arm64`、`merge-image` 八个 Task 且最终镜像可拉取，
再合入 `main`。检查命令（需切换到 `business-build` 的授权 kubeconfig）：

```bash
kubectl -n asm-dev get repository
kubectl -n asm-dev get pipelineruns --sort-by=.metadata.creationTimestamp
tkn pipelinerun logs <PipelineRun 名称> -n asm-dev -f
```

常见故障定位：没有 PipelineRun 通常是 Repository/Webhook 未注册或分支表达式未匹配；
`hub resolver` 报错时检查 Edge Hub 上的 `catalog/*` 版本；`secret not found` 或 401
检查 `build-harbor.kauto.docfj` 的命名空间、键名和 Harbor push 权限；Git clone 失败则
检查 PAC 生成的 `git_auth_secret` 是否存在以及 GitHub App 是否允许读取仓库。
