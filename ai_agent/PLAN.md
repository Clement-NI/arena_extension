# Arena AI Agent 研究项目计划书

> **目标**：在 Arena 测试床之上构建一个完整的 AI 工作流，把"应用拓扑设计 → 网络模拟 → 部署 → 评估"全流程自动化。
>
> **关联论文**：Huang et al., *"Arena: A Kubernetes-based Testbed for Evaluating Application Deployment across the Computing Continuum"*, IEEE ICC 2026.
>
> **本计划响应论文 §V 提出的未来工作方向**：*"develop a topology-aware network modeling framework that allows users to specify application-level topologies so that Arena can automatically configure network characteristics."*

---

## 1. 整体工作流

```
   用户人话                                                    论文/数据
   "我要测视频流应用..."                                          ↑
        │                                                       │
        ▼                                                       │
  ┌──────────────────┐                                   ┌─────────────┐
  │ 任务 A           │                                   │ 任务 E      │
  │ 自然语言理解     │                                   │ 评估与可视化│
  │ (LLM)            │                                   └─────▲───────┘
  └────────┬─────────┘                                         │
           │                                              CSV / 图表
           ▼                                                   │
   topology.yaml  ◄── 标准 schema (中间接口)             ┌─────┴───────┐
           │                                              │ Prometheus  │
           ▼                                              │ 数据收集    │
  ┌──────────────────┐                                   └─────▲───────┘
  │ 任务 B           │                                         │
  │ YAML 翻译        │                                         │
  │ (确定性代码)     │                                         │
  └────────┬─────────┘                                         │
           │                                                   │
           ▼                                                   │
   K8s + ChaosMesh YAML                                        │
           │                                                   │
           ▼                                                   │
  ┌──────────────────┐         ┌──────────────────┐    ┌─────┴───────┐
  │ 任务 C           │────────►│ 任务 D           │───►│ Arena 集群  │
  │ 多层验证         │  pass   │ 部署到集群       │    │ 运行实验    │
  └──────────────────┘         └──────────────────┘    └─────────────┘
           │
        fail → 回到任务 A 自我修正（最多 3 轮）
```

**核心设计**：LLM 只做它擅长的（理解+结构化），代码做它擅长的（精确生成+验证）。两者用 `topology.yaml` 这个中间格式解耦。

---

## 2. 工作流五个任务

| 任务 | 名称 | 实现方式 | 输入 | 输出 |
|---|---|---|---|---|
| **A** | 自然语言理解 | LLM (Claude) | 用户人话 | `topology.yaml` |
| **B** | YAML 翻译 | Python + Jinja2 | `topology.yaml` + `network_profiles.yaml` | K8s Deployment + Service + NetworkChaos YAML |
| **C** | 多层验证 | JSON Schema + kubectl dry-run + 资源核算 | 生成的 YAML | 验证报告（pass/fail + 详细问题）|
| **D** | 部署 | `kubernetes` Python client | 验证通过的 YAML | 集群运行状态 + 健康检查报告 |
| **E** | 评估与可视化 | Python + matplotlib | Prometheus CSV | 对比图、统计报告 |

**任务 A** 是 LLM 驱动的；**B/C/D/E** 都是确定性代码。

---

## 3. 关键中间产物：`topology.yaml`

这是整个工作流的**核心契约**，定好了 A 和 B 之间的接口。

```yaml
nodes:                              # 应用拓扑节点
  - name: camera
    placement: IoT                  # 对应 Arena 的节点 label
    image: camera-mock:latest
    replicas: 3
    resources:
      cpu: "200m"
      memory: "256Mi"

  - name: transcoder
    placement: Edge
    image: my-transcoder:latest

  - name: storage
    placement: Cloud
    image: minio/minio:latest

links:                              # 应用间链路
  - from: camera
    to: transcoder
    network: 4G_suburban            # 引用预定义网络场景

  - from: transcoder
    to: storage
    network: fiber_datacenter
```

配套的 `network_profiles.yaml`（预定义场景库）：

```yaml
4G_suburban:    { latency: "40ms", jitter: "10ms", bandwidth: "20mbps", loss: "0.5%" }
5G_urban:       { latency: "10ms", jitter: "2ms",  bandwidth: "200mbps", loss: "0.1%" }
wifi_indoor:    { latency: "5ms",                  bandwidth: "100mbps", loss: "0.3%" }
fiber_datacenter: { latency: "1ms",                bandwidth: "10gbps",  loss: "0%" }
satellite:      { latency: "600ms",                bandwidth: "5mbps",   loss: "2%" }
lossy_wireless: { latency: "20ms",                 bandwidth: "10mbps",  loss: "5%" }
```

---

## 4. 项目目录结构

```
ai_agent/
├── PLAN.md                       # 本文件
├── README.md
├── requirements.txt
├── schemas/                      # 任务 A & C 共用
│   ├── topology_schema.json
│   └── profile_schema.json
├── profiles/
│   └── network_profiles.yaml     # 网络场景库
├── nl_understanding/             # 任务 A
│   ├── prompts/
│   │   ├── system_prompt.md
│   │   ├── examples.md
│   │   └── network_knowledge.md
│   ├── llm_client.py
│   ├── tools.py                  # 给 LLM 用的 tools
│   └── chat.py                   # 多轮对话
├── yaml_translator/              # 任务 B
│   ├── templates/                # Jinja2
│   │   ├── deployment.yaml.j2
│   │   ├── service.yaml.j2
│   │   ├── chaos_delay.yaml.j2
│   │   ├── chaos_bandwidth.yaml.j2
│   │   └── chaos_loss.yaml.j2
│   └── generator.py
├── validator/                    # 任务 C
│   ├── schema_validator.py
│   ├── resource_validator.py
│   └── dry_run_validator.py
├── deployer/                     # 任务 D
│   ├── deploy.py
│   ├── health_check.py
│   └── cleanup.py
├── evaluator/                    # 任务 E
│   ├── prometheus_client.py
│   ├── analyzer.py
│   └── plot.py
├── scenarios/                    # 评估用的 10 个场景
│   ├── smart_city.txt
│   ├── industrial_iot.txt
│   └── ...
└── main.py                       # 串起整个工作流
```

---

## 5. 时间表（8 周，分 3 个阶段）

### 阶段 1：搭骨架（Week 1-4）

**先做 B/C/D/E，不做 A**。理由：先有确定性的底座，才能验证后面 LLM 生成的东西对不对。

#### Week 1 — 任务 B（翻译器）

- [ ] D1-2：定义 `topology.yaml` JSON Schema
- [ ] D2-3：定义 `network_profiles.yaml`（6-8 个场景）
- [ ] D3-5：写 Jinja2 模板（deployment / service / chaos × 3）
- [ ] D5-7：写 `generator.py`，能输入 `topology.yaml` 出 YAML

> **交付**：`python generator.py topology.yaml` → `output/*.yaml`

#### Week 2 — 任务 C（验证器）

- [ ] D1-2：Schema 验证（`jsonschema`）
- [ ] D2-4：资源验证（算 CPU/内存总和 vs `nodes.json`）
- [ ] D4-5：Dry-run 验证（`kubectl apply --dry-run=server`）
- [ ] D5-7：拓扑闭环验证（link 引用的节点/profile 是否存在）

> **交付**：`validation_report.json`，列 error/warning/info

#### Week 3 — 任务 D（部署器）

- [ ] D1-3：`deploy.py` — `kubectl apply` + 等 pod Ready
- [ ] D3-4：`cleanup.py` — 一键清理
- [ ] D4-5：超时/重试逻辑
- [ ] D5-7：健康检查 — 每对 link 实测延迟丢包

> **交付**：`./run.sh topology.yaml` → 部署完成 + 自检报告

#### Week 4 — 任务 E（评估器）+ **里程碑 1：复现论文实验 2**

- [ ] D1-2：`prometheus_client.py` — 拉 Prometheus 数据
- [ ] D2-3：`analyzer.py` — CSV 处理 + 统计
- [ ] D3-5：把论文实验 2（IoT→Kafka→Logstash→ES + 限速）改写成 `topology.yaml`
- [ ] D5-7：跑 5 个限速档（无限/10/5/2/1 Mbps），对比论文 Figure 5

> **🎯 里程碑 1**：复现论文 Figure 5 的数据（5.7→11.3→27.7→41.7→41.9 docs/s），误差 < 10%
> **意义**：证明 B/C/D/E 整条流水线正确

---

### 阶段 2：加 LLM 前端（Week 5-7）

#### Week 5 — 任务 A 基础（prompt 工程）

- [ ] D1-2：写 `system_prompt.md`（schema + 可用 profile + placement 规则）
- [ ] D3-4：准备 5-10 个 few-shot 例子
- [ ] D5-7：写 `llm_client.py`，调 Claude API，开 prompt caching

> **交付**：单次调用 — 人话 → topology.yaml 字符串

#### Week 6 — 任务 A 进阶（tool use + 自修正）

- [ ] D1-2：tool — `get_arena_resources()` 调 `kubectl get nodes`
- [ ] D2-3：tool — `list_profiles()` / `validate_topology()`（调任务 C）
- [ ] D3-5：接入 Claude tool use API
- [ ] D5-7：**自循环修正**：生成 → 验证失败 → 拿错误信息重新生成（最多 3 轮）

> **交付**：Agent 能自我修正

#### Week 7 — 任务 A 完善（多轮对话）

- [ ] D1-3：`chat.py` — REPL 模式
- [ ] D3-5：支持改主意（"把网络换成卫星"）
- [ ] D5-7：澄清提问（信息不够时主动问）

> **交付**：交互式对话界面

---

### 阶段 3：评估（Week 8）

#### Week 8 — **里程碑 2：10 场景评估 + 论文草稿**

- [ ] D1-2：设计 10 个真实场景的人话 prompt
  - 智慧城市 / 工业 IoT / 农业监测 / 智能家居 / 车联网 / 医疗远程 / 视频流 / 边缘 AI / 实时分析 / 内容分发
- [ ] D3-5：跑端到端，测：
  - Schema 通过率
  - 端到端部署成功率
  - 自修正轮数分布
- [ ] D5-6：找 3-5 个 K8s 熟人给生成的拓扑打分（1-5）
- [ ] D6-7：写 1-2 页 short paper 草稿

> **🎯 里程碑 2**：完整 demo + 评估数据 + 论文素材

---

## 6. 评估指标全表

| 指标 | 测量阶段 | 测量方法 | 目标 |
|---|---|---|---|
| **Schema 通过率** | 任务 A | 生成的 YAML 一次性通过 schema 校验比例 | > 80% |
| **端到端成功率** | A→B→C→D | 完整流水线最终部署成功的比例 | > 70% |
| **自修正轮数** | 任务 A 内循环 | 平均需要几轮 LLM 才能产出可用 YAML | 平均 < 1.5 |
| **网络保真度** | 任务 D 健康检查 | 实测延迟/带宽 vs profile 声明值的误差 | < 15% |
| **论文复现误差** | 里程碑 1 | 复现的 Figure 5 数据 vs 论文原值的差异 | < 10% |
| **拓扑合理性** | 里程碑 2 | 专家 1-5 分人工评分 | 平均 > 3.5 |

---

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| LLM 生成字段名错（"latency" 写成 "delay_ms"）| 任务 A 失败 | Tool use 强制结构化输出 + 自修正循环 |
| ChaosMesh 多规则叠加效果不确定 | 任务 D 保真度差 | 任务 D 加健康检查实测验证 |
| 资源不够导致 pod Pending | 任务 D 失败 | 任务 C 提前算总和并报错 |
| 沙箱 cgroup 限制（已发现）| 无法本地跑 Arena | 真机/云 VM 上跑 |
| Claude API 成本 | 预算超支 | 开 prompt caching（~90% 省 token）|
| 用户描述模糊 | 任务 A 瞎猜 | 加澄清提问机制 |

---

## 8. 技术栈

| 用途 | 选型 |
|---|---|
| 主语言 | Python 3.10+ |
| LLM | Claude Sonnet 4.6（`claude-sonnet-4-6`），开 prompt caching |
| 模板引擎 | Jinja2 |
| Schema 校验 | jsonschema |
| K8s 客户端 | `kubernetes` Python client + `kubectl` |
| 监控数据 | Prometheus HTTP API |
| 可视化 | matplotlib / seaborn |
| 测试 | pytest |

---

## 9. 8 周后交付物清单

- [ ] 完整 Github 仓库（`ai_agent/` 全部 5 个任务模块）
- [ ] README + demo 录屏
- [ ] **复现论文实验 2 的对比图**（里程碑 1）
- [ ] **10 场景评估表**（里程碑 2）
- [ ] 1-2 页 short paper 草稿（投 workshop 或扩为 full paper）

---

## 10. 论文贡献声明（draft）

> 本工作扩展 Arena 测试床，引入 LLM 驱动的端到端拓扑感知部署工作流。系统由自然语言理解（LLM）、YAML 翻译（确定性代码）、多层验证、自动部署与评估五个任务组成，将自然语言应用描述自动转换为完整的 Kubernetes 部署与 Chaos Mesh 网络模拟配置。**实验表明：在 10 个计算连续体场景上，端到端部署成功率达 X%，与人工配置相比节省 Y% 设计时间，并能精确复现 Arena 论文实验 2 的网络限速结果（误差 < 10%）。**
