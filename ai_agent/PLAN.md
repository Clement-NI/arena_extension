# Arena AI Agent 研究项目计划书

> **目标**：在 Arena 测试床之上构建 AI agent 层，自动化"应用拓扑设计 → 网络模拟 → 部署 → 评估"全流程。
>
> **关联论文**：Huang et al., "Arena: A Kubernetes-based Testbed for Evaluating Application Deployment across the Computing Continuum", IEEE ICC 2026.
>
> **本计划响应 Arena 论文 §V 提出的未来工作方向**：*"develop a topology-aware network modeling framework that allows users to specify application-level topologies so that Arena can automatically configure network characteristics."*

---

## 0. 整体架构

```
                    用户人话
                       ↓
              ┌────────────────┐
              │    Agent 2     │  LLM 理解自然语言
              │  拓扑生成器     │  抽取应用 + 链路 + 网络场景
              └────────┬───────┘
                       ↓
                topology.yaml   ←─ 中间接口（标准 schema）
                       ↓
              ┌────────────────┐
              │    Agent 1     │  确定性 Python 代码
              │  YAML 翻译+验证 │  生成 K8s + ChaosMesh YAML
              └────────┬───────┘  评估正确性
                       ↓
              可直接 kubectl apply 的 YAML
                       ↓
                Arena 集群跑实验
                       ↓
                Prometheus 数据
```

**分层依据**：LLM 不擅长生成精确的 YAML（缩进、字段名、版本号容易错），但擅长理解自然语言。让 LLM 只负责"理解+结构化"，让代码负责"精确生成+验证"。

---

## 1. Agent 1 — YAML 翻译与评估 Agent

### 1.1 目标

把结构化的 `topology.yaml` 转成可部署的 K8s + ChaosMesh YAML，并自动验证生成的 YAML 正确性。

### 1.2 输入 / 输出

**输入**
- `topology.yaml`（用户写，或 Agent 2 生成）
- `network_profiles.yaml`（预定义网络场景库，如 4G/5G/卫星）
- `nodes.json`（Arena 现有的节点配置）

**输出**
- `output/deployments.yaml` — 所有应用的 K8s Deployment
- `output/services.yaml` — 对应 Service
- `output/network-chaos.yaml` — 所有 NetworkChaos CRD
- `output/validation_report.json` — 验证报告

### 1.3 目录结构

```
ai_agent/agent1/
├── schemas/
│   ├── topology_schema.json
│   └── profile_schema.json
├── templates/                  # Jinja2 模板
│   ├── deployment.yaml.j2
│   ├── service.yaml.j2
│   ├── chaos_delay.yaml.j2
│   ├── chaos_bandwidth.yaml.j2
│   └── chaos_loss.yaml.j2
├── validators/
│   ├── schema_validator.py
│   ├── resource_validator.py   # 检查 CPU/内存够不够
│   └── dry_run_validator.py    # kubectl apply --dry-run
├── generator.py                # 核心翻译器
├── evaluator.py                # 评估生成质量
└── main.py
```

### 1.4 分步实施（4 周）

#### Week 1 — Schema + 基础翻译器

- [ ] **D1-2**：定义 `topology.yaml` 的 JSON Schema（nodes/links/network_profiles 字段）
- [ ] **D2-3**：定义 `network_profiles.yaml`，预填 6-8 个网络场景：
  - `4G_suburban` / `5G_urban` / `wifi_indoor`
  - `fiber_datacenter` / `satellite` / `lossy_wireless`
- [ ] **D3-5**：写 Jinja2 模板（5 个）
- [ ] **D5-7**：写 `generator.py`，从 topology + profiles 生成 YAML

**交付物**：`python generator.py topology.yaml` → 出 YAML 文件

#### Week 2 — 验证器（评估部分核心）

- [ ] **D1-2**：**Schema 验证**：用 `jsonschema` 校验输入合法性
- [ ] **D2-4**：**资源验证**：算所有 Deployment 的 CPU/内存总和，对比 `nodes.json`
- [ ] **D4-5**：**Dry-run 验证**：`kubectl apply --dry-run=server`
- [ ] **D5-7**：**拓扑闭环验证**：检查所有 link 引用的节点/profile 是否存在

**交付物**：`validation_report.json`，列出 error/warning/info

#### Week 3 — 实际部署 + 健康检查

- [ ] **D1-3**：写 `deploy.py`：`kubectl apply` + 等所有 pod Ready
- [ ] **D3-4**：写 `cleanup.py`：一键清理
- [ ] **D4-5**：加超时/重试逻辑
- [ ] **D5-7**：**健康检查**：每对 link 跑 `kubectl exec` ping，测延迟丢包

**交付物**：`./run.sh topology.yaml` → 部署完成 + 自检报告

#### Week 4 — 复现论文实验 2（里程碑）

- [ ] **D1-3**：把论文实验 2（IoT→Kafka→Logstash→ES + 限速）改写成 `topology.yaml`
- [ ] **D3-5**：用 Agent 1 生成，部署到 Arena
- [ ] **D5-7**：跑 10 分钟，测吞吐量，对比论文 Figure 5

**交付物**：复现论文实验 2 数据；一张对比图

### 1.5 评估指标

| 指标 | 测量方法 |
|---|---|
| **正确性** | 生成的 YAML 通过 `kubectl apply --dry-run` 的比例 |
| **完整性** | 拓扑里每条 link 是否都有对应的 ChaosMesh 规则 |
| **保真度** | 实测网络延迟/带宽，对比 profile 声明值的误差 |
| **复现性** | 跟论文 Figure 5 的吞吐量结果差异（应 < 10%） |

### 1.6 风险与缓解

| 风险 | 缓解 |
|---|---|
| ChaosMesh `target` 字段跨 namespace 行为奇怪 | 第一版全部用 `default` namespace |
| 多条 ChaosMesh 规则叠加效果不确定 | 用健康检查实测验证 |
| 资源不够导致 pod Pending | 生成阶段提前算总和并报错 |

---

## 2. Agent 2 — 拓扑生成 Agent

### 2.1 目标

把用户的自然语言描述翻译成 `topology.yaml`（Agent 1 的输入）。

### 2.2 输入 / 输出

**输入**
- 用户自然语言（单次或对话）
- 可选：业务约束（"4 核 16G 主机"、"模拟农村 4G"）

**输出**
- `topology.yaml`（符合 Agent 1 的 schema）
- `rationale.md`（Agent 解释设计理由，给用户看）

### 2.3 目录结构

```
ai_agent/agent2/
├── prompts/
│   ├── system_prompt.md        # 主提示词
│   ├── examples.md             # few-shot 例子
│   └── network_knowledge.md    # 网络场景知识库
├── tools/                      # 给 LLM 用的工具
│   ├── get_arena_resources.py  # 查询当前 Arena 集群资源
│   ├── list_profiles.py        # 列出可用网络 profile
│   ├── validate_topology.py    # 调 Agent 1 的 schema validator
│   └── search_image.py         # 找合适的 Docker image
├── llm_client.py               # Claude API 封装
├── chat.py                     # 交互式对话循环
└── main.py                     # 一次性生成模式
```

### 2.4 分步实施（4 周）

#### Week 5 — Prompt 工程基础

- [ ] **D1-2**：写 `system_prompt.md`，明确：
  - 任务：生成 topology.yaml
  - 严格遵守的 schema（贴上 Agent 1 的 schema）
  - 可用的 network profiles 列表
  - Arena 节点的 placement 选项（IoT/Edge/Cloud/Controller）
- [ ] **D3-4**：准备 5-10 个 few-shot 例子（input: 人话，output: topology.yaml）
- [ ] **D5-7**：写 `llm_client.py`，调 Claude API（`claude-sonnet-4-6`，开 prompt caching）

**交付物**：单次调用 — 人话 → topology.yaml 字符串

#### Week 6 — Tool use（让 LLM 能查信息）

- [ ] **D1-2**：实现 `get_arena_resources()` — 调 `kubectl get nodes -o json`
- [ ] **D2-3**：实现 `list_profiles()` — 读 `network_profiles.yaml`
- [ ] **D3-4**：实现 `validate_topology()` — 调 Agent 1 的 schema validator
- [ ] **D4-5**：接入 Claude tool use API
- [ ] **D5-7**：**自循环修正**：生成 → validate → 失败拿错误信息再生成（最多 3 轮）

**交付物**：Agent 能自我修正 — 验证失败时自动改

#### Week 7 — 多轮对话

- [ ] **D1-3**：写 `chat.py`，REPL 模式
- [ ] **D3-5**：支持改主意：
  ```
  用户: 加 10 个摄像头，5G 网络
  Agent: 好，更新 topology...
  用户: 改成卫星网络
  Agent: 把链路 profile 改成 satellite，重新生成
  ```
- [ ] **D5-7**：加澄清提问：信息不够时主动问
  ```
  用户: 我要测一个 IoT 应用
  Agent: 我需要更多信息：
    1. 几个 IoT 设备？
    2. 数据传给什么处理？
    3. 网络条件？
  ```

**交付物**：交互式对话界面

#### Week 8 — 评估 + 案例（里程碑）

- [ ] **D1-3**：设计 10 个真实场景的人话 prompt：
  - 智慧城市监控 / 工业 IoT / 农业监测 / 智能家居 / 车联网 等
- [ ] **D3-5**：让 Agent 生成，对每个：
  - 算生成的 topology.yaml 验证通过率
  - 跑 Agent 1 看能不能部署成功
  - 让人工评分（生成的拓扑合不合理）
- [ ] **D5-7**：总结：哪些场景容易做对、哪些容易出错

**交付物**：评估报告，写进论文 evaluation section

### 2.5 评估指标

| 指标 | 测量方法 |
|---|---|
| **Schema 通过率** | 生成的 topology.yaml 一次性通过 schema 验证的比例 |
| **端到端成功率** | 生成 → Agent 1 翻译 → 实际部署成功的比例 |
| **合理性（人工评分）** | 5 个 K8s 专家给生成的拓扑打分（1-5） |
| **修正轮数** | 一次成功 vs 需要 LLM 自我修正几轮 |

### 2.6 风险与缓解

| 风险 | 缓解 |
|---|---|
| LLM 生成字段名错（如 "latency" 写成 "delay_ms"）| Tool use 强制结构化输出 + 自动修正 |
| 用户描述模糊导致瞎猜参数 | 加澄清提问机制 |
| Claude API 成本 | 开 prompt caching，可省 ~90% token |
| 拓扑设计不合理（如把数据库放 IoT 节点）| System prompt 加放置规则 + 专家评分 |

---

## 3. 两个 Agent 的集成

```python
# ai_agent/integration.py
from agent2.main import generate_topology
from agent1.generator import generate_yamls
from agent1.deploy import deploy_to_cluster

user_input = "我要测试 10 个 IoT 摄像头通过 5G 上传到边缘转码器"

topology = generate_topology(user_input)      # Agent 2
yamls = generate_yamls(topology)              # Agent 1
report = deploy_to_cluster(yamls)             # Agent 1

print(report)
```

---

## 4. 时间表与里程碑

| 周 | Agent 1 | Agent 2 | 里程碑 |
|---|---|---|---|
| 1 | Schema + 翻译器 | – | |
| 2 | 验证器 | – | |
| 3 | 部署 + 健康检查 | – | |
| **4** | **复现论文实验 2** | – | **🎯 基础闭环跑通** |
| 5 | – | Prompt 工程 | |
| 6 | – | Tool use + 自修正 | |
| 7 | – | 多轮对话 | |
| **8** | 联调 | **10 场景评估** | **🎯 完整 demo + 评估数据** |

---

## 5. 8 周后的交付物清单

- [ ] 完整 Github 仓库（`ai_agent/agent1/` + `ai_agent/agent2/`）
- [ ] README 带 demo 录屏 / gif
- [ ] **复现论文实验 2 的数据**：5.7, 11.3, 27.7, 41.7, 41.9 docs/s
- [ ] **10 个场景的评估结果表**
- [ ] 1-2 页 short paper 草稿（投 workshop 或扩展为 full paper）

---

## 6. 技术栈

| 用途 | 选型 |
|---|---|
| 主语言 | Python 3.10+ |
| LLM | Claude Sonnet 4.6 (`claude-sonnet-4-6`)，开 prompt caching |
| 模板引擎 | Jinja2 |
| Schema 校验 | jsonschema |
| K8s 客户端 | `kubernetes` Python client + `kubectl` |
| 测试 | pytest |

---

## 7. 论文贡献声明（draft）

> **本工作扩展 Arena 测试床**，引入 LLM 驱动的拓扑感知部署 agent，将自然语言应用描述自动转换为完整的 Kubernetes 部署与 Chaos Mesh 网络模拟配置。Agent 1 提供确定性的 YAML 生成与多层验证，保证部署正确性；Agent 2 提供自然语言接口并支持自我修正。**实验表明：在 10 个计算连续体场景上，端到端部署成功率达 X%，与人工配置相比节省 Y% 设计时间，并能精确复现 Arena 论文实验 2 的网络限速结果。**

---

## 附录 A：topology.yaml 示例 schema

```yaml
nodes:
  - name: camera
    placement: IoT              # IoT | Edge | Cloud | Controller
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

links:
  - from: camera
    to: transcoder
    network: 4G_suburban

  - from: transcoder
    to: storage
    network: fiber_datacenter
```

## 附录 B：network_profiles.yaml 示例

```yaml
4G_suburban:
  latency: "40ms"
  jitter: "10ms"
  bandwidth: "20mbps"
  loss: "0.5%"

5G_urban:
  latency: "10ms"
  jitter: "2ms"
  bandwidth: "200mbps"
  loss: "0.1%"

wifi_indoor:
  latency: "5ms"
  bandwidth: "100mbps"
  loss: "0.3%"

fiber_datacenter:
  latency: "1ms"
  bandwidth: "10gbps"
  loss: "0%"

satellite:
  latency: "600ms"
  bandwidth: "5mbps"
  loss: "2%"

lossy_wireless:
  latency: "20ms"
  bandwidth: "10mbps"
  loss: "5%"
```
