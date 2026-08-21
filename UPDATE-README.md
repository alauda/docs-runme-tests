# 变更操作手册（UPDATE-README）

[README.md](README.md) 讲**怎么用**这个框架；本文讲**改了东西之后还要同步改哪儿**。

这个仓库有一堆"一处改了、别处必须跟着改"的耦合点——文档里加一个外部链接、Case 加一个标签、
发一个新版本分支，各自都牵着 3~5 个文件。漏改的典型后果不是立刻报错，而是**镜像照常构建、
dailybuild 照常绿灯，但那条用例根本没跑**。所以每一节都给了对应的自检命令。

## 0. 改完先跑这几条

```bash
# 四条清单自检（构建期也会跑，任一不过即构建失败）
bash lynx/check-manifest.sh       # 文档里的外部 URL 都登记了吗
bash lynx/check-case-ids.sh       # 每个 runme-test_*.sh 都有 case_id 吗
bash lynx/check-docs-refs.sh      # 三个文档仓库的 ref 清单合法吗
bash lynx/check-shell-compat.sh   # 有没有 macOS/bash 3.2 会炸的写法

# 全量单测（不依赖集群与网络）
for t in framework/tests/*_test.sh; do bash "$t" >/dev/null || echo "FAIL: $t"; done
```

前四条依赖三个文档仓库存在于兄弟目录（见 `repos.conf`）。

---

## 1. Case 更新：新增或修改一篇文档的测试

### 1.1 写测试脚本

测试脚本 `runme-test_<文档名>.sh` 与被测 `.mdx` **同仓同目录**，不在本仓库里。
具体写法（代码块命名、测试模式 A~I、cleanup 判断）见
[`.claude/skills/auto-test-creator/SKILL.md`](.claude/skills/auto-test-creator/SKILL.md)。

### 1.2 登记 case_id —— **必做，否则镜像构建失败**

`lynx/case-ids.tsv` 三列 TAB 分隔：`<project><TAB><doc><TAB><case_id>`。

```
mesh	install-mesh	ASM-DOC-002
```

- 编号规则：`mesh=ASM-DOC-NNN`、`otel=OTEL-DOC-NNN`、`tracing=TRACE-DOC-NNN`
- **一经分配永不复用**。文档改名时保留原编号、只改 `doc` 列——allure 报告靠它做历史对齐，
  换了编号等于历史断链。
- 新增文档取当前最大编号 +1。
- `doc` 列就是文件名去掉 `runme-test_` 前缀和 `.sh` 后缀。

自检：`bash lynx/check-case-ids.sh`（会遍历 `repos.conf` 里所有文档仓库，
发现未登记的 `runme-test_*.sh` 就报错）。

### 1.3 挂进编排脚本并选标签

编辑 `run-<project>-all.sh`。**新增 Case 一律用 `case_begin_if`，不要用裸 `case_begin`**——
后者不参与 `CASE_TYPE` 过滤，在 lynx 上会无条件执行。

```bash
if case_begin_if "12" "新功能安装测试" smoke install newfeature; then
    if (
        set -e
        ./run.sh --project mesh --file new-doc --no-cleanup
        ./run.sh --project mesh --file new-doc --cleanup-only
    ); then
        case_end 0
    else
        case_end 1
    fi
fi
```

标签怎么选：

| 想要的效果 | 加什么标签 |
| --- | --- |
| 每次都跑（环境初始化这类前置） | `always`（保留标签，恒被选中，不参与表达式求值） |
| 进首批 dailybuild | 必须带 `smoke`（首批表达式是 `smoke and not egress`） |
| 只在多集群测试项里跑 | `multicluster` |
| 暂不纳入，先攒着 | 只给功能标签（如 `opensearch`），不给 `smoke` |

DocTest 级别的细粒度开关用 `doctest_selected <tag>` 包住单篇文档（现在只有 `egress` 一处）。

### 1.4 需要新标签时，同步 release-config

`CASE_TYPE` **只支持 `and` 合取式与 `not`，不支持 `or` 和括号**（见 `lynx/case-filter.sh`）。
所以"我想让 A 和 B 两组互不相干的 Case 都跑"没法写成一个表达式——必须**另开一个 lynx 测试项**。

`apt-test/release-config/tests/<版本>/dailybuild/dailybuild_mircos_g1.yaml` 里
`spec.template.spec.tests` 现有四项：

| 测试项 | order | CASE_TYPE |
| --- | --- | --- |
| `docs-mesh` | 0 | `smoke and not egress` |
| `docs-otel` | 1 | `smoke and not egress` |
| `docs-tracing` | 2 | `smoke and not egress` |
| `docs-mesh-multicluster` | 3 | `multicluster and not egress` |

新加的 Case 如果不在这几个表达式的选择范围内，它在 dailybuild 上就是**不会跑**的，
而且不会有任何报错——只会在 allure 里显示成 `[expected] 未被 CASE_TYPE 选中` 的跳过。
改完务必用下面这段核对一遍实际选中集合：

```bash
source lynx/case-filter.sh
_case_type_matches "smoke and not egress" smoke install sidecar && echo 选中 || echo 未选中
```

### 1.5 同步 README 的两张表

- `README.md`「各项目测试清单」：加一行文档条目
- `README.md`「Case 标签与 CASE_TYPE」：加一行 Case 与标签

### 1.6 文档脚本内部主动跳过：分清两种语义

| 函数 | 语义 | allure 分类 |
| --- | --- | --- |
| `skip_test_env "原因"` | 环境不支持（缺集群 / 缺存储 / 单栈环境跑双栈） | `[env]` |
| `skip_test_expected "原因"` | 预期就不测（本轮有意不覆盖） | `[expected]` |
| `skip_test "原因"` | `skip_test_expected` 的别名，**新代码不要用** | `[expected]` |

分类会进 allure 的 `categories.json`，看板上是两栏。写错了会让"环境没配好"混进"本来就不测"，
排查时直接被忽略过去。

---

## 2. 离线资源更新（文档里的外部链接变了）

### 2.1 机制

dailybuild 环境访问不了公网。mesh 文档里有 46 处 `-f <外部 URL>` 的代码块（去重后 17 个 URL），
这些 sample YAML 在**构建期**按 `lynx/assets-manifest.tsv` 下载进镜像的 `assets/`，
运行时由 `framework/assets.sh` 改走本地文件。未命中清单的 URL 一律回退联网 `curl`，
所以本地开发行为不变。

文档侧要配合：直接 `runme run` 执行 `kubectl apply -f <url>` 的代码块，测试脚本里要调
`runme_run_with_assets <block-name>` 而不是 `runme run`。走 `kubectl_apply_with_mirror`
的块不用改——那个函数内部已经用 `fetch_url_content`。

### 2.2 URL 变了怎么改

比如 istio 从 `istio-1.30` 升到 `istio-1.32`，文档里所有 raw.githubusercontent 链接都会变：

1. 先改文档仓库（`.mdx` 里的 URL）
2. 回到本仓库，跑 `bash lynx/check-manifest.sh`——它会列出**未登记的新 URL**（报错）
   和**已不再被引用的旧 URL**（警告）
3. 按报错提示改 `lynx/assets-manifest.tsv`：两列 TAB 分隔 `<url><TAB><相对 assets/ 的路径>`。
   路径约定为**去掉协议头的 URL 全路径**，同名文件不同版本因此天然不冲突：

   ```
   https://raw.githubusercontent.com/alauda-mesh/istio/istio-1.32/samples/sleep/sleep.yaml	raw.githubusercontent.com/alauda-mesh/istio/istio-1.32/samples/sleep/sleep.yaml
   ```

4. 删掉警告里列出的 stale 行（不删不会导致构建失败，但会白下一个没人用的文件）
5. 重新跑 `bash lynx/check-manifest.sh`，要求输出"资产清单校验通过"
6. **重建镜像才生效**——`assets/` 是构建期落盘的，改了清单不重建镜像等于没改

### 2.3 新加一个引用外部 URL 的代码块

同上：写完文档 → `check-manifest.sh` 报未登记 → 补进清单 → 重建镜像。
构建期任一条 URL 下载失败即构建失败，不会产出"缺资产的镜像"。

---

## 3. 工具版本升级

| 工具 | 改哪儿 | 备注 |
| --- | --- | --- |
| `runme` | `Dockerfile` 的 `ARG RUNME_VERSION` | 同时是 `run.sh check_env` 的必需项，构建期会写进 `.image-info` 并被入口回填 |
| `allure` | `Dockerfile` 的 `ARG ALLURE_VERSION` | 建议与 ares 基础镜像保持同版本 |
| `kubectl` | `Dockerfile` 的 `ARG KUBECTL_VERSION` | |
| `istioctl` | **不用改** | 版本从 mesh 文档的 `multi-primary-multi-network:set-istio-version` 代码块推导，与 `install_istioctl` 的校验一致。文档改了版本，重建镜像即可自动跟上 |
| `buildah` | `.tekton/image-build.yaml` 的 `builder-image` 参数 | 构建集群拉不到 quay.io 时换成内网镜像，不用动编排 |

改完 `Dockerfile` 的版本 ARG 后要重建镜像验证——构建期每个工具都有 `--version | grep` 断言，
版本号写错会在构建阶段直接失败，不会带病出镜像。

---

## 4. 插件包地址更新

| 场景 | 改哪儿 |
| --- | --- |
| 本地手工跑 | `export PKG_*_URL=...`（见 `README.md`「环境变量」） |
| dailybuild 的 L5 插件（servicemesh-operator2 / kiali-operator / opentelemetry-operator2 / jaeger-cluster-plugin / mesh-v2-test-suite） | `apt-test/release-config/releases/<版本>/<release>.yaml` 里 `spec.test_plans[].release.initial.l5_plugin_packages` |
| dailybuild 的 L4 平台插件（multus / metallb / metallb-operator） | **不用写**。这类插件由当日构建产物（`product-acp-plugin-nonkernel`，`plugins: ALL`）自动上架，release-config 里从来不手写；`plugin_packages: []` 是所有 ctyunp 环境模板的固定样板，不要往里塞条目（塞了反而有覆盖自动上架全集的风险） |

lynx 上跑时**所有 `PKG_*_URL` 都不设置**，框架进 verify-only 模式：只校验平台是否已上架，
不下载不上架。真没上架时会精确报错，指明该去 release-config 补哪个包。

---

## 5. 四仓联合改动（文档仓库与本仓库要一起改）

典型场景：文档代码块从 `runme run` 改成 `runme_run_with_assets`，或者新加了外部 URL——
本仓库的改动只有配上文档仓库的同批改动才完整。

镜像默认克隆三个文档仓库的主干分支（mesh 是 `master`，otel 与 tracing 是 `main`，
不一致是各仓库自身历史，别"顺手统一"）。文档仓库的配套 PR 没合入主干之前，
从主干构建出来的镜像**不包含**那批改动。

做法：

1. 在本仓库的 PR 里改 `lynx/docs-refs.tsv`，把对应行指到文档仓库的**特性分支名或 commit SHA**：

   ```
   MESH_DOCS_REF	feat/dailybuild-lynx-integration
   OTEL_DOCS_REF	main
   TRACING_DOCS_REF	main
   ```

2. 在 PR 上评论 `/image-build`。特性分支会得到 `<净化后的分支名>-<短 commit>` 这个专属 tag，
   **不会**产出 `latest` / `release-<x>` 这类浮动 tag，不污染 dailybuild 正在用的镜像。
3. 用那个 tag 在测试环境真跑一遍。
4. 合入顺序：**文档仓库的 PR 先合** → 回本仓库把 `docs-refs.tsv` 改回主干分支名 → 本仓库 PR 合入。
5. 合入后 push 到 `main` 会自动触发构建，产出 `latest`。

排查时想知道某个镜像里到底是哪一组四仓组合：入口日志第一行就打印了 tag 与三个仓库的
commit SHA，镜像内也可以直接 `cat /app/docs-runme-tests/.image-info`。

---

## 6. 发新版本

### 6.1 发版分支

创建 `release-mesh-2.x` 分支，用于对应测试的项目。

> mesh、OTel 和 Tracing 会同时发版，所以只创建 mesh 发版分支。
> mesh 2.1 对应 OTel 2.0 和 Tracing 2.0，以此类推。

### 6.2 登记 release-matrix.tsv —— **必做，否则构建报错**

`lynx/release-matrix.tsv` 两列 TAB 分隔 `<branch><TAB><acp_version>`：

```
release-mesh-2.2	4.5
release-mesh-2.1	4.4
```

`release-mesh-*` 形状的分支**没登记就直接构建失败**（rc=1），不会降级成特性分支 tag——
那样发版镜像会缺 `release-<ACP大版本>` 这个 dailybuild 真正引用的浮动 tag。

### 6.3 同步 .tekton 的分支白名单

`.tekton/image-build.yaml` 的 `on-cel-expression` 里 `source_branch.matches(...)` 正则
必须覆盖新分支。两处（矩阵 + 正则）的分支集合要一致，否则会出现
"能触发构建但 tag 算不出来"或反过来"登记了却触发不了"。

现有正则已覆盖 `release-mesh-<x.y>` 通配，通常只需要改矩阵；改成别的命名形状时才要动正则。

### 6.4 mesh-v2-test-suite 矩阵

| docs-runme-tests 分支 | mesh-v2-test-suite 版本 |
| --------------------- | ----------------------- |
| release-mesh-2.1      | v1.0.x                  |
| release-mesh-2.2      | v2.2.x-rN               |

打包与上架方式见 [Chart 说明](charts/mesh-v2-test-suite/README.md)。

### 6.5 ACP 大版本变了

`apt-test/release-config` 里要新建 `enviroments/<新版本>/` 与 `tests/<新版本>/` 目录，
把 `dailybuild_mircos_g1.yaml` 的 asm 相关部分（两个 region、两个 initials、四个 tests）
一并带过去，并同步该目录下 `README.md` 的测试项计数。

---

## 7. 镜像构建与 tag 规则

### 7.1 本地构建

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
文档引用的 17 个外部 sample YAML 落到 `assets/`。构建期会跑第 0 节那四条自检，任一不过即构建失败。

### 7.2 流水线触发

- push 到 `main` 或 `release-mesh-<x.y>`（提交信息含 `ci skip` 的除外）→ 自动构建
- 任意分支的 PR 上评论 `/image-build` → 手动构建

流水线是内联 `pipelineSpec`（不引用 hub catalog 的 pipeline），三步：
`git-clone`（hub `extras/git-clone:0.10`）→ `prepare`（跑 `compute-tags.sh` 与读 `docs-refs.tsv`）
→ `build-push`（buildah bud 多 tag + 逐个 push）。

推镜像的凭据走 Tekton 标准的 creds-init：流水线 ServiceAccount 上挂一个带
`tekton.dev/docker-0: https://build-harbor.alauda.cn` 注解的 registry Secret 即可。
第一次构建若在 push 步骤报 401，是那个 Secret 没配，不是编排问题。

### 7.3 tag 规则

| 分支 | 产出的 tag |
| --- | --- |
| `main` | `latest`、`main-<短 commit>` |
| `release-mesh-x.y`（已登记） | `release-<ACP大版本>`、`release-mesh-x.y-<短 commit>` |
| `release-mesh-x.y`（未登记） | 构建失败 |
| 其余特性分支 | 只有 `<净化后的分支名>-<短 commit>`，无浮动 tag |

分支名净化：非 `[A-Za-z0-9_.-]` 换成 `-`，去掉开头的 `.` 与 `-`，截断到 120 字符。
`feat/xxx` 里的斜杠必须换掉，否则会被当成镜像仓库路径分隔符。

---

## 8. 新增一个文档项目

1. `repos.conf` 加一行 `<project>:../<repo>`
2. 新建 `projects/<project>/project.sh`，实现 `project_check_env` / `project_init` / `project_prepare`
3. 新建 `run-<project>-all.sh`（照抄 `run-otel-all.sh` 的骨架：`report_init` + `trap report_finalize EXIT`
   + `export RUNME_TEST_ORCHESTRATED=1`）
4. `lynx/case-ids.tsv` 起一个新的编号前缀，并在 `lynx/check-case-ids.sh` 的编号正则里加上它
5. `lynx/docs-refs.tsv` 加一行 ref，并在 `lynx/check-docs-refs.sh` 的键名正则里加上它
6. `Dockerfile` 加一段 `git clone`，并把新仓库的 SHA 写进 `.image-info`
7. `lynx/entrypoint.sh` 的 `case "$MODE"` 白名单加上新项目
8. release-config 加一个 lynx 测试项

---

## 9. 速查：我改了 X，还要动谁

| 改动 | 必须同步 | 自检 |
| --- | --- | --- |
| 新增 `runme-test_*.sh` | `case-ids.tsv`、`run-*-all.sh`、README 两张表 | `check-case-ids.sh` |
| 给 Case 加/改标签 | release-config 的 `CASE_TYPE`、README 标签表 | `case-filter.sh` 手工验算 |
| 文档里新增/修改外部 URL | `assets-manifest.tsv`、重建镜像 | `check-manifest.sh` |
| 文档块改用 `runme_run_with_assets` | `lynx/docs-refs.tsv` 指到文档特性分支 | `/image-build` 出镜像真跑 |
| 升级 runme/allure/kubectl | `Dockerfile` 的 ARG、重建镜像 | 构建期版本断言 |
| 升级 istio | 只改文档、重建镜像 | 构建期 istioctl 版本断言 |
| 新增发版分支 | `release-matrix.tsv`、`.tekton` 分支正则 | `compute_tags_test.sh` |
| 新增 L5 插件包 | release-config 的 `l5_plugin_packages` | verify-only 的未上架报错 |
| 改任何 `.sh` | —— | `check-shell-compat.sh` + 全量单测 |
