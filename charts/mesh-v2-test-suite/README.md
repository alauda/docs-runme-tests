# mesh-v2-test-suite

Mesh v2 测试套件——一个仅用于分发测试镜像的 ACP 集群插件。

## 插件作用

将一组用于 Mesh v2 验证、教程和回归测试的容器镜像打包随插件下发。用户在 ACP 上安装本插件后，这些镜像会被同步到平台内置镜像仓库，业务工作负载可直接引用，无需再从外部公网拉取。

本插件**不部署任何工作负载**，安装时只在 `cpaas-system` 命名空间下创建两个 ConfigMap：

- `mesh-v2-test-suite-manifest`：占位 ConfigMap，声明插件已安装并提供镜像清单。
- `mesh-v2-test-suite-java-otel-demo`：承载 Java OTel 示例服务的 manifest（Instrumentation + consumer / provider / asm-client）及配套的自定义监控面板（HTTP / JVM MonitorDashboard），需要时由用户用 `kubectl apply` 一键部署，详见 [部署 Java OTel 示例服务](#部署-java-otel-示例服务)。

## 包含的镜像

镜像清单维护在 [`values.yaml`](./values.yaml) 的 `global.images` 字段。当前版本包含：

| 名称                    | 仓库路径                                     | 版本      |
| ----------------------- | -------------------------------------------- | --------- |
| curl                    | `asm/curlimages/curl`                        | `8.16.0`  |
| go-httpbin              | `asm/mccutchen/go-httpbin`                   | `v2.15.0` |
| bookinfo-details-v1     | `asm/istio/examples-bookinfo-details-v1`     | `1.20.3`  |
| bookinfo-ratings-v1     | `asm/istio/examples-bookinfo-ratings-v1`     | `1.20.3`  |
| bookinfo-reviews-v1     | `asm/istio/examples-bookinfo-reviews-v1`     | `1.20.3`  |
| bookinfo-reviews-v2     | `asm/istio/examples-bookinfo-reviews-v2`     | `1.20.3`  |
| bookinfo-reviews-v3     | `asm/istio/examples-bookinfo-reviews-v3`     | `1.20.3`  |
| bookinfo-productpage-v1 | `asm/istio/examples-bookinfo-productpage-v1` | `1.20.3`  |
| tcp-echo-server         | `asm/istio/tcp-echo-server`                  | `1.3`     |

镜像源 registry 由 `global.registry.address` 配置，默认 `build-harbor.alauda.cn`。

## 目录结构

```
mesh-v2-test-suite/
├── Chart.yaml                           Helm chart 元信息
├── README.md                            本文件
├── module-plugin.yaml                   ACP 插件声明（ModulePlugin CR）
├── values.yaml                          镜像清单及全局变量
├── scripts/
│   └── plugin-config.yaml               插件配置（无可调参数的最小版本）
├── files/
│   └── java-otel-demo/                  Java OTel 示例服务的 manifest 源文件（带 Helm 模板语法）
│       ├── java-instrumentation.yaml    OTel javaagent 注入配置
│       ├── java-otel-test-service.yaml  consumer / provider / asm-client 工作负载
│       └── dashboard/                   自定义监控面板源文件（MonitorDashboard，原样嵌入不经 tpl）
│           ├── otel-java-http-monitor-dashboard.yaml   HTTP RED 指标面板
│           ├── otel-java-jvm-monitor-dashboard.yaml    JVM 运行时指标面板
│           ├── acp-opentelemetry-http-grafana.json     HTTP 面板的 Grafana 导出源（参考用，不嵌入）
│           └── acp-opentelemetry-jvm-grafana.json      JVM 面板的 Grafana 导出源（参考用，不嵌入）
└── templates/
    ├── _helpers.tpl                     镜像 helper：imageList（全量清单）+ image（按名取址）
    ├── image-manifest-configmap.yaml    占位 ConfigMap，仅用作插件已安装的标识
    └── java-otel-demo-configmap.yaml    承载 files/java-otel-demo/ 四个 manifest 的 ConfigMap
```

## 如何打包与上架

详细背景请参考在线文档 [plugin-build-guide.md](https://github.com/alauda/cluster-plugin/blob/main/docs/plugin-build-guide.md)。

### 1. 推送 chart 到 OCI 仓库

```bash
helm package mesh-v2-test-suite/
helm registry login build-harbor.alauda.cn
helm push mesh-v2-test-suite-<chart-version>.tgz oci://build-harbor.alauda.cn/asm
```

### 2. 用 violet 打包

#### 流水线打包

详见：https://edge.alauda.cn/console-devops/workspace/asm/ci?buildName=artifacts-plugin&cluster=business-build&namespace=asm-dev

#### 本地打包测试

```bash
violet create mesh-v2-test-suite \
  --artifact build-harbor.alauda.cn/asm/mesh-v2-test-suite:<chart-version> \
  --platforms linux/amd64,linux/arm64 \
  --username <harbor-user> \
  --password <harbor-pass>

violet package mesh-v2-test-suite \
  --username <harbor-user> \
  --password <harbor-pass>
```

执行后在当前目录生成 `mesh-v2-test-suite-<chart-version>.tgz`。

### 3. 上架到 ACP

```bash
violet push mesh-v2-test-suite-<chart-version>.tgz \
  --platform-address https://<acp-host> \
  --platform-username <acp-user> \
  --platform-password <acp-pass>
```

## 安装与卸载

平台管理 → 集群管理 → 选择目标集群 → 插件 → 找到 `Mesh v2 测试套件` → 部署 / 卸载。

## 安装后如何使用镜像

插件安装完成后，9 个镜像已被同步到 ACP 内置镜像仓库。可通过以下方式确认：

```bash
kubectl get configmap mesh-v2-test-suite-manifest -n cpaas-system -o yaml
```

ConfigMap 的 `data` 字段：

- `data.registry`：所有打包镜像统一使用的 ACP 内置镜像仓库地址（由 `scripts/plugin-config.yaml` 的 valuesTemplates 在安装时通过 `<< .RegistryAddress >>` 自动重写为当前集群的内置镜像仓库地址）。
- `data.images`：所有打包镜像的**完整可拉取地址**（含上面的 registry 前缀），可直接在工作负载里引用。

测试自动化（`tests/`）开启 `USE_MESH_V2_TEST_SUITE_PLUGIN=true` 后会读取 `data.registry` 来改写 docker.io / registry.istio.io 镜像，详见 [tests/README.md](../../tests/README.md)。

```yaml
spec:
  containers:
    - name: curl
      image: <acp-registry>/asm/curlimages/curl:8.16.0
```

> 用 `helm template` 在本地渲染时，registry 字段还是 `values.yaml` 默认值 `build-harbor.alauda.cn`（即镜像源地址），属正常现象。该字段只有在 ACP 安装时才会被 valuesTemplates 重写为平台内置 registry。

## 部署 Java OTel 示例服务

除占位 ConfigMap 外，插件还会在 `cpaas-system` 下创建 `mesh-v2-test-suite-java-otel-demo`，承载 Java OTel 示例服务的部署清单：

- `data.description`：本节命令的说明文本。
- `data.java-instrumentation.yaml`：OTel Operator 注入 javaagent 用的 `Instrumentation` 资源。
- `data.java-otel-test-service.yaml`：示例工作负载（`otel-demo-consumer-for-test` / `otel-demo-provider-for-test` / `asm-client`）及对应 Service。其中 `asm-client` 启动后会持续向 consumer 发起两条循环测试请求，自动产生分布式追踪数据。
- `data.otel-java-http-monitor-dashboard.yaml`：HTTP RED 指标的自定义监控面板（`MonitorDashboard`，资源自带 `namespace: cpaas-system`）。
- `data.otel-java-jvm-monitor-dashboard.yaml`：JVM 运行时指标的自定义监控面板（`MonitorDashboard`，资源自带 `namespace: cpaas-system`）。

前置条件：集群已安装 Jaeger v2 与 opentelemetry-operator（追踪数据通过 `http://otel-collector.jaeger-system.svc:4318` 上报）。

一键部署：

```bash
# 1. 创建示例命名空间
kubectl create ns otelv2-java-demo

# 2. 部署 Instrumentation（OTel javaagent 注入配置）
kubectl get cm mesh-v2-test-suite-java-otel-demo -n cpaas-system \
  -o jsonpath='{.data.java-instrumentation\.yaml}' \
  | kubectl apply -n otelv2-java-demo -f -

# 3. 部署示例工作负载
kubectl get cm mesh-v2-test-suite-java-otel-demo -n cpaas-system \
  -o jsonpath='{.data.java-otel-test-service\.yaml}' \
  | kubectl apply -n otelv2-java-demo -f -

# 4. 在 Operations Center / Monitor / Dashboards 中创建自定义监控面板
#    （面板 manifest 自带 namespace: cpaas-system，apply 时无需再指定 -n）
kubectl get cm mesh-v2-test-suite-java-otel-demo -n cpaas-system \
  -o jsonpath='{.data.otel-java-http-monitor-dashboard\.yaml}' \
  | kubectl apply -f -
kubectl get cm mesh-v2-test-suite-java-otel-demo -n cpaas-system \
  -o jsonpath='{.data.otel-java-jvm-monitor-dashboard\.yaml}' \
  | kubectl apply -f -
```

部署完成后即可在 Jaeger UI 上看到 consumer / provider 之间的调用链，并在 Operations Center / Monitor / Dashboards 的 `otel-java` 目录下看到 HTTP、JVM 两个自定义监控面板。

### 修改示例服务清单与监控面板

- 示例服务源文件位于 [`files/java-otel-demo/`](./files/java-otel-demo/)（`java-instrumentation.yaml`、`java-otel-test-service.yaml`），是带 Helm 模板语法的 manifest。
- ConfigMap 模板 [`templates/java-otel-demo-configmap.yaml`](./templates/java-otel-demo-configmap.yaml) 通过 `tpl + .Files.Get` 把上述两个 manifest 渲染后嵌入 `data` 字段；所有镜像引用通过 [`_helpers.tpl`](./templates/_helpers.tpl) 的 `mesh-v2-test-suite.image` helper 从 `values.yaml` 拉取，因此换 registry / 升级镜像版本只需改 `values.yaml`，无需动 manifest 本体。
- 监控面板源文件位于 [`files/java-otel-demo/dashboard/`](./files/java-otel-demo/dashboard/)，以 `.Files.Get` **原样嵌入**（**不经 `tpl`**）：面板的 Grafana `legendFormat` 使用了双花括号 `{{.label}}` 语法，一旦经 `tpl` 渲染会被 Helm 误当作模板求值而损坏。新增 / 修改面板时直接编辑 YAML 即可，切勿引入需要 `tpl` 的 Helm 语法（如镜像 helper）。同目录的 `*-grafana.json` 是面板的 Grafana 导出源，仅作参考、不会被嵌入 ConfigMap。

## 如何新增或更新镜像

1. 编辑 [`values.yaml`](./values.yaml) 的 `global.images`，新增条目或调整 `repository`/`tag`。
2. 按 [如何更新插件版本](#如何更新插件版本) 递增 chart 版本号。
3. 重新执行打包流程（推 chart → violet create / package / push）。

`templates/_helpers.tpl` 中的两个 helper 都从 `values.yaml` 自动取值：

- `mesh-v2-test-suite.imageList`：将所有镜像拼成完整可拉取地址列表，渲染到占位 ConfigMap 的 `images` 字段。
- `mesh-v2-test-suite.image`：按镜像名（即 `global.images` 的 key）拼出单个完整地址，供 `files/java-otel-demo/` 等模板 manifest 引用。新增供示例 manifest 使用的镜像后，直接在 manifest 中写 `{{ include "mesh-v2-test-suite.image" (dict "ctx" . "name" "<image-key>") }}` 即可。

## 如何更新插件版本

chart 版本号同时记录在两个文件中，且必须保持一致：

- [`Chart.yaml`](./Chart.yaml) 的 `version` 字段
- [`module-plugin.yaml`](./module-plugin.yaml) 的 `spec.appReleases[0].chartVersions[0].version` 字段

直接使用 [`hack/update-version.sh`](./hack/update-version.sh) 一次性同步这两处：

```bash
./hack/update-version.sh <NEW_VERSION>
```

示例：

```bash
./hack/update-version.sh v1.0.0-rc.2
./hack/update-version.sh v1.0.0
```

脚本同时兼容 Linux（GNU sed）和 macOS（BSD sed），无需额外安装 `gnu-sed`。执行完成后请用 `git diff` 确认两个文件的 `version` 行都已更新，再继续打包流程。

## 约束

- 所有镜像必须与主 chart 在同一个 registry domain（即 `global.registry.address`）。violet 在打包时会用主 chart 的 OCI artifact 地址作为唯一 domain 拼装镜像 URL（参见 violet 源码 `pkg/artifact/chart/chart.go` 的 `seekImagesFromValues`）。
- `values.yaml` 中 `global.images.<name>.repository` 必须是仓库相对路径，**不能**包含 registry 前缀，否则会被拼成错误的双域名地址。
