# ADR-006 推送走 DSH 官方 hook 桥；"尚未被证实会触发"是已记录的现状

**状态**：Accepted（2026-09-20 随初版 `13734e3` 落地；2026-10-07 补记为 ADR）。
**附带一条硬规矩**：见下面的"记录方式"。

**背景**：想在两个时机推手机：会话卡在"等你回答"（`PreToolUse` +
`ask_user_question`）、一轮跑完（`Stop`）。怎么拿到这两个时机有两条路：
读会话日志、或用 DSH 官方给 hook 留的接口。

**决策**：用官方 hook 桥 `@deepseek-ai/dsh-hooks-claude-code`：

- 模板 `hooks/claude-hooks.json`（`dsh-notify --hook --async`，两个事件，timeout 20）；
- `dsh-remote notify-enable` 把它渲染进 `$CONF_DIR/hooks.json`，
  再往 `$DSH_HOME/profiles/web/cordis.patch.yml` 里插一段 **`- insert:`** 的
  `hooks-claude-code` 条目，`configPath` 指向前者。

**为什么不读会话日志**：会话日志是 `session.v3.jsonl.zstd`，**多帧 + 自定义分帧**，
用标准 zstd 解压到第二帧就报 `Unknown frame descriptor`（实测，见 README §4）。
格式是内部实现，会变；hook 桥是官方给"会话/工具/回合"留的接口。

**记录方式（本 ADR 真正要固化的那半条）**：这条桥**挂上了，但没有被证实会触发**
（2026-09-21 的对照实验：`configPath` 指到不存在的文件也不报错；一次性 headless
会话里 `SessionStart`/`Stop`/`PreToolUse` 一个都没触发；正在跑的实例十几轮没写过日志）。
这件事**不许只留在提交信息或某次对话里**，必须同时写进：

| 放哪 | 写什么 |
|---|---|
| `architecture.md` §9 | 现状：挂了、没触发、排除了哪些可能、`check-hooks` 做什么 |
| `README.md` §4 | 给用户的说明 + 两条出路（装 pnpm 走 `dsh plugin add` / 先手动 `dsh-notify`） |
| `docs/hazards.md` H3 | 现象 → 根因假设 → 复查命令 → 判据（触发=0，没触发=1） |
| 本 ADR | **硬规矩：在证实之前，不许把"会话卡住会推手机"写成已有能力** |

**理由**：这类"看起来接好了、其实没生效"的接口最容易被下一个人当成已有能力来依赖；
把它钉成文档事实 + 一条可执行的复查命令，比留在谁的记忆里可靠。

**否决**：解析会话日志（格式内部、会变、实测解不动）；
改 harness 启动参数来挂插件（要重启，打断正在跑的会话）；
在会话里"顺手试试看"（一次性进程才是对照实验，`check-hooks` 就是它的封装）。

**后果**：今天能用的推送只有手动的那条（`dsh-notify "标题" "正文"` / `dsh-remote notify-test`）。
要坐实桥，两条路（都得用户定）：装 pnpm 后 `dsh plugin --profile web add …` 并重启
`dsh web`（会打断会话）；或者先用手动推送。见 `BACKLOG.md`。
