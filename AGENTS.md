# AGENTS.md —— tools/dsh-remote

> 先读用户级 `~/.dsh/AGENTS.md`（工作区通用规则）和仓库根 `AGENTS.md`（多仓库工作区规则），
> 本文件只讲**这个项目**的事。

## 这个项目是什么

手机远程接管家里这台机器上的 DSH 会话：手机浏览器 → 阿里云 Caddy（HTTPS +
basic auth）→ SSH 反向隧道 → 家里 `127.0.0.1:3080`（`dsh web`），外加一条
"卡在等你回答 / 一轮跑完"的推送。

**它是独立项目**：`wtool install tools/dsh-remote` 之后才有 `dsh-remote` /
`dsh-notify` 两条命令。仓库里只有文本（脚本 + 两个 Caddyfile 模板 + 文档），
证书 / 密码 / 密钥 / 日志一律在安装落点，不进 git。

| 东西 | 在哪 |
|---|---|
| 家这头的命令 | `bin/dsh-remote`、`bin/dsh-notify` |
| 云端（阿里云）的一条命令装好 | `cloud/relay.sh` + `cloud/Caddyfile.*` + `cloud/docker-compose.yml` |
| hook 桥的模板 | `hooks/claude-hooks.json`（`dsh-remote notify-enable` 渲染进配置目录） |
| shell 集成（zsh/bash 各一份） | `env.zsh` / `env.bash` |
| 服务清单 | `wtool.xml` |
| 给用户的说明书 | `README.md` |

## 三条硬规矩

1. **`scripts/install.sh` 里不许写死 `$HOME/.wtool/...`。**
   源问引擎要 `WTOOL_PROJECT_DIR`（手跑按 `$0` 自推），落点从
   `WTOOL_HOME` / `WTOOL_PREFIX` 推。写死的后果是**报"install 完成"却什么都没装**
   （2026-10-04 实测：源钉在 `~/.wtool/wtool-work-dir/links/...` 这格引擎内部布局上，
   换 `WTOOL_HOME` 装就指丢，而检查是"找不到就跳过"）。
   **源找不到 = 只跳过那一条 + 打印去哪儿找了**，绝不整脚本静默退出；
   **只有真要装才 `mkdir`**（别留"空目录 + 指向它的软链"这种看着像装好了的东西）。
   回归测试在 `tests/run_tests.sh` 的 I 节。

2. **别在真 `$HOME` 上跑 `scripts/install.sh` 或测试。**
   测试全部用临时的 `HOME` / `WTOOL_HOME` / `WTOOL_PREFIX` / `DSH_HOME` /
   `XDG_CONFIG_HOME` / `XDG_STATE_HOME`，跑完比对真 `$HOME` 的指纹。
   要手工试就照 I 节那样 `env HOME=$T/... sh scripts/install.sh`。

3. **我们自己的配置/日志不放 `~/.dsh`** —— 那是 DSH 自己的目录。
   配置在 `~/.config/dsh-remote/`（软链 → `$WTOOL_PREFIX/etc/dsh-remote`），
   日志在 `~/.local/state/dsh-remote/`（软链 → `$WTOOL_PREFIX/var/dsh-remote`）。
   **唯一例外**：`~/.dsh/profiles/web/cordis.patch.yml`（profile patch 只能放那儿）。

## README 是功能说明书，改了代码就同步改

`README.md` 是**给用户的完整功能说明书**（不是开发笔记）。对应关系：

| 改了什么 | 改 README 哪一节 |
|---|---|
| 加/改子命令、选项 | 「3. 命令」 |
| `scripts/install.sh`（装什么、装到哪、卸载撤什么） | 「2. 五步装好」第 0 步 / 「7. 占地与清理」 |
| `cloud/relay.sh`、`cloud/Caddyfile.*` | 「4. 为什么这么设计」/ 「5. 安全边界」 |
| `hooks/claude-hooks.json`、`notify-enable` 行为 | 「4. 为什么这么设计」里的钩子那两段 |
| `tests/` 的条数或覆盖面 | 「6. 测试」 |
| 环境变量、路径约定 | 「2. 五步装好」/ 「7. 占地与清理」 |

**README 与代码不一致 = 缺陷**，不是"以后补"。README 里**不写"怎么手工跑
`scripts/install.sh`"** —— 它是 `wtool install` 调的，安装只有一句话
（`wtool install tools/dsh-remote`）。

## `wtool.xml` 要跟上引擎（它现在会硬报错）

- **`id=` 属性已经取消**（引擎 `wtool_plan.py` 硬报错，不留兼容窗口）：
  项目身份就是它相对工作区根的路径。`tools/dsh-remote` 这个属性是 2026-10-04
  端到端验证时发现并删掉的 —— 带着它会 `wtool install` 直接 exit 2，
  `scripts/install.sh` 根本没机会跑。
- 旧标签 `<env src= shells=>`（每次解析都告警）已改成
  `<zshrc src="env.zsh"/>` + `<bashrc src="env.bash"/>`；`<link src= dest=>` 同理。
- 改完跑 `wtool validate tools/dsh-remote`（只读）应打印 `ok: tools/dsh-remote`。

## 测试

```sh
cd tools/dsh-remote
sh tests/run_tests.sh         # 179 条，不联网、不碰 docker、不碰真 $HOME（秒级）
sh tests/caddy-validate.sh    # 3 条，用 caddy:2 镜像真校验 Caddyfile（要 docker，人工）
tests/relay-e2e.sh            # 真起 caddy 容器验 HTTPS+basic auth+反代（要 docker，人工）
```

改了 `scripts/install.sh` / `env.zsh` / `env.bash` / `wtool.xml` **一定要跑
`tests/run_tests.sh`**（I 节守的就是"命令真装得出来、源找不到不装假"）。

## 已知缺口（别当成已经有能力）

- **hook 桥还没被证实会触发**（2026-09-21 实测：profile patch 挂上了，但
  `SessionStart`/`Stop`/`PreToolUse` 一个都没触发）。在证实之前，
  **不要把"会话卡住会推手机"写成已有能力**；`dsh-remote check-hooks` 是那条
  一次性复查命令（触发 → 0，没触发 → 1）。细节见 README §4。
- 真阿里云的安全组/防火墙、手机浏览器实测、隧道断线重连时长都**没有自动测**。

## 提交

改动只提交到 `ds_dev`（用户级规则见 `~/.dsh/AGENTS.md` §1）：`git add` 前先
`git diff` 看一遍、提交带 `-m`、**不 push、不动 `main`**。
