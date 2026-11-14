# 小鲸鱼桌宠 — 交接文档

> 更新时间：2026-11-14
> 用途：把当前进展、架构、配置、已知坑和下一步任务完整交给 Cursor 继续开发，避免重新摸索。

---

## 0. 一句话现状

小鲸鱼已经是一个能独立运行的 Windows 桌宠：语音唤醒、语音对话、聊天、记忆、交给 DSH 干活、打开应用/网站、浏览器搜索/读页面。
DSH 侧已接入 OpenViking 记忆、session-search、Agent Teams、modlens 视觉；本地跑着 Qwen2.5-VL 3B、Qwen3-Embedding 0.6B 和 OpenViking server。
**桌宠本体还没有接 OpenViking 和本地视觉**，这是下一步的主要工作。

---

## 1. 仓库与运行目录

| 用途 | 路径 |
|---|---|
| Git 仓库（源码，Cursor 在这里开发） | `D:\repos\whale-desktop-pet` |
| GitHub | https://github.com/Jerenyaoyelu/your-beloved-fish |
| 实际运行目录（数据、venv、模型） | `C:\Users\ASUS\Documents\deepseek-harness\default-workspace\whale-pet` |

> 仓库名实际是 `your-beloved-fish`，本地目录叫 `whale-desktop-pet`，两者是同一个项目。

**重要**：`voice\.venv`、`voice\models`、`data\`、`openviking\.venv` 都在运行目录，**不在 Git 仓库里**（`.gitignore` 已排除）。Cursor 改完代码后，需要把改动同步到运行目录，或者直接在运行目录开发、再拷回仓库提交。

---

## 2. 架构

```
┌─────────────────────────────┐
│  小鲸鱼 WPF 桌宠 (WhalePet.ps1) │
│  语音 / 聊天 / 记忆 / 托盘 / 皮肤 │
└──────┬───────────┬──────────┘
       │           │
       │           ├── 本地快捷动作（打开应用/网站/搜索）
       │           ├── Playwright 浏览器（搜索/读页面）
       │           ├── Whisper 语音（voice\utterance.py）
       │           └── DSH headless（工作/文件/命令）
       │                    │
       │                    └── DSH 插件：OpenViking / session-search / Agent Teams / modlens
       │
       └── 本地服务（需先启动）
             ├─ :8080 Qwen2.5-VL-3B  (视觉)
             ├─ :8081 Qwen3-Embedding-0.6B (向量)
             └─ :1933 OpenViking server (记忆)
```

---

## 3. 已实现功能

### 3.1 桌宠本体

- 透明置顶、拖动、托盘、开机自启、换肤（PNG/GIF/JPG）
- 单击冒泡（余额/今日 token/待办数），双击聊天
- 聊天：DeepSeek API，工具调用（待办、提醒、记忆、文件、时间等）
- 本地记忆：`data/memory.json`（事实/待办/提醒/摘要）+ `data/sessions/*.jsonl`（逐天对话）
- 每 4 轮自动抽取事实/待办；每天首次启动整理
- 读屏 OCR（Windows OCR）
- TTS 朗读（Microsoft Huihui）
- 余额低提醒、错过提醒补发、余额恢复提醒
- 右键菜单：聊天、记忆、皮肤、语音输入、语音唤醒、设置、测试语音、DSH 备用

### 3.2 语音

- `Ctrl+Alt+V` 单向听写（Whisper，填输入框，可选自动发送）
- 唤醒词「小鱼小鱼」（SAPI 语法识别，离线）
- 唤醒后进入语音对话：录音 → Whisper → 发送 → 回复朗读 → 继续听
- 端点检测：静音 1.8 秒判停；结尾是连接词/太短则继续听
- 状态栏：🎤 正在听 / 🤔 正在想 / 🔊 正在说 / 🤔 DSH 处理中

### 3.3 交给 DSH

- 自动识别 / `@dsh` / `交给 DSH` / `让 DSH` 触发
- 持久会话（`data/dsh-session.json`，跨重启）
- `--json` 流式输出，气泡实时更新
- 开跑前权限预检：任务涉及 Downloads/Desktop/Documents 或工作区外路径时，先问「要 / 总是 / 不要」
  - 「总是」写入 `data/config.json` 的 `dshAllowedDirs`
- 沙箱拒绝兜底：失败后仍可授权重试（`--add-dir`）

### 3.4 调度器（`lib/Router.psm1`）

| 路由 | 例子 | 执行者 |
|---|---|---|
| `action_open` / `action_search` | 打开浏览器、搜一下 | 本地秒开 |
| `browser_search` / `browser_read` | 搜一下并总结、读网页 | Playwright |
| `dsh` | 建文件、改代码、跑命令 | DSH headless |
| `ambiguous` | 「…可以吗？」 | 先确认 |
| `chat` | 闲聊 | 聊天模型 |

路由结果写日志：`路由: browser_search | 搜索并总结`

### 3.5 DSH 插件（本机已装并在 desktop profile 生效）

| 插件 | 状态 |
|---|---|
| `@openviking/dsh-memory-plugin` | ✅ MCP 工具可用，语义记忆写入/检索已测通 |
| `@deepseek-ai/dsh-experimental-session-search` | ✅ 已装（desktop + headless） |
| `@deepseek-ai/dsh-experimental-agent-team-profile` | ✅ 已装（desktop） |
| `@liustack/modlens` | ✅ 已装，配置为本地 `openai` 引擎（:8080） |

---

## 4. 本地服务

| 服务 | 端口 | 启动方式 | 现状 |
|---|---|---|---|
| Qwen2.5-VL-3B（视觉） | 8080 | `tools\start-local-services.ps1` | 上下文 8192，显存约 5.5GB |
| Qwen3-Embedding-0.6B | 8081 | 同上 | 1024 维 |
| OpenViking server | 1933 | 同上 | health/ready 200 |

一键启动：

```powershell
powershell -ExecutionPolicy Bypass -File tools\start-local-services.ps1
```

脚本会跳过已运行的端口，并做健康检查；**目前没有开机自启**，重启电脑后必须手动跑，否则：
- OpenViking/modlens 连不上
- 桌宠记忆/视觉降级

模型路径（运行目录）：

```
voice\models\qwen-vl\llama\llama-server.exe
voice\models\qwen-vl\Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf
voice\models\qwen-vl\mmproj-F16.gguf
voice\models\qwen-vl\Qwen3-Embedding-0.6B-Q8_0.gguf
```

---

## 5. 关键文件

| 文件 | 作用 |
|---|---|
| `WhalePet.ps1` | 主程序（约 3000 行）：UI、聊天、语音、DSH、路由分发、OCR、TTS |
| `lib\Brain.psm1` | 系统提示、工具定义、记忆抽取/反思提示 |
| `lib\Store.psm1` | 本地 JSON 记忆（事实/待办/提醒/摘要/对话） |
| `lib\Router.psm1` | 指令路由器 |
| `lib\Skins.psm1` | 皮肤管理 |
| `voice\utterance.py` | VAD 录音 + Whisper 转写 |
| `voice\browser.py` | Playwright 无头搜索/读页面 |
| `voice\vision.py` | 本地 Qwen2.5-VL 看图（llama-mtmd-cli） |
| `voice\setup.ps1` | 首次安装语音依赖 + 下载 Whisper 模型 |
| `tools\wake.ps1` | SAPI 唤醒词监听 |
| `tools\asr.ps1` | SAPI 单向听写（旧，备用） |
| `tools\ocr.ps1` | Windows OCR |
| `tools\start-local-services.ps1` | 启动 8080/8081/1933 |
| `docs\ROADMAP.md` | 早期路线图（部分已过时） |

---

## 6. 配置

### 6.1 桌宠 `data\config.json`

关键字段：

```json
{
  "apiKeyProtected": "...",      // DPAPI 加密的 DeepSeek Key
  "model": "deepseek-chat",
  "ttsEnabled": true,
  "voiceAutoSend": false,
  "voiceWakeEnabled": true,
  "voiceWakeWord": "小鱼小鱼",
  "voiceSilenceMs": 1800,
  "dshAllowedDirs": [],
  "dshRoot": ""
}
```

### 6.2 OpenViking `~/.openviking/ov.conf`

```json
{
  "storage": { "workspace": "<运行目录>\\openviking\\data" },
  "embedding": {
    "dense": {
      "provider": "openai",
      "api_base": "http://127.0.0.1:8081/v1",
      "api_key": "local",
      "model": "Qwen3-Embedding-0.6B",
      "dimension": 1024
    }
  },
  "vlm": {
    "provider": "openai",
    "api_base": "https://api.deepseek.com/v1",
    "api_key": "<DeepSeek Key>",
    "model": "deepseek-chat"
  }
}
```

> 当前 VLM 临时用 DeepSeek：本地 3B 无法解析 OpenViking 的记忆抽取 SDK 格式（会报 `unknown SDK method sdk.get_soul()`）。
> 注意：Key 是明文存在这个文件里，注意不要提交。

### 6.3 modlens `~/.modlens/config.json`

```json
{
  "providers": {
    "openai": {
      "apiKey": "local",
      "baseUrl": "http://127.0.0.1:8080/v1",
      "model": "Qwen2.5-VL-3B-Instruct",
      "structuredOutput": true
    }
  },
  "provider": "openai"
}
```

### 6.4 DSH profile

- desktop：`~/.dsh/profiles/desktop/package.json`（4 个插件）
- headless：`~/.dsh/profiles/headless/package.json`（base + headless + session-search + OpenViking）
- DSH CLI：`D:\Program Files (x86)\dsh\resources\runtime\cli\bin\dsh.cmd`
- DSH 桌面 app：`D:\Program Files (x86)\dsh\DeepSeek Harness.exe`

用户环境变量：`OPENVIKING_URL=http://127.0.0.1:1933`

---

## 7. 运行

```powershell
# 1) 本地服务
powershell -ExecutionPolicy Bypass -File tools\start-local-services.ps1

# 2) 桌宠
powershell -STA -ExecutionPolicy Bypass -File WhalePet.ps1

# 3) 语音首次安装（换机器才需要）
powershell -ExecutionPolicy Bypass -File voice\setup.ps1
```

DSH 桌面端需要重启后才会加载新插件。

---

## 8. 已验证

- 语音：唤醒「小鱼小鱼」→ 对话 → 识别「打开计算器」→ 执行
- 视觉：本地 Qwen 对测试图 OCR 正确（「小鲸鱼测试图片 / 这是第二行文字：你好，世界」）
- modlens：本地 `openai` 引擎 analyze 成功，schema 校验通过
- OpenViking：写入「测试口令是蓝色鲸鱼」→ 语义检索命中 91%，生成 `entities/…/小鲸鱼.md`（测试数据已删）
- DSH：持久会话、流式输出、权限预检、写 Downloads 成功
- 浏览器：Bing 搜索 + 读页面
- 快捷动作：打开记事本/计算器/浏览器

---

## 9. 已知问题 / 坑

1. **PowerShell 5.1 + WPF**：脚本必须 STA；`.ps1/.psm1` 必须 **UTF-8 with BOM**，否则中文乱码/函数找不到
2. **不要用 `Start-Process` 启动带 Mark-of-the-Web 的 python.exe**：会弹安全警告；语音里已改用 `ProcessStartInfo.UseShellExecute=false`
3. **OpenViking 抽取用 3B 会失败**：需要强文本模型（当前 DeepSeek），或换 7B/14B 本地
4. **服务无开机自启**：重启后所有本地能力失效
5. **桌宠记忆仍是 JSON**：`search_memory` 走 `lib\Store.psm1`，没有调 OpenViking
6. **桌宠视觉仍是 OCR**：没有调 8080 的 Qwen
7. **余额低**：DeepSeek 余额约 ¥4.25，抽取会消耗
8. **Cursor 订阅不能当通用 API**：官方只有 Cloud Agents API，不是 OpenAI 兼容；社区 cursor2api 属非官方逆向，不建议接
9. **OpenViking `ov` CLI**：会报需要设置显示语言，CLI 配置文件有问题；server/MCP 不受影响
10. **全局热键 Ctrl+Alt+V** 可能与其他软件冲突

---

## 10. 下一步任务（按优先级）

### P0 · 服务自启与健康检查（0.5 天）

- [ ] 把 `tools\start-local-services.ps1` 注册为登录计划任务
- [ ] 桌宠启动时检查 8080/8081/1933，不可用则降级并提示
- [ ] 服务异常时写日志、自动重试

验收：重启电脑后不手动操作，桌宠记忆/视觉仍可用。

### P1 · 桌宠记忆接 OpenViking（1–2 天）

- [ ] 新增 `memory_search` / `memory_remember`，调 OpenViking MCP（`http://127.0.0.1:1933/mcp`）
- [ ] 替换 `WhalePet.ps1` 中 `search_memory` 的实现
- [ ] 保留本地 JSON 作为离线缓存
- [ ] 迁移现有事实/待办到 OpenViking（可选）

验收：问「你还记得…」时能命中 OpenViking 的历史记忆，而不是只靠 JSON。

### P2 · 桌宠视觉接本地 Qwen（1 天）

- [ ] 「看看这个」截图 → `POST http://127.0.0.1:8080/v1/chat/completions`（image_url base64）
- [ ] 结果作为下一条消息上下文；OCR 保留做快速取字
- [ ] 状态栏显示「👀 正在看…」

验收：截一张有文字的窗口，能描述内容并读出文字。

### P3 · DSH 插件端到端验证（0.5 天）

- [ ] session-search 查历史会话
- [ ] Agent Teams 跑一个双 Agent 小任务
- [ ] 确认 desktop UI 里四个插件都正常
- [ ] 验证 headless + OpenViking 的记忆读写

### P4 · 成本与打包

- [ ] 决定记忆抽取用：免费 Gemini Key / 本地 7B / DeepSeek
- [ ] 低余额保护 + 充值提醒
- [ ] 一键安装包（桌宠 + 服务 + 模型）

---

## 11. 给 Cursor 的注意事项

1. **不要重写**：`WhalePet.ps1` 已经很大，按函数改；先读 `lib\Router.psm1`、`lib\Store.psm1` 再动。
2. **改完必须同步到运行目录**（或直接在运行目录改，再拷回仓库）：
   ```powershell
   Copy-Item WhalePet.ps1 C:\Users\ASUS\Documents\deepseek-harness\default-workspace\whale-pet\ -Force
   ```
3. **测试前先起服务**：`tools\start-local-services.ps1`
4. **用运行目录测试**，因为模型/venv/data 都在那里。
5. **不要提交**：`data\`、`voice\.venv`、`voice\models`、`openviking\.venv`、`~/.openviking/ov.conf`（含 Key）。
6. **语音相关**：Whisper 模型、唤醒词、录音设备都在运行目录，改之前先跑一遍现状。
7. **DSH 相关**：改 `WhalePet.ps1` 的 `Start-DshTask` / `Invoke-BrowserTask` 时注意 `DispatcherFrame` 泵消息，别把 UI 卡死。

---

## 12. 成本

| 项目 | 费用 |
|---|---|
| 桌宠聊天 | DeepSeek API，按 token |
| OpenViking 记忆抽取 | 当前 DeepSeek，按 token（很便宜，但余额低） |
| 本地视觉/向量 | ¥0（电费） |
| modlens | 当前本地 Qwen，¥0 |
| 可选：Gemini 免费 Key | 视觉/抽取可切免费额度 |

余额约 ¥4.25，建议先充或切免费 Gemini。
