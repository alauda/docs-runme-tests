# 文档自动化测试框架（docs-runme-tests）

基于 [runme](https://runme.dev) 的 MDX 文档自动化测试框架，用于验证多个文档项目中的命令和步骤可执行、输出正确。

本仓库是**独立的测试框架仓库**，与各文档仓库平级，作为兄弟目录存在：

```bash
/your/workspace/
├── docs-runme-tests/          # 本仓库：测试引擎 + 编排 + 各项目钩子
├── servicemesh2-docs/         # 文档仓库（mesh）
├── opentelemetry-docs/        # 文档仓库（otel）
└── distributed-tracing-docs/  # 文档仓库（tracing）
```

测试脚本 `runme-test_*.sh` 与被测 `.mdx` 同仓同目录（runme 按 CWD 所在 git 仓库扫描代码块；文档与测试同 PR 演进）。本仓库提供引擎、通用函数库、各项目初始化逻辑与全量编排。

## 支持的文档项目

| 项目 | 文档仓库 | 全量编排 | 说明 |
| --- | --- | --- | --- |
| mesh | `servicemesh2-docs` | `run-mesh-all.sh` | Alauda Service Mesh v2 |
| otel | `opentelemetry-docs` | `run-otel-all.sh` | Alauda Build of OpenTelemetry v2 |
| tracing | `distributed-tracing-docs` | `run-tracing-all.sh` | Alauda Distributed Tracing |

## 文档导航

| 文档 | 讲什么 |
| --- | --- |
| [configuration.md](docs/configuration.md) | 环境准备：系统要求、`repos.conf`、全部环境变量、ACP Token 自动获取、kubeconfig 管理 |
| [usage.md](docs/usage.md) | 怎么跑：`run.sh` 命令、项目自动查找、全量编排、Operator 重入、故障排除 |
| [test-catalog.md](docs/test-catalog.md) | 三个项目的完整文档测试清单与各自的前置条件 |
| [architecture.md](docs/architecture.md) | 工作原理：runme、项目钩子、脚本结构、验证工具、三层结果统计 |
| [dailybuild.md](docs/dailybuild.md) | 在 lynx / dailybuild 中运行：变量映射、Case 标签与 `CASE_TYPE` |
| [image-build.md](docs/image-build.md) | 镜像构建与 Edge 流水线：本地构建、触发方式、tag 规则、文档 ref |
| [maintenance.md](docs/maintenance.md) | **改了 X 还要同步改哪儿**：新增 Case、离线资源、版本升级、四仓联动、发版 |

## 快速开始

```bash
cd docs-runme-tests

./run.sh --project mesh --init-only    # 初始化环境
./run.sh --file install-mesh           # 跑一篇文档
./run-mesh-all.sh                      # 全量编排
```

环境变量先按 [configuration.md](docs/configuration.md) 配齐，命令细节见 [usage.md](docs/usage.md)。

## 目录结构

```bash
docs-runme-tests/
├── run.sh                      # 单测执行引擎（项目感知）
├── run-{mesh,otel,tracing}-all.sh   # 各项目全量编排
├── repos.conf                  # 文档仓库注册表
├── framework/                  # 通用引擎函数库（零项目耦合）
│   ├── common.sh               # 日志 / operator 与集群插件安装 / 通用等待与断言
│   ├── report.sh               # Run → Case → DocTest 三层结果统计
│   ├── verify.sh               # 输出比对
│   ├── acp-auth.sh             # ACP API Token 自动获取 / 校验 / 缓存
│   ├── kubeconfig.sh           # ACP kubeconfig 拉取 / 合并 / 复用
│   ├── tools.sh                # 工具检查 / runme·violet 安装 / 插件包上下架
│   ├── assets.sh               # 离线资产改走本地文件
│   └── tests/                  # 框架单测（不依赖集群与平台）
├── projects/                   # 各文档项目专属逻辑
│   ├── mesh/                   # 钩子 + Kiali 监控验证
│   ├── otel/                   # 钩子
│   └── tracing/                # 钩子 + OpenSearch / Elasticsearch / Jaeger 插件 / 调用链查询
├── lynx/                       # lynx / dailybuild 适配层
│   ├── entrypoint.sh           # 镜像入口 docs-test <init|mesh|otel|tracing>
│   ├── env-adapter.sh          # lynx 内置变量 → 框架变量
│   ├── case-filter.sh          # CASE_TYPE 表达式求值
│   ├── allure.sh               # allure 结果与报告生成
│   ├── compute-tags.sh         # 分支 + commit → 镜像 tag 列表
│   ├── *.tsv                   # 离线资产 / case_id / 文档 ref 三份清单
│   └── check-*.sh              # 五条构建期自检
├── .tekton/                    # 镜像构建流水线（Pipelines-as-Code）
├── charts/mesh-v2-test-suite/  # Mesh v2 测试套件 ACP 集群插件
└── docs/                       # 本 README 引用的各篇文档

<文档仓库>/docs/en/<path>/
├── <doc>.mdx                   # 文档（含 {name=...} 代码块）
└── runme-test_<doc>.sh         # 测试脚本，与文档同目录
```

`charts/mesh-v2-test-suite` 用于把 Mesh v2 / OpenTelemetry 测试镜像预置到 ACP 内置镜像仓库，并提供 Java OTel 示例资源；打包、上架与版本维护见 [Chart 说明](charts/mesh-v2-test-suite/README.md)。

## 参考资料

- [runme 官方文档](https://runme.dev)
- [Istio 文档测试](https://github.com/istio/istio.io/blob/master/tests/README.md)
