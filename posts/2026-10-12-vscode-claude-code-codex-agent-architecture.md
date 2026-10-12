# 在 VSCode 里并存的多套 AI Agent:从 ps 输出看 Claude Code 插件、内置 Agents 模式与 Codex app-server

## 现象

在 VSCode 里"让 AI 写代码"至少有三个入口:

1. **Claude Code 官方插件**(扩展面板里的 anthropic.claude-code);
2. **VSCode 内置的 Agents 模式**(Copilot Chat 的 agent 模式,模型可以选 Claude、GPT、Codex 等);
3. **ChatGPT 桌面版**里的 Codex。

直觉上很容易把它们当成"同一个 Claude / 同一个 Codex,套了不同的皮"。但 `ps -ef` 看一眼就会发现,同一台机器上其实并存着**多份互相独立的 agent 内核**,连协议都不一样。

下面所有证据都来自我本机(macOS,arm64)的真实进程,逐个拆解。

## 证据一:Claude Code 插件 —— 自带的 230MB native binary,走 stream-json

启动插件后能看到这样的进程:

```text
$ ps -ef | grep claude | grep -v grep
502 5305 4085 ... /Users/junjie20/.vscode/extensions/anthropic.claude-code-2.1.296-darwin-arm64/resources/native-binary/claude \
    --output-format stream-json --verbose --input-format stream-json \
    --max-thinking-tokens=31999 --permission-prompt-tool=stdio \
    --setting-sources=user,project,local --include-partial-messages \
    --debug --debug-to-stderr --enable-auth-status --no-chrome --replay-user-messages
```

两个关键事实:

**第一,二进制是插件自带的,和全局安装的 claude 无关。**

```text
$ ls -lh ~/.vscode/extensions/anthropic.claude-code-2.1.296-darwin-arm64/resources/native-binary/
-rwxr-xr-x  1 junjie20  staff   230M  claude

$ file .../native-binary/claude
Mach-O 64-bit executable arm64
```

这是一个完整的、独立打包的 Mach-O 可执行文件。而我在终端里用的全局 CLI 是另一份:

```text
~/.local/bin/claude  →  版本管理目录 ~/.local/share/claude/versions/2.1.296 → 2.1.289
```

插件版是 2.1.296,全局版是 2.1.289——**同一台机器上两个 claude 内核,版本可以不一致,升级也互不影响**。插件更新时替换自己扩展目录里的那份,全局 CLI 用 `claude update` 更新 `~/.local/share/claude/versions/` 下的那份。这样做的好处是显然的:插件作者可以锁定并随发随更自己验证过的内核版本,不用担心用户机器上装了什么版本的 CLI、也不用要求用户先装 CLI。

**第二,插件与内核之间的通信协议是 stdin/stdout 上的 JSONL。**

上面那一串参数其实就是在描述这套协议:

| 参数 | 含义 |
|---|---|
| `--input-format stream-json` | 从 **stdin** 读用户消息,每行一个 JSON 对象 |
| `--output-format stream-json` | 往 **stdout** 写 agent 事件流(工具调用、文本增量、结果等),每行一个 JSON |
| `--permission-prompt-tool=stdio` | 权限询问(要不要允许执行这条命令/改这个文件)也通过 stdio 通道走 JSON 回传,而不是在终端里弹交互确认 |
| `--include-partial-messages` | 流式输出 token 级的增量,插件 UI 才能做打字机效果 |
| `--replay-user-messages` | 把用户消息回放给 stdout,便于 UI 对账 |
| `--setting-sources=user,project,local` | 仍然加载 `~/.claude/settings.json`、项目 `.claude/settings.json` 和 local 配置——所以 CLAUDE.md、自定义指令这些在插件里照样生效 |
| `--no-chrome` | 关掉 TUI 渲染(反正没人看它的"终端界面") |

也就是说,**插件的 WebView 只是一个 UI 壳,真正的 agent 循环、工具执行、权限判断全部在那个子进程里**。插件干的事是:把你的输入序列化成 JSON 写进子进程的 stdin,再从 stdout 逐行读事件渲染到界面上。这套接口就是官方 headless 模式(`claude -p --output-format stream-json`)的同款,也是 Claude Agent SDK 底层用的同一条通道。

顺带一提,全局 CLI 自己还有一套常驻进程形态:

```text
~/.local/bin/claude daemon run --origin transient ...      # 守护进程
claude bg-pty-host ...                                     # 后台 PTY 宿主
~/.local/share/claude/versions/2.1.289 --session-id ... --resume ...   # 会话进程
```

这是 CLI 为后台任务、会话恢复做的进程管理,和插件那条路完全独立。

## 证据二:VSCode 内置 Agents 模式 —— Agent Host 与它自己的 sdk-cache

VSCode 现在把"接入第三方 agent"这件事抽象成了一个专门的 **Agent Host** 进程 + **harness(执行框架)**的概念(见官方文档 *Agent Host* / *Agent harnesses*)。你在 Chat 视图里切换的 Local / Copilot / Claude / Codex,选的是 harness 而不是模型。

VSCode 会**自己下载并管理各 harness 的运行时**,缓存位置在:

```text
$ ls "$HOME/Library/Application Support/Code/agent-host/sdk-cache/"
claude/   codex/

$ ls .../sdk-cache/claude/0.3.258/darwin-arm64/node_modules/@anthropic-ai/
claude-agent-sdk/
claude-agent-sdk-darwin-arm64/

$ cat .../claude-agent-sdk-darwin-arm64/package.json
{"name":"@anthropic-ai/claude-agent-sdk-darwin-arm64",
 "description":"Native CLI binary for @anthropic-ai/claude-agent-sdk on darwin-arm64", ...}
```

这就回答了我在主题里提出的问题:**内置模式下用 Claude,不需要装 Claude Code 插件,但 VSCode 确实会下载自己的运行时**——`@anthropic-ai/claude-agent-sdk`(版本号是 0.3.258,和 CLI 的 2.1.x 是两套版本序列),而它的平台子包描述里写得明明白白:里面带的就是一个 native CLI binary。

于是同一台机器上,Claude 的 agent 内核至少存在三份互不相干的副本:

| 来源 | 位置 | 版本 |
|---|---|---|
| Claude Code 插件 | `~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude` | 2.1.296 |
| VSCode Agent Host | `~/Library/Application Support/Code/agent-host/sdk-cache/claude/0.3.258/...` | SDK 0.3.258 |
| 全局 CLI | `~/.local/share/claude/versions/2.1.289` | 2.1.289 |

顺带说明:如果你在 Copilot Chat 里只是把 Claude 当**模型**用(纯对话/普通 agent mode,不启用 Claude harness),那走的是 Copilot 的模型 API,本地不需要任何 Anthropic 运行时;启用 Claude harness 后,才落到上面 sdk-cache 里那份 SDK 上。

## 证据三:codex app-server —— 一个内核,三个宿主

Codex 这边把"内核复用"演绎得更彻底。`ps -ef | grep app-server` 能同时看到三条路:

**宿主一:VSCode 内置 Agents 模式(Codex harness)**

```text
$ ps -ef | grep app-server
.../Code/agent-host/sdk-cache/codex/0.157.0/darwin-arm64/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex app-server \
  -c model_providers.vscode-proxy.name="VS Code Proxy" \
  -c model_providers.vscode-proxy.base_url="http://127.0.0.1:65328/v1" \
  -c model_providers.vscode-proxy.wire_api="responses" \
  -c shell_environment_policy.set.AI_AGENT="github_copilot_vscode_agent" \
  -c default_permissions="vscode-workspace" \
  -c permissions.vscode-workspace={ filesystem = { ... }, network = { enabled = false } } ...
```

这段参数信息量很大:

- `app-server` 是 codex 内置的一个**服务端子命令**:以 JSON-RPC 的方式在 stdio 上提供服务(会话管理、任务执行、审批回调),供宿主进程驱动。内核还是那个 codex,只是不再自带 UI。
- `base_url="http://127.0.0.1:65328/v1"`:codex 的**模型请求被指回 VSCode 的本地代理端口**,真正出网、鉴权、计费都由 VSCode/Copilot 那一层接管——所以内置模式下用 Codex 可以直接走 Copilot 订阅的额度。
- `AI_AGENT="github_copilot_vscode_agent"`:给模型和遥测标记当前的宿主身份。
- `default_permissions="vscode-workspace"` + permissions 映射:codex 自己的沙箱/审批体系被映射到 VSCode 的权限模型上(工作区可写、其余只读、默认禁网)。

**宿主二:ChatGPT 桌面版**

```text
/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex \
  -c features.code_mode_host=true app-server --analytics-default-enabled ...
```

ChatGPT 桌面版内嵌了一份 codex-cli,给它的编码功能也是拉起 `codex app-server`。同一个内核,换了壳。

**宿主三:codex CLI 自己**

```text
~/.codex/packages/app-server-daemon/releases/0.159.2-aarch64-apple-darwin/bin/codex app-server \
  --listen unix:// --managed-daemon
```

codex CLI 自己还会起一个常驻 daemon,监听 unix socket,给多个前端复用。

也就是说,`ps -ef | grep app-server` 里每一个进程,都是"**同一个 codex 内核 + 不同宿主**"的一个实例;版本还各不相同(0.157.0 / 0.159.2 / ChatGPT 内嵌版)。

## 总结:同一个模式 —— 无头内核 + 宿主壳

把三组证据放在一起,架构上是同一个思路:

```text
┌──────────┐   UI 壳(WebView / Chat 面板 / 桌面 App)
│   宿主    │   输入渲染、会话列表、权限弹窗
└────┬─────┘
     │  IPC:stream-json(JSONL over stdio)
     │      或 JSON-RPC(app-server over stdio / unix socket)
┌────┴─────┐
│ agent 内核 │  工具执行、权限判断、上下文管理、模型调用
└──────────┘
```

| 入口 | agent 内核来源 | 进程形态 | 协议 | 计费 |
|---|---|---|---|---|
| Claude Code 插件 | 插件扩展目录自带的 binary | `claude` 子进程(每会话) | stdin/stdout JSONL(`stream-json`) | Anthropic 账号 |
| VSCode 内置模式(Claude harness) | Agent Host 下载的 `@anthropic-ai/claude-agent-sdk` | Agent Host 内运行 | Agent Host 协议(JSON-RPC) | Copilot 额度或 Anthropic |
| VSCode 内置模式(Codex harness) | Agent Host 下载的 `@openai/codex` | `codex app-server` 子进程 | JSON-RPC over stdio | Copilot(经本地代理) |
| ChatGPT 桌面版 | App 内嵌的 codex-cli | `codex app-server` 子进程 | JSON-RPC | ChatGPT 订阅 |
| 终端 CLI | `~/.local/share/claude/versions/` | 前台进程 + daemon | TUI / stream-json | Anthropic 账号 |

两种 IPC 风格也有区别:

- **stream-json(Claude Code 插件)**:单会话、单向管道式的 JSONL,一个子进程对应一个会话,简单直接;
- **app-server(Codex)**:常驻服务端、JSON-RPC 多会话,宿主可以同时管理多个会话、订阅事件流,还能被 unix socket 上的多个客户端共享。

## 实际影响

理解了这个分层,有几个日常可感知的推论:

1. **版本漂移是常态**。插件、SDK 缓存、全局 CLI 各自独立升级,同一个 Claude 内核在你机器上可能同时是三个版本。遇到"插件里行为和终端里不一样"时,先查版本。
2. **配置体系部分共享、进程完全隔离**。Claude Code 插件通过 `--setting-sources=user,project,local` 仍然读你的 CLAUDE.md 和 settings.json,所以项目级约定在插件里生效;但三个内核的登录态、缓存、日志互不相通。
3. **磁盘开销**。一份 Claude native binary 230MB,而它可能存在于 `~/.vscode/extensions/`、`agent-host/sdk-cache/`、`~/.local/share/claude/versions/` 三处;codex 同理。
4. **排查问题从进程入手最直接**:

```bash
# 谁在跑、哪个版本、什么协议
ps -ef | grep -E "claude|app-server" | grep -v grep

# VSCode 下载了哪些 agent 运行时
ls "$HOME/Library/Application Support/Code/agent-host/sdk-cache/"
```

## 小结

"VSCode 里的 Claude"从来不是一个东西:Claude Code 插件是自带内核的独立产品,内置 Agents 模式里的 Claude harness 是 VSCode 托管的另一份 SDK,而 Copilot 里的"Claude 模型"则可能压根没有本地运行时。Codex 走得更远——一个 `app-server` 内核被 VSCode、ChatGPT 桌面版、CLI daemon 三类宿主共享。

下一代编码工具的架构已经很清晰:**agent 内核无头化、协议标准化(stream-json / JSON-RPC),宿主只负责壳**。谁能把内核做扎实、把宿主生态铺开,谁就同时出现在所有编辑器里。
