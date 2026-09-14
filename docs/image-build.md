# 镜像构建与 Edge 流水线

## 1. 本地构建

```bash
docker build \
  --build-arg MESH_DOCS_REF=master \
  --build-arg OTEL_DOCS_REF=main \
  --build-arg TRACING_DOCS_REF=main \
  --build-arg IMAGE_TAG=local-dev \
  -t docs-runme-tests:local-dev .
```

三个文档仓库都是公开仓库，匿名克隆，**不接受任何 token 参数**——token 拼进 clone URL 后 git 会原样写进 `.git/config` 的 `remote.origin.url`，任何拿到镜像的人都能读到。将来真出现私有文档仓库，用 BuildKit 的 `--mount=type=secret`，不要走 build-arg。

镜像自包含：三个文档仓库按 ref 浅克隆进 `/app/`；`runme` / `violet` / `istioctl` 预置到 `bin/`（`istioctl` 版本从 mesh 文档的 runme 块推导，与 `install_istioctl` 的校验一致）；文档引用的外部 sample YAML 按 `lynx/assets-manifest.tsv` 落到 `assets/`。

构建期会跑 `lynx/check-{manifest,case-ids,docs-refs,shell-compat,runtime-shell}.sh` 五条自检，任一不过即构建失败（详见 [maintenance.md 第 0 节](maintenance.md#0-改完先跑这几条)）。

想知道某个镜像里装的是哪一组四仓组合：入口日志第一行会打印 tag 与三个文档仓库的 commit SHA，镜像内也可以 `cat /app/docs-runme-tests/.image-info`。

## 2. 流水线触发与构建步骤

- push 到 `main` 或 `release-mesh-<x.y>`（提交信息含 `ci skip` 的除外）→ 自动构建
- 任意分支的 PR 上评论 `/image-build` → 手动构建

手动触发不需要打开 Edge 页面点执行：在目标 GitHub PR 的评论框中单独发送 `/image-build`（前后不要附加参数）即可。PaC 会用该 PR 的 head revision 创建 PipelineRun；`cancel-in-progress: true` 表示同一 Repository 的旧运行会被取消。评论触发不受 push 分支白名单限制，因此特性分支也能构建。若没有 PipelineRun，先检查 `Repository`、GitHub App 的 `issue_comment` 事件和评论是否严格匹配，再看 Task 日志。

流水线保留内联 `pipelineSpec`，但每个步骤都使用 Edge Hub 的产品化 Task：

```
git-clone-amd64 / git-clone-arm64      (catalog/git-clone:0.10)
  → prepare-tags / prepare-arch-tags / prepare-refs   (catalog/run-script:0.1)
  → build-image-amd64 / build-image-arm64             (catalog/buildah:0.10)
  → merge-image                                       (catalog/merge-image:0.2)
```

两个 Buildah Task 分别调度到原生 amd64/arm64 节点，先推送 `_buildcache-<短 SHA>-amd64/arm64` 临时 tag，再由 `merge-image` 把 `compute-tags.sh` 生成的每个正式 tag 写成含两个架构的 manifest list。临时 tag 仅供合并使用，建议在 Harbor retention 规则中定期清理。

几条不要动的约束：

- 两个架构使用**独立**的 `edge-build-cache-ceph` RWO 源码 PVC。不要改回一个共享 RWO PVC，否则两个原生架构 Task 的挂载会互相影响。
- Edge 集群必须存在带 `kubernetes.io/arch: arm64` 的构建节点；若该节点有 `build-arm:NoSchedule` 或 `builder:NoSchedule` 污点，流水线已为 clone/build Task 配置对应 toleration。
- `buildah` 使用 Edge 内置镜像 `registry.alauda.cn:60070/devops/tektoncd/hub/buildah:v1.33`，所有 Task 按 UID 65532 运行，不需要自定义 `privileged` step。

## 3. tag 规则与文档 ref

| 分支 | 产出的 tag |
| --- | --- |
| `main` | `latest`、`main-<短 commit>` |
| `release-mesh-x.y` | `release-mesh-x.y-<短 commit>` |
| 其余特性分支 | 只有 `<净化后的分支名>-<短 commit>`，无浮动 tag |

分支名净化：非 `[A-Za-z0-9_.-]` 换成 `-`，去掉开头的 `.` 与 `-`，截断到 120 字符。`feat/xxx` 里的斜杠必须换掉，否则会被当成镜像仓库路径分隔符。

三个文档仓库的 ref **不由触发事件猜测**，而是构建 checkout 本仓库后读取 `lynx/docs-refs.tsv`，作为 Dockerfile 的 `MESH_DOCS_REF` / `OTEL_DOCS_REF` / `TRACING_DOCS_REF` build-arg。可填分支名、tag 或 commit SHA，构建前会执行 `lynx/check-docs-refs.sh`。

`/image-build` 评论命令不接受 `mesh=...` 这类参数，所以要控制 ref，先在本仓库 PR 修改该 TSV 再评论。若要结果可复现，优先填完整的不可变 commit SHA——构建通过 `lynx/clone-repo-at-ref.sh` 执行浅 fetch 并 detached checkout，裸 SHA 也能正常工作。文档 PR 合入主干后再把对应行改回 `master` / `main`。

四仓联合改动的完整流程见 [maintenance.md 第 5 节](maintenance.md#5-四仓联合改动文档仓库与本仓库要一起改)。

## 4. Edge 环境坐标与故障定位

流水线目标是 Edge 的 `business-build` 集群、`asm-dev` 命名空间（控制台工作区 `asm~business-build~asm-dev`）。

- **推镜像凭据**：`registryconfig` 工作区绑定 `asm-dev` 的 `build-harbor.kauto.docfj` Secret（类型 `kubernetes.io/dockerconfigjson`，数据键 `.dockerconfigjson`，registry `https://build-harbor.alauda.cn`）。账号需对 `build-harbor.alauda.cn/asm/docs-runme-tests` 有 push 权限。Secret 被平台轮换为新名称时同步改 `.tekton/image-build.yaml`，**不要**复制或提交解码后的凭据。
- **GitHub 克隆凭据**：由 PaC 通过 `{{ git_auth_secret }}` 自动注入 `basic-auth` 工作区，无需手工维护。
- **Repository 注册**：本仓库的 PaC Repository 是最小形态，公司 PAC 已通过全局配置提供 GitHub App / Webhook 凭据：

  ```yaml
  apiVersion: pipelinesascode.tekton.dev/v1alpha1
  kind: Repository
  metadata:
    name: alauda-docs-runme-tests
    namespace: asm-dev
  spec:
    url: https://github.com/alauda/docs-runme-tests
  ```

  不要在本仓库运行 `tkn pac create repo`：该命令可能生成额外的 `.tekton/pipelinerun.yaml`，PAC 会把它和现有的 `image-build.yaml` 一起处理。也不要把 GitHub PAT、App 私钥或 webhook secret 写进 Repository CR 或 Git 仓库。

查看与排查（需切到 `business-build` 的授权 kubeconfig，或用 Edge Web CLI）：

```bash
kubectl -n asm-dev get repository
kubectl -n asm-dev get pipelineruns --sort-by=.metadata.creationTimestamp
tkn pipelinerun logs <PipelineRun 名称> -n asm-dev -f
```

| 现象 | 先查哪儿 |
| --- | --- |
| 没有 PipelineRun | Repository / Webhook 未注册，或分支表达式未匹配 |
| `hub resolver` 报错 | Edge Hub 上的 `catalog/*` 版本 |
| `secret not found` 或 401 | `build-harbor.kauto.docfj` 的命名空间、键名和 Harbor push 权限 |
| Git clone 失败 | PAC 生成的 `git_auth_secret` 是否存在、GitHub App 是否允许读取仓库 |
