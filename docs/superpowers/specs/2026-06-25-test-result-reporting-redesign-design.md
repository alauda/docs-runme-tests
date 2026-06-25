# 文档自动化测试「结果统计」完全重构 — 设计文档

- 日期：2026-06-25
- 状态：已批准（待 writing-plans）
- 范围：`docs-runme-tests` 框架的测试结果统计、汇总与报告子系统
- 类型：完全重构（抛弃旧设计，重新设计）

---

## 1. 背景与动机

### 1.1 旧设计

旧的「测试结果统计」集中在 `framework/common.sh:103-140`，仅由 3 个全局变量 + 2 个函数构成：

- 全局计数器：`TESTS_TOTAL` / `TESTS_PASSED` / `TESTS_FAILED`
- `record_test_result 0|1`：累加计数
- `print_test_summary`：打印「总计 / 通过 / 失败」三行

它被两层同时使用，但两层互不相通：

| 层 | 调用点 | 统计单位 |
| --- | --- | --- |
| 引擎层 `run.sh` | 每个 `run_test_script` 后 | 1 个测试脚本 |
| 编排层 `run-*-all.sh` | 每个 Case 子 shell 后 | 1 个 Case（含 10+ 个 `./run.sh`）|

### 1.2 旧设计的缺陷（本次重构要全部解决）

1. **粒度 / 语义混乱**：编排层「总计 11」指 11 个 Case，但单个 Case（如 mesh Case 3）内含 20+ 个文档测试；两层用同一套措辞却是不同单位。引擎层与编排层两套计数器互不相通——子 shell 内 `run.sh` 的计数无法回传父进程。
2. **fail-fast 丢全局**：每个 Case 失败即 `exit 1`，配合 `trap ... EXIT` 终止全脚本，永远只看到「第一个失败」，无法得到一次运行的完整全貌。
3. **失败不定位**：只有数字，不指明是哪个 Case / 哪篇文档 / 哪一步失败，排查必须翻全部日志。
4. **无 SKIPPED 第三态**：编排层大量条件跳过（双栈、多集群、OpenSearch、Java demo）完全不计数；文档脚本内部的「SKIPPED」是伪装的 PASS（`log_warn "SKIPPED"` + `return 0`），信息丢失。
5. **无耗时**：测试动辄数十分钟，却无任何时间记录。
6. **无结构化 / 持久化输出**：纯彩色 echo，无 JSON / JUnit，无法对接 CI、无法留存历史报告。
7. **退出码形同虚设**：`print_test_summary` 经 `trap EXIT` 调用，其 return 值不影响脚本退出码，实际靠各 Case 的 `exit 1` 兜底。

### 1.3 现状事实（调研结论）

- 共 **36 个** `runme-test_*.sh` 脚本：30 个 mesh（`servicemesh2-docs`）、3 个 otel（`opentelemetry-docs`）、3 个 tracing（`distributed-tracing-docs`）。
- 文档测试脚本本身只 `return 0/1`，**不直接调用统计函数**——统计由引擎 `run.sh` 包裹捕获。这意味着绝大多数脚本无需改动。
- 现有「伪 SKIPPED」脚本约 5 个：`java-instrumentation`、`installing-distributed-tracing-opensearch`、`installing-distributed-tracing-elasticsearch`、`uninstalling-distributed-tracing` 等，用 `log_warn "SKIPPED: ..."` + `return 0` 表达跳过。
- 仓库**无任何 CI 配置**（无 `.gitlab-ci.yml` / `.github/workflows` / `Jenkinsfile`）。JUnit XML 是为未来对接准备，按标准 schema 产出即可对接任意 CI。
- `tmp/` 已在 `.gitignore`，适合放运行产物。
- `jq` 已是框架既有依赖（`common.sh` 多处使用）。

---

## 2. 设计目标与决策

| 维度 | 决策 |
| --- | --- |
| 统计模型 | 三层：**Run → Case → DocTest** |
| 失败策略 | 跑完全部再汇总；**致命前置中止，普通 Case 继续**；Case 内部保持原子（任一步失败该 Case 即 FAIL）|
| 输出形式 | 美化终端摘要 + `summary.json` + `junit.xml` |
| 信息维度 | 状态三态（passed / failed / **skipped**）、**耗时**、失败与跳过**定位到具体文档与 Case** |
| 产物保留 | `tmp/runs/<run-id>/` 按时间戳分目录保留历史 + `tmp/runs/latest` 软链指向最近一次 |

### 2.1 术语与三层模型

- **Run（运行）**：一次 `run-<project>-all.sh` 的完整执行，或一次独立的 `./run.sh --file ...` 调用。
- **Case（用例组）**：编排脚本中的一个 `log_header "Case N"` + 子 shell，内含一个或多个 `./run.sh` 调用。是「原子单元」——内部任一步失败则整个 Case 判 FAIL。
- **DocTest（文档测试）**：一次 `./run.sh --file <doc>` 的执行，对应一篇 MDX 文档的 `runme-test_<doc>.sh`。是最细的统计粒度。

---

## 3. 核心架构决策：跨进程三层统计

### 3.1 根本难点

进程层级如下，DocTest 结果产生在 `./run.sh` **子进程**内，却要在 `run-*-all.sh` **父进程**汇总。内存变量无法跨进程回传——这正是旧设计的死穴。

```
run-mesh-all.sh        （父进程，一次 Run）
  └─ ( ... )           （子 shell，一个 Case）
       └─ ./run.sh     （子进程，引擎，一个 DocTest）
            └─ test_<feature>()   （实际测试函数）
```

### 3.2 方案对比

| 方案 | 机制 | 评价 |
| --- | --- | --- |
| **A 文件 Sink（选定）** | 引擎每跑完一个 `--file` 追加一行 JSON 到 `results.jsonl`；父进程末尾用 `jq` 聚合 | ✅ 进程天然解耦、可持久化、JSON/JUnit 同源派生、`jq` 已是依赖 |
| B 结构化 stdout | 引擎把结果打到 stdout，父进程解析捕获 | ❌ 与日志混杂、解析脆弱、子 shell 管道易丢 |
| C 命名管道 / 导出变量 | FIFO 或 `export` 回传 | ❌ 子进程无法写父进程变量；FIFO 在串行编排里过度设计 |

**选定方案 A**：唯一数据源 `results.jsonl`（JSON Lines），终端摘要 / `summary.json` / `junit.xml` 三种输出全部由它派生，干净且可追溯。串行执行下追加写无并发竞争。

### 3.3 数据流

```
run-mesh-all.sh (一次 Run)
│  report_init mesh
│    → 生成 run-id（date +%Y%m%d-%H%M%S）
│    → 建 tmp/runs/<run-id>/，更新 tmp/runs/latest 软链
│    → export RUNME_TEST_RUN_DIR、RUNME_TEST_ORCHESTRATED=1
│  trap report_finalize EXIT
│
├─ case_begin "1" "环境初始化"     → export RUNME_TEST_CASE_ID/NAME，log_header
│  ( ./run.sh --init-only )         → 引擎写 1 行 doctest 记录
│  case_end_fatal $?                → 失败：report_finalize + exit（致命前置）
│
├─ case_begin "3" "单网格安装与应用"
│  ( ./run.sh --file install-mesh; ./run.sh --file kiali; ... )
│                                    → 每个 --file 各写 1 行 doctest 记录
│  case_end $?                       → 写 1 行 case 记录；普通 Case 失败仅记录、继续
│
└─ case_skip "2" "双栈安装" "IS_DUAL_STACK!=true"
                                     → 写 1 行 case_skip 记录
   ...
   report_finalize（trap 触发）
     → jq 聚合 results.jsonl
     → 终端摘要 + summary.json + junit.xml
     → 退出码：有 failed → 1，否则 0
```

---

## 4. 数据模型：`results.jsonl`

每行一条 JSON 记录，`type` 区分三类。所有时间戳为 Unix 秒（`date +%s`）。

```jsonc
// type=doctest：一次 ./run.sh --file 的结果（引擎 run.sh 写）
{
  "type": "doctest",
  "project": "mesh",
  "file": "kiali",
  "script": "runme-test_kiali.sh",
  "case_id": "3",                 // 取自 RUNME_TEST_CASE_ID，单跑模式为 ""
  "case_name": "单网格安装与应用", // 取自 RUNME_TEST_CASE_NAME
  "phase": "test",                // test | cleanup-only | init-only
  "status": "failed",             // passed | failed | skipped
  "skip_reason": "",              // status=skipped 时填
  "fail_reason": "step 7: kiali pod 未就绪", // status=failed 时填
  "start_ts": 1750000000,
  "end_ts": 1750000510,
  "duration_s": 510
}

// type=case：Case 级汇总（case_end / case_end_fatal 写）
// 覆盖 init-only 这类无 --file、不产生 doctest 记录的 Case
{
  "type": "case",
  "case_id": "1",
  "case_name": "环境初始化",
  "status": "passed",             // passed | failed
  "duration_s": 130
}

// type=case_skip：条件跳过的整个 Case（case_skip 写）
{
  "type": "case_skip",
  "case_id": "2",
  "case_name": "双栈网格安装",
  "skip_reason": "IS_DUAL_STACK != true"
}
```

### 4.1 聚合规则（report_finalize 内 jq 实现）

- **Case 列表与顺序**：取所有 `type=case` 与 `type=case_skip` 记录，按写入顺序（`results.jsonl` 行序）展示。
- **Case 明细**：同 `case_id` 的 `type=doctest` 记录构成该 Case 的文档测试明细。
- **Case 状态**：优先取 `type=case` 记录的 `status`；缺失时由其下 doctest 聚合（任一 failed → Case failed；否则 passed）；`case_skip` 为 skipped。
- **Run 级计数**：同时输出两套维度——
  - Case 维度：Case 总数 / passed / failed / skipped
  - DocTest 维度：DocTest 总数 / passed / failed / skipped
- **总耗时**：全局 `max(end_ts) - min(start_ts)`，或各 Case `duration_s` 之和（取前者，更贴近墙钟）。
- **退出码**：DocTest 维度或 Case 维度存在 failed → `1`，否则 `0`（skipped 不算失败）。

---

## 5. 模块划分

遵循单一职责，重构涉及以下单元：

| 单元 | 改动 | 职责 |
| --- | --- | --- |
| **`framework/report.sh`** 🆕 | 新建 | 统计与报告核心，对外接口见 §6 |
| `framework/common.sh` | 删旧增新 | 移除 `record_test_result` / `print_test_summary` / `TESTS_*`（约 38 行）；新增 `skip_test "reason"` |
| `run.sh` | 改 `run_test_script` 与 `main` | 计时、捕获三态、写 doctest 记录；区分编排 / 单跑模式；移除内置 summary 噪音 |
| `run-{mesh,otel,tracing}-all.sh` ×3 | 改控制流 | `record_test_result` + 手动 `exit` → `case_begin` / `case_end` / `case_end_fatal` / `case_skip` |
| 文档测试脚本 ×约 5 | 小改 | `log_warn "SKIPPED"; return 0` → `skip_test "reason"`（其余 30+ 个零改动）|
| `README.md` | 改 | 更新「测试结果统计」章节 |

> 注：文档测试脚本分散在 `servicemesh2-docs` / `opentelemetry-docs` / `distributed-tracing-docs` 三个独立仓库。本设计刻意让普通脚本零改动，仅约 5 个带 skip 逻辑的脚本需小改，以控制跨仓库改动面。

---

## 6. `framework/report.sh` 接口设计

```bash
# ── Run 生命周期 ───────────────────────────────────────────────
# 生成 run-id、建 tmp/runs/<run-id>/、更新 latest 软链、
# export RUNME_TEST_RUN_DIR 与 RUNME_TEST_ORCHESTRATED=1、写空 results.jsonl
report_init <project>

# 读取 $RUNME_TEST_RUN_DIR/results.jsonl，jq 聚合，产出：
#   - 终端摘要（stdout）
#   - $RUNME_TEST_RUN_DIR/summary.json
#   - $RUNME_TEST_RUN_DIR/junit.xml
# 返回：有 failed → 1，否则 0
report_finalize

# ── 引擎层（run.sh 调用）────────────────────────────────────────
# 追加一行 type=doctest 记录到 results.jsonl
report_record_doctest <project> <file> <script> <phase> <status> \
                      <skip_reason> <fail_reason> <start_ts> <end_ts>

# ── 编排层（run-*-all.sh 调用）─────────────────────────────────
# 设置 Case 上下文：export RUNME_TEST_CASE_ID/NAME，记录起始时间，log_header
case_begin <case_id> <case_name>

# 写 type=case 记录（status 由 rc 推断：0=passed，非0=failed）+ duration
# 普通 Case：rc≠0 时 log_error，但不中断 Run
case_end <rc>

# 同 case_end，但 rc≠0 时调用 report_finalize 后 exit 1（致命前置 Case 用）
case_end_fatal <rc>

# 写 type=case_skip 记录（条件跳过的整个 Case）
case_skip <case_id> <case_name> <reason>
```

### 6.1 健壮性约定

- `report_finalize` 经 `trap ... EXIT` 注册，确保中途 `case_end_fatal` 退出时也能产出报告。
- `results.jsonl` 为空（未跑任何测试）时，输出友好提示而非报错。
- `report_init` 的 run-id 用 `date +%Y%m%d-%H%M%S`；若同秒冲突（极少），追加 `$$` 或自增后缀。
- `latest` 软链用 `ln -sfn` 原子替换。

---

## 7. `run.sh` 引擎层改造

### 7.1 `run_test_script` 改造要点

```bash
run_test_script() {
    local test_script="$1"
    local start_ts end_ts status="passed" skip_reason="" fail_reason=""
    start_ts=$(date +%s)

    # ...（原有 source 脚本、查找 test_/cleanup_ 函数逻辑不变）...

    # 执行测试函数，捕获三态
    if $test_func; then
        if [ "${__TEST_SKIPPED:-0}" = "1" ]; then
            status="skipped"; skip_reason="$__TEST_SKIP_REASON"
        else
            status="passed"
        fi
    else
        status="failed"; fail_reason="$(__last_error_or_default)"
    fi

    end_ts=$(date +%s)
    report_record_doctest "$PROJECT" "$file" "$script_name" "$phase" \
        "$status" "$skip_reason" "$fail_reason" "$start_ts" "$end_ts"
}
```

- `skip_test`（在 common.sh）设置 `__TEST_SKIPPED=1` 与 `__TEST_SKIP_REASON`，并 `return 0`；引擎据此判定 skipped。每次执行前需重置这两个变量。
- `fail_reason` 来源：优先捕获测试函数最后一条 `log_error` 文本（在 `log_error` 内记录到全局 `__LAST_ERROR`），缺省回退为「测试函数返回非 0」。
- `cleanup-only` 阶段经 `run_test_script` 执行（其 `CLEANUP_ONLY` 分支），照常写 doctest 记录（`phase=cleanup-only`）。`init-only` 不经 `run_test_script`（`main` 内直接处理并 exit），不产生 doctest 记录——其 Case 级状态由 `case_end_fatal` 写的 `type=case` 记录提供（见 §4）。

### 7.2 编排 / 单跑模式区分

- `report_init` 设置 `RUNME_TEST_ORCHESTRATED=1`；`run.sh` 检测该变量：
  - **编排模式**（由 `run-*-all.sh` 设置）：只写 doctest 记录，**不** finalize（交给父进程）。
  - **单跑模式**（直接 `./run.sh --file x`）：引擎自行 `report_init`（建临时 run 目录）+ 跑 + `report_finalize`，产出一致报告。无显式 Case，doctest 记录 `case_id=""`，聚合时归入一个名为「（无 Case）」的隐式分组。
- 移除 `run.sh:465` 的 `print_test_summary` 调用与内嵌计数，消除「总计:1」噪音。

---

## 8. 编排脚本（`run-*-all.sh`）改造模式

与现状几乎一对一同构，迁移风险低：

```bash
# ── 顶部 ──
source "$SCRIPT_DIR/framework/report.sh"
report_init mesh
trap report_finalize EXIT

# ── 致命前置 Case ──
case_begin "1" "环境初始化（默认 SINGLE_CLUSTER_NAME）"
if ( set -e; ./run.sh --project mesh --init-only ); then
    case_end 0
else
    case_end_fatal 1            # → report_finalize + exit 1
fi

# ── 普通 Case（失败不退出，继续后续）──
case_begin "3" "单网格安装与应用"
if (
    set -e
    ./run.sh --project mesh --file install-mesh
    ./run.sh --project mesh --file kiali
    # ...
); then
    case_end 0
else
    case_end 1                  # 仅记录，Run 继续
fi

# ── 条件跳过 ──
if [ "$IS_DUAL_STACK" == "true" ]; then
    case_begin "2" "双栈网格安装"
    if ( set -e; ... ); then case_end 0; else case_end 1; fi
else
    case_skip "2" "双栈网格安装" "IS_DUAL_STACK != true"
fi
```

对照旧的 `log_header + if(...) record_test_result 0/1 + exit 1`，逐项替换即可。

### 8.1 `set -e` 处理

编排脚本顶层保留 `set -e` 捕捉脚本自身 bug，但每个 Case 用 `if (...); then ...; else ...; fi` 包裹——`if` 条件中的子 shell 失败不会触发顶层 `set -e`，从而实现「普通 Case 失败继续」。

### 8.2 失败继续与脏环境

- **致命前置**（环境初始化 / `--init-only`）失败 → `case_end_fatal` 中止整个 Run（后续无意义）。
- **普通 Case** 失败 → 记录后继续下一个 Case。多数 Case 已用 `--force-init` 开头，会自我重置环境，降低脏环境对后续 Case 的连环影响。
- 失败 Case 的残留资源在「跑完全部」模式下为已知权衡：报告会如实标注失败，后续 Case 若因脏环境失败也会各自记录，便于人工判读。

---

## 9. SKIPPED 双来源统一

| 来源 | 旧行为 | 新行为 |
| --- | --- | --- |
| 文档脚本内部条件不满足 | `log_warn "SKIPPED"` + `return 0`（伪 PASS）| 调 `skip_test "reason"` → 引擎记 `status=skipped` |
| 编排层条件跳过（双栈 / 多集群 / opensearch）| 仅 `log_header` 一句话，不计数 | 调 `case_skip` → 进入统计与报告 |

`skip_test` 实现（`common.sh`）：

```bash
skip_test() {
    __TEST_SKIPPED=1
    __TEST_SKIP_REASON="$1"
    log_warn "SKIPPED: $1"
    return 0
}
```

需小改的约 5 个脚本：把 `log_warn "SKIPPED: ..."; return 0` 整体替换为 `skip_test "..."`。

---

## 10. 输出格式

### 10.1 终端摘要（ASCII，直出）

```
════════════════════════════════════════════════════════════════
  测试运行汇总   run-id: 20260625-143022   项目: mesh
════════════════════════════════════════════════════════════════
  总耗时 42m18s
  Case      11   ✓ 8   ✗ 2   ⊘ 1
  文档测试  47   ✓ 38  ✗ 2   ⊘ 7
────────────────────────────────────────────────────────────────
  Case                              ✓   ✗   ⊘    耗时
  ①  环境初始化                      1   ·   ·    2m10s
  ②  双栈网格安装                    ·   ·   1    —     ⊘ IS_DUAL_STACK!=true
  ③  单网格安装与应用                18  1   ·    15m12s
  ⑧  InPlace 更新                    ·   1   ·    12m03s
  …
────────────────────────────────────────────────────────────────
  ✗ 失败明细
    [Case3] mesh/kiali            510s   step 7: kiali pod 未就绪
    [Case8] mesh/update-inplace   723s   step 12: istiod 版本不匹配
  ⊘ 跳过明细
    [Case2] 双栈网格安装                  IS_DUAL_STACK != true   （case_skip：整个 Case 跳过）
    [Case3] tracing/installing-distributed-tracing-elasticsearch  未配置 ES 端点   （skip_test：跨项目复用的 DocTest 跳过）
════════════════════════════════════════════════════════════════
  结果: 失败 (2/47 文档测试)    报告: tmp/runs/20260625-143022/
════════════════════════════════════════════════════════════════
```

### 10.2 `summary.json`（三层结构化）

```jsonc
{
  "run_id": "20260625-143022",
  "project": "mesh",
  "started_at": 1750000000,
  "duration_s": 2538,
  "totals": {
    "cases":    { "total": 11, "passed": 8,  "failed": 2, "skipped": 1 },
    "doctests": { "total": 47, "passed": 38, "failed": 2, "skipped": 7 }
  },
  "result": "failed",
  "cases": [
    {
      "case_id": "3", "case_name": "单网格安装与应用",
      "status": "failed", "duration_s": 912,
      "doctests": [
        { "file": "install-mesh", "status": "passed", "duration_s": 180 },
        { "file": "kiali", "status": "failed", "duration_s": 510,
          "fail_reason": "step 7: kiali pod 未就绪" }
      ]
    }
  ]
}
```

### 10.3 `junit.xml`（三层 → 标准两层半映射）

```xml
<testsuites name="mesh" tests="47" failures="2" skipped="7" time="2538">
  <testsuite name="Case 3: 单网格安装与应用" tests="20" failures="1" time="912">
    <testcase name="mesh/install-mesh" classname="Case3" time="180"/>
    <testcase name="mesh/kiali" classname="Case3" time="510">
      <failure message="step 7: kiali pod 未就绪"/>
    </testcase>
  </testsuite>
  <testsuite name="Case 2: 双栈网格安装" tests="1" skipped="1">
    <testcase name="双栈网格安装" classname="Case2">
      <skipped message="IS_DUAL_STACK != true"/>
    </testcase>
  </testsuite>
</testsuites>
```

- 映射：`<testsuites>` = Run；`<testsuite>` = Case；`<testcase>` = DocTest。
- XML 特殊字符（`<>&"'`）需转义。

---

## 11. 产物布局

```
tmp/runs/
├── 20260625-143022/          # 一次 Run，按时间戳分目录（保留历史）
│   ├── results.jsonl         # 唯一数据源（JSON Lines）
│   ├── summary.json          # 三层结构化汇总
│   └── junit.xml             # 标准 JUnit
├── 20260625-181530/
│   └── ...
└── latest -> 20260625-181530 # 软链指向最近一次（ln -sfn）
```

全部位于 `tmp/`，已被 `.gitignore` 忽略。可用 `--report-dir <path>` 覆盖默认位置（可选增强，非必须）。

---

## 12. 测试策略

这是 bash 框架，核心可测逻辑是 `report.sh` 的**聚合与渲染**，不依赖真实集群：

1. **TDD（report.sh 单元测试）**：构造样本 `results.jsonl`（覆盖 passed / failed / skipped / case_skip、init-only Case、空文件等组合），断言：
   - `summary.json` 关键字段（两套计数、result、cases 结构）
   - `junit.xml` 结构（tests/failures/skipped 属性、failure/skipped 元素、字符转义）
   - 终端摘要的计数行
   - `report_finalize` 退出码（有 failed→1，全 passed/skipped→0，空→0 且友好提示）
2. **冒烟**：`./run.sh --file <轻量文档>` 单跑一次，验证单跑模式端到端产出报告。
3. **真跑** `run-*-all.sh`（需集群、数十分钟）不在重构验证范围，留待真实环境验收。

测试放置：新增 `framework/tests/report_test.sh`（或沿用项目既有测试约定），可独立运行、无副作用。

---

## 13. 改造范围与迁移成本

| 改动项 | 数量 | 风险 |
| --- | --- | --- |
| 新增 `framework/report.sh` | 1 | 低（新文件，含单元测试）|
| 改 `framework/common.sh` | 1 | 低（删旧三件套、加 `skip_test`，其余不动）|
| 改 `run.sh` | 1 | 中（`run_test_script` 与 `main` 改造，需保模式区分正确）|
| 改 `run-*-all.sh` | 3 | 低（一对一替换，结构同构）|
| 改文档测试脚本（skip 逻辑）| ~5 | 低（局部替换，跨 3 仓库）|
| 改 `README.md` | 1 | 低 |

普通文档测试脚本（30+ 个）**零改动**。

---

## 14. 已定夺的实现细节

1. 进程间通信用**文件 Sink（JSON Lines）+ jq 聚合**。
2. DocTest 命名用 `项目/文档名`（如 `mesh/kiali`）。
3. Run 级**同时报 Case 与 DocTest 两套计数**。
4. 单跑 `./run.sh --file` 也产出一致的三层报告（隐式单 Case / 空 case_id）。
5. run-id 格式 `date +%Y%m%d-%H%M%S`；产物按 run-id 分目录 + `latest` 软链。

---

## 15. 风险与权衡

- **「跑完全部」的脏环境**：失败 Case 可能留下残留资源，致后续 Case 误失败。缓解：致命前置中止 + 多数 Case `--force-init` 自重置；报告如实标注，交人工判读。可接受。
- **fail_reason 精度**：依赖捕获最后一条 `log_error`，可能不总是最贴切的根因。作为首版可接受，后续可增强（如捕获测试函数返回前的上下文）。
- **JSON Lines 并发写**：当前编排为串行执行，无并发写竞争。若未来并行化，需改为带锁或每 DocTest 独立文件后合并。当前不处理（YAGNI）。

---

## 16. 后续步骤

本设计批准后，进入 `writing-plans` 产出分阶段实现计划（建议顺序：report.sh + 单元测试 → common.sh → run.sh → 编排脚本 → skip 脚本 → README），再按计划实施。
