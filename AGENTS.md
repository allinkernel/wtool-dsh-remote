# AGENTS.md —— tools/dsh-remote

> 先读用户级 `~/.dsh/AGENTS.md`（工作区通用规则）和仓库根 `AGENTS.md`（多仓库工作区规则），
> 本文件只讲**这个项目**的事：文档在哪、必须遵守什么、怎么交付。

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

---

## 文档地图（【wsw 文档体系】，五类 + 可选第六类）

| 想知道 | 看 | 谁写 / 怎么变 |
|---|---|---|
| **必须遵守什么规则、读哪些文件** | 本文件 + 用户级 `~/.dsh/AGENTS.md` | 稳定，可迭代 |
| **代码现在长什么样**（唯一权威） | `architecture.md` | 改完代码**必须**回来同步；只写现状 |
| **为什么这么决策** | `docs/adr/`（索引在 `docs/adr/README.md`） | 决策发生时新增；Accepted 后不改，新的取代旧的 |
| **接下来做什么、做到哪了** | `BACKLOG.md` | 完成即更新状态，不删 |
| **踩过哪些坑 / 禁区** | `docs/hazards.md` | 踩坑时新增；编号只增不改 |
| 按日期的操作流水（可选第六类） | `journal.md` | 每轮收尾追加；只记流水与判据 |
| 给用户的说明书（装法、安全边界） | `README.md` | 改了功能就同步改；**不写进度、不写决策** |

**加载顺序是一圈闭环，不是单向读一遍**：

```
用户级 ~/.dsh/AGENTS.md → 本文件 → architecture.md → 相关 ADR → BACKLOG.md
        ↓
     动手改代码
        ↓
     把改完的现状**回写** architecture.md
        ↓
     新决策写 ADR / 做完的事在 BACKLOG.md 标完成 / 这轮的验证记进 journal.md
```

**规则**：

1. 改任何代码前先读 `architecture.md`，再读相关 ADR。
2. 新决策**必须**写一条 ADR；Accepted 之后不改，结论变了就新写一条取代它。
3. **任务来自 `BACKLOG.md`，不来自 ADR 标题**（ADR 只说为什么，不说该不该做、做到哪了）。
4. 改完代码**必须**同步 `architecture.md`，让它和代码一致。
5. `architecture.md` **只写现状** —— 未来计划进 `BACKLOG.md`，决策理由进 ADR，
   教训进 `docs/hazards.md` / `journal.md`。
6. **代码与文档不一致时直接改文档**（2026-10-07 用户口径）：代码是权威、文档是待检验的一方，
   该改就改、别逐次请示。三类例外仍然要停下来问：① 要改的是**代码行为**；
   ② 触碰**冻结内容**（Accepted ADR 正文/文件名）；③ 超出本次授权（别的仓、云上、用户的自留地）。
7. 发现 `architecture.md` / ADR / BACKLOG 互相矛盾 → 停下来问用户，不要脑补。

---

## 三条硬规矩

1. **`scripts/install.sh` 里不许写死 `$HOME/.wtool/...`。**
   源问引擎要 `WTOOL_PROJECT_DIR`（手跑按 `$0` 自推），落点从
   `WTOOL_HOME` / `WTOOL_PREFIX` 推。写死的后果是**报"install 完成"却什么都没装**
   （2026-10-04 实测：源钉在 `~/.wtool/wtool-work-dir/links/...` 这格引擎内部布局上，
   换 `WTOOL_HOME` 装就指丢，而检查是"找不到就跳过"）。
   **源找不到 = 只跳过那一条 + 打印去哪儿找了**，绝不整脚本静默退出；
   **只有真要装才 `mkdir`**（别留"空目录 + 指向它的软链"这种看着像装好了的东西）。
   回归测试在 `tests/run_tests.sh` 的 I 节。理由与完整决策见 ADR-007。

2. **别在真 `$HOME` 上跑 `scripts/install.sh` 或测试。**
   测试全部用临时的 `HOME` / `WTOOL_HOME` / `WTOOL_PREFIX` / `DSH_HOME` /
   `XDG_CONFIG_HOME` / `XDG_STATE_HOME`，跑完比对真 `$HOME` 的指纹。
   要手工试就照 I 节那样 `env HOME=$T/... sh scripts/install.sh`。

3. **我们自己的配置/日志不放 `~/.dsh`** —— 那是 DSH 自己的目录。
   配置在 `~/.config/dsh-remote/`（软链 → `$WTOOL_PREFIX/etc/dsh-remote`），
   日志在 `~/.local/state/dsh-remote/`（软链 → `$WTOOL_PREFIX/var/dsh-remote`）。
   **唯一例外**：`~/.dsh/profiles/web/cordis.patch.yml`（profile patch 只能放那儿）。
   见 ADR-009。

---

## 本项目特有的硬规矩（续）：`dsh web` 与云上

| 规矩 | 为什么 |
|---|---|
| **绝不改 `dsh web` 的绑定、绝不给它加 `--trusted-host`、绝不重启它** | 重启会打断正在跑的会话；绑 `0.0.0.0` = 把 RCE 挂公网（用户级 `~/.dsh/AGENTS.md` §5、ADR-005）。远程访问靠"隧道 + Caddy 改写 Host/Origin"（ADR-001、ADR-008），**不需要动 harness** |
| **云上（阿里云那台）的任何操作都要用户同意** | 那是用户的真机器。`cloud-install` 会 scp + ssh + `sudo sh relay.sh`（起容器、开端口）；助手不代跑，也不改安全组 |
| **`cloud/relay.sh` 在云上跑要 root + docker** | 它要 `docker compose up -d`、写 `/opt/dsh-relay/Caddyfile`、起 host 网络的容器；`--dry-run` 不需要 root。`--install-docker` 才会 apt 装 docker |
| **不跑 docker** | `tests/relay-e2e.sh` / `tests/caddy-validate.sh` 要 docker，**只写清怎么人工跑，不代跑**；`tests/run_tests.sh` 在**装了 docker 的机器上**它的 D 节会经 `relay.sh --dry-run` 调一次 `caddy validate`（见 hazards H8） |
| **真机安装要用户点头** | 本项目天生装在真机上才有用（手机连的就是这台机器），但用户级规矩（2026-10-04）是"wtool 的项目只在容器 / 影子家装、测"—— 助手不得自行 `wtool install tools/dsh-remote` |
| **钩子桥未证实会触发** | 不许把"会话卡住会推手机"写成已有能力；复查用 `dsh-remote check-hooks`（ADR-006、hazards H3） |

---

## README 是功能说明书，改了代码就同步改

`README.md` 是**给用户的完整功能说明书**（不是开发笔记）。对应关系：

| 改了什么 | 改 README 哪一节 |
|---|---|
| 加/改子命令、选项 | 「3. 命令」（`cloud-install` 的选项也在这里） |
| `scripts/install.sh`（装什么、装到哪、卸载撤什么） | 「2. 五步装好」第 0 步 / 「7. 占地与清理」 |
| `cloud/relay.sh`、`cloud/Caddyfile.*`、`cloud/docker-compose.yml` | 「4. 为什么这么设计」/「5. 安全边界」 |
| `hooks/claude-hooks.json`、`notify-enable` 行为 | 「4. 为什么这么设计」里的钩子那两段 |
| `tests/` 的条数或覆盖面 | 「6. 测试」 |
| 环境变量、路径约定 | 「2. 五步装好」/「7. 占地与清理」 |
| 命令/参数的**真实行为**（现状） | `architecture.md`（README 只写"给用户怎么用"） |

**README 与代码不一致 = 缺陷**，不是"以后补"。README 里**不写"怎么手工跑
`scripts/install.sh`"** —— 它是 `wtool install` 调的，安装只有一句话
（`wtool install tools/dsh-remote`）。README 里也**不写进度和决策**
（进度去 `BACKLOG.md`，为什么去 `docs/adr/`）。

---

## `wtool.xml` 要跟上引擎（它现在会硬报错）

- **`id=` 属性已经取消**（引擎 `wtool_plan.py` 硬报错，不留兼容窗口）：
  项目身份就是它相对工作区根的路径。`tools/dsh-remote` 这个属性是 2026-10-04
  端到端验证时发现并删掉的 —— 带着它会 `wtool install` 直接 exit 2，
  `scripts/install.sh` 根本没机会跑。
- 旧标签 `<env src= shells=>`（每次解析都告警）已改成
  `<zshrc src="env.zsh"/>` + `<bashrc src="env.bash"/>`；`<link src= dest=>` 同理。
- 改完跑 `wtool validate tools/dsh-remote`（只读）应打印 `ok: tools/dsh-remote`。

---

## 测试

```sh
cd tools/dsh-remote
sh tests/run_tests.sh         # 268 条（以跑出来的 PASS 行为准），秒级
                              #   不联网、不碰真 $HOME；连 python3；
                              #   ⚠️ 本机装了 docker 时 D 节会跑一次 docker run … caddy validate（hazards H8）
                              #   J 节用 DSH_REMOTE_UNIT_DIR + systemctl/tmux 桩，不碰真 unit / 真 tmux
sh tests/caddy-validate.sh    # 3 条，要 docker（caddy:2 镜像，本地没有会去拉）—— 人工跑
sh tests/relay-e2e.sh         # 9 条，要 docker + python3，会起容器再自己撤 —— 人工跑
```

`run_tests.sh` 逐节（2026-10-07 实测）：A 语法 10 / B `env.*` 等价 6 /
C `dsh-notify` 22 / D Caddyfile 渲染 27 / E 子命令 53 / F `cloud-install` 14 /
G `~/.dsh` 边界 8 / H `check-hooks` 6 / I 安装脚本 53 / J 常驻隧道 69 = **268**。
条数是手写的、会过期 —— **以跑出来的 PASS 行为准**。

⚠️ 两个要 docker 的脚本**没有 docker 时打印"跳过"并 `exit 77`**（跳过码）：
**77 是"没测"，不是通过**。以前是 `exit 0`（放进 CI / `&&` 链里空跑也算绿的假绿），
2026-10-07 改成 77（hazards H8）。

改了 `scripts/install.sh` / `env.zsh` / `env.bash` / `wtool.xml` **一定要跑
`tests/run_tests.sh`**（I 节守的就是"命令真装得出来、源找不到不装假"）；
改了隧道那三个子命令要跑 J 节（它同时守着"别碰真 `~/.config/systemd/user`
和真 tmux"—— 后者上面可能挂着生产隧道）。

---

## 已知缺口（别当成已经有能力）

**完整的"还剩什么"在 `BACKLOG.md` 的 U1–U9**；这里只列最容易被误当能力的：

- **hook 桥还没被证实会触发**（2026-09-21 实测：profile patch 挂上了，但
  `SessionStart`/`Stop`/`PreToolUse` 一个都没触发）。在证实之前，
  **不要把"会话卡住会推手机"写成已有能力**；`dsh-remote check-hooks` 是那条
  一次性复查命令（触发 → 0，没触发 → 1）。细节见 ADR-006 / `architecture.md` §9。
- **真机端到端只走通了一部分**（2026-10-07）：真阿里云中继 + 公网 8443 → 家里
  `dsh web` 走通了（带 basic auth 拿到家里 401 原文）；常驻隧道 `kill -9` 后
  **3.2s** 回来（实测，见 U3）。**还没验的**：真手机带 token 打开、真 Let's Encrypt、
  "网络真断"那条重连路、重启机器后会不会自动恢复。
- 真阿里云的安全组/防火墙、手机浏览器实测都**没有自动测**；`cloud-install` 只用假
  ssh/scp 验过参数拼装。
- **常驻隧道要 `loginctl enable-linger`** 才能跨登录会话/开机活着（本机 2026-10-07
  已开、实测不需要 sudo）；没开的话"登录会话一结束服务就停"。见 hazards H15。

---

## 交付方式：改动只提交到 `ds_dev`，合不合由人决定

> 完整规则在 `~/.dsh/AGENTS.md` §1 和仓库根 `AGENTS.md`，这里只写这个仓要注意的。

- **分支**：动手前 `git rev-parse --abbrev-ref HEAD` 必须打印 `ds_dev`；
  **不 push、不动 `main`**（`main` 上只有 `94eb8b7 Initial empty repository`）。
- **提交**：一律带 `-m` / `-F`（裸 `git commit` 在非交互 shell 里会**静默失败**）；
  `git add` 之前先 `git diff` 看一遍（见到 `【wsw: …】` 批注必须读并照做，
  改完把批注本身删掉，别提交进去）。
- **多个代理同时干一个仓 → 先串行化；提交用 pathspec 形式**（2026-10-07 实测踩到：
  `git commit` 提交的是**整个索引**，别的代理几秒前 `git add` 的文件会被一起带进来）：

  ```sh
  git commit -F /tmp/msg -- <自己的文件…>
  git show --stat HEAD        # 提交后核对实际内容
  ```

  万一被卷进去 → **不许改历史**（不 amend / 不 reset），在 `BACKLOG.md` 里如实记账。
- 文档类改动**要和它描述的对象在同一个提交里**（代码 + architecture + BACKLOG…），
  别把"改了代码没回写文档"留到下一轮。

## 仓库里的文件

| 路径 | 是什么 |
|---|---|
| `architecture.md` | **现状**（唯一权威） |
| `docs/adr/` | 决策记录（索引在 `docs/adr/README.md`） |
| `docs/hazards.md` | 坑与禁区（H1…，编号只增不改） |
| `BACKLOG.md` | 接下来做什么、做到哪了（U1–U9） |
| `journal.md` | 按日期的操作流水（可选第六类） |
| `README.md` | 给用户的说明书 |
| `bin/`、`cloud/`、`hooks/`、`scripts/`、`tests/`、`env.*`、`wtool.xml`、`*.example` | 代码与配置样板 |
