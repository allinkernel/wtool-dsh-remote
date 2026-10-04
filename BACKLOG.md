# BACKLOG —— tools/dsh-remote

> 这个文件是这个项目"接下来做什么、做到哪了"的**唯一权威**。
> 引擎/跨项目的事在 `~/self/wtool/harness/BACKLOG.md`，别混。
>
> 状态：⬜ 待做 · 🔄 在做 · ✅ 做完（写清怎么做的、验证到什么程度）· ⏸ 待决定（要人来拍）

---

## ✅ install.sh 写死引擎内部布局 —— "报成功却什么都没装"（2026-10-04 修）

**现象**（临时环境里实测复现，改前的脚本）：

```
tools/dsh-remote: 警告：找不到 .../home/.wtool/wtool-work-dir/links/tools/dsh-remote/bin/dsh-remote（wtool 的稳定链接还没建好？）
tools/dsh-remote: 警告：找不到 .../home/.wtool/wtool-work-dir/links/tools/dsh-remote/bin/dsh-notify（wtool 的稳定链接还没建好？）
tools/dsh-remote: 软链 .../xdg-conf/dsh-remote -> .../prefix/etc/dsh-remote
tools/dsh-remote: 布局：
tools/dsh-remote:   命令      .../prefix/bin/{dsh-remote,dsh-notify}
...
（exit 0）
$ ls -l .../prefix/bin
total 0                                  ← 一条命令都没有
```

它还会把**空目录**的配置/日志软链铺好、打一份"布局"总结 —— 装完看起来和装好了
一模一样，`wtool` 那边照样报 `install 完成`。这台机器上的现状正好是这个病的活标本：
引擎现在的 `~/.wtool/wtool-work-dir/links/` 根本不存在，而 `~/.wtool/usr/bin/` 里
那两条 Sep 20 的软链还指着**更老**的一格 `~/.wtool/links/tools/dsh-remote/bin/*`。

**根因**：`scripts/install.sh:31` 把"源"写死成引擎的内部布局
`link_dir="$HOME/.wtool/wtool-work-dir/links/tools/dsh-remote"`
（`bootstrap/lib/wtool_plan.py` 的 `WORK_DIR_NAME`），第 96/112 行拿它当源。
两种情况下立刻指丢：① `WTOOL_HOME != $HOME`（影子家 / 临时家 / 测试）—— 中转链接
建在 `$WTOOL_HOME/.wtool/...`，脚本却去真家目录那格找；② 引擎以后再挪一次那一格
（2026-09-23 已经挪过一次，`tools/android_repack` 就是在那一挪之后坏掉的）。
而检查是"源不存在就 `continue`"，于是整轮静默跳过。
同一个病在 `tools/android_repack`（`14bf463`）和 `harness/dsh-conf`（`977101b`）
上修过 —— **这是最后一处**。

**改动**（`7388984` 之后的新提交，都在 `ds_dev` 上）：

1. `scripts/install.sh`：
   * 源 = **`WTOOL_PROJECT_DIR`**（引擎对项目脚本的契约，见 `bootstrap/wtool.sh` 的
     `wt_run_project_script`：`export WTOOL_PROJECT_DIR="$_rs_dir"`），手跑时按 `$0`
     自推 `<项目>/scripts/..`；
   * 落点 = `WTOOL_PREFIX`（默认从 `WTOOL_HOME` 推）、`~/.config` / `~/.local/state`
     的默认值也从 `WTOOL_HOME` 推（XDG 显式设了就用 XDG）；
   * 某条源找不到 = **只跳过那一条** + 打印"找的地方：…（来自 WTOOL_PROJECT_DIR）"，
     末尾还要交代跳过了几条；只有真要装才 `mkdir`（源找不到时连空目录都不建）；
   * 往 `$WTOOL_PREFIX/bin` 里放东西时，**已存在且不是软链就警告跳过**，不覆盖。
2. `env.zsh` / `env.bash`：单独 source 时的兜底从写死 `$HOME/.wtool/...` 改成
   `${WTOOL_HOME:-$HOME}/.wtool/...`（同一个病：换影子 HOME 就指错）。
3. `tests/run_tests.sh` 新增 **I 节**（五个场景，见下）。
4. `README.md`（§2 第 0 步、§4 新增一段"安装脚本为什么不自己拼路径"、§6 测试、
   §7 占地与清理重写；顺手订正了三处过期路径：`hooks.json` 在配置目录、
   `web-url.txt` / `notify.log` 在 state 目录）、新建本仓库的 `AGENTS.md` / `BACKLOG.md`。

**复现**（临时环境，不碰真 `$HOME`；`$T` 是临时目录）：

```sh
# 改前：源写死在 $HOME 下的影子 HOME，换 WTOOL_HOME 就找不到
HOME=$T/home WTOOL_HOME=$T/home WTOOL_PREFIX=$T/prefix WTOOL_PROJECT_DIR=$PWD \
  XDG_CONFIG_HOME=$T/conf XDG_STATE_HOME=$T/state sh scripts/install.sh
#   → 警告两条 + exit 0 + $T/prefix/bin 是空的
# 改后：同样一条命令 → 已链接 $T/prefix/bin/dsh-remote -> <项目>/bin/dsh-remote（两条都装）
```

**验证到什么程度**：

* `sh tests/run_tests.sh` → **179 通过 0 失败**（改前基线 **126** 条，本次 +53）。
  I 节全部用临时 `HOME` / `WTOOL_HOME` / `WTOOL_PREFIX` / `DSH_HOME` /
  `XDG_CONFIG_HOME` / `XDG_STATE_HOME`，五个场景：
  ① 引擎调用（`WTOOL_PROJECT_DIR`；引擎内部那格故意埋一份**假的**可执行文件，
  还从那儿取源就会挂）② 手工跑按 `$0` 自推（cwd 在别处 / 相对路径两种）
  ③ 换 `WTOOL_HOME` 装到别处（落点跟它走，真 `$HOME` 一个东西都不多）
  ④ 源找不到（只跳过、说清去哪儿找、**一个字节都不写**）⑤ `--uninstall` 撤干净
  （软链撤掉、配置/日志实体留着）。跑完比对真 `$HOME` 的指纹
  （`.zshrc` / `.bashrc` / `.config/dsh-remote` / `.local/state/dsh-remote`，
  `stat -c '%F|%s|%Y'`）**逐字不变**；另有 `grep -F` 断言守着
  "`scripts/install.sh` / `env.zsh` / `env.bash` 里不许出现 `$HOME/.wtool/...` 字面量"。
* **反证**（证明这 53 条不是永远绿的摆设）：把改前的 `scripts/install.sh` /
  `env.zsh` / `env.bash`（`git show HEAD:...`）放进仓库副本，用**同一份新用例**
  跑 → **148 通过 31 失败**（exit 1）。挂掉的正是 I 节那批（命令没装出来、
  软链指到埋的假链接、`$WTOOL_HOME` 场景全挂、源找不到时还铺了空目录软链、
  `grep -F` 三条）。
* **引擎端到端**（全临时环境：`HOME` / `WTOOL_HOME` / `WTOOL_STATE` / `WTOOL_ROOT`
  全指临时目录，`env -i`）：`wtool install tools/dsh-remote` → exit 0，
  `$WTOOL_HOME/.wtool/usr/bin/{dsh-remote,dsh-notify}` 指向临时工作区里的项目目录，
  配置/日志软链 + 两份样板都到位；`dsh-remote help` / `status` 退出 0；
  `wtool uninstall tools/dsh-remote` → 软链撤掉、实体留着。
* 真 `$HOME` 没被碰：11 条真路径（rc 文件、两条配置软链、`~/.wtool/usr/...`）
  在**整轮测试 + 上面那些临时实验**前后 `stat` 逐字相同。

**还剩什么**：

* ⏸ 这台机器上那两条 **Sep 20 的老软链**（`~/.wtool/usr/bin/dsh-remote` →
  `~/.wtool/links/tools/dsh-remote/bin/dsh-remote`，老布局）还留着。
  修好之后重跑一次 `wtool install tools/dsh-remote` 会把它们纠正到新落点 ——
  **这是用户自己在真 `$HOME` 上跑的动作，助手不代跑**（当前 `dsh-remote` 走
  `~/.local/bin/dsh-remote` → 工作树，所以命令本身是可用的）。
* ⏸ 要不要让"找不到源"变成**真失败**（`exit 1`）而不是警告 + 继续：现在选的是
  "警告 + 继续 + 末尾交代跳过了几条"，因为脚本失败会把整个 `wtool install`
  拉下水；坏处是它仍然是"半装"。三个仓库现在口径一致（都选了警告）。
* ⏸ `main` 与 `ds_dev` 的差距要不要合 —— 由用户定（助手不合并、不推送）。

---

## ✅ `wtool.xml` 跟上引擎：`id=` 已取消 + `<env>` 旧标签（2026-10-04 修）

**怎么发现的**：做上面那条的**引擎端到端**验证时，`wtool install tools/dsh-remote`
直接 `exit 2`：

```
wtool: error: wtool.xml 里的 id='tools/dsh-remote' 已经取消：项目身份就是它相对工作区根的路径。
       删掉这个属性即可（.../wtool.xml）
```

`id=` 是**硬报错**（`bootstrap/lib/wtool_plan.py:214-219`，用户 2026-10-04 拍板，
不留兼容窗口）—— 带着它，`scripts/install.sh` **根本没机会跑**，上面那条修复
也就用不上。工作区里其它项目（`android_repack` / `dsh-conf` / `astronvim_v5` /
`git-repo-sh-tools` …）都已经删掉了，只剩 `tools/dsh-remote` 和 `terminal/tmux`。

**改动**：`wtool.xml` 删掉 `id="tools/dsh-remote"`；顺手把旧标签
`<env src= shells=>`（每次解析都告警）换成 `<zshrc src="env.zsh"/>` +
`<bashrc src="env.bash"/>`（和别的项目一致，`env.zsh`/`env.bash` 两份不变）。

**验证**：`wtool validate tools/dsh-remote` → 改前 `error: ... id=... 已经取消`（exit 1），
改后 `ok: tools/dsh-remote`（exit 0，无告警）；随后上面那套引擎端到端跑通。

**还剩什么**：

* ⏸ `terminal/tmux/wtool.xml` 有**一模一样的两个问题**（`id=` + `<env>`）——
  那是另一个仓库，本次不动；`tools/gerrit-gate` 用户明确说不动（已废弃）。

---

## ⏸ 待决定：真阿里云那台要不要现在装

跟本次修复无关，但别忘：云端 Caddy / 隧道 / 钩子桥都还没在这台机器上真跑过
（`cloud-install` 只测了参数拼装）。**hook 桥"挂上了但没被证实会触发"** 是
README §4 里那条已知缺口，`dsh-remote check-hooks` 是复查命令。
要不要装、什么时候装，用户定。
