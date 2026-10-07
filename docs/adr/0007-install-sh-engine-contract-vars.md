# ADR-007 `scripts/install.sh` 只认引擎契约变量；源找不到 = 只跳过那一条

**状态**：Accepted（2026-10-04，`f8da57c`；2026-10-07 补记为 ADR）。

**背景**：改之前，`scripts/install.sh` 把"源"写死成
`$HOME/.wtool/wtool-work-dir/links/tools/dsh-remote` —— 那是**引擎的内部布局**
（`bootstrap/lib/wtool_plan.py` 的 `WORK_DIR_NAME`），而且用的是字面量 `$HOME`。
后果是换 `WTOOL_HOME` 装（影子家 / 临时家 / 测试）时源一定指丢，而脚本的检查是
"源不存在就 `continue`" —— 于是**报"install 完成"却什么都没装**：命令一条没有、
配置/日志却铺了空目录软链，装完看起来和装好了一模一样（完整现象在 `BACKLOG.md`）。
同一个病在 `tools/android_repack`（`14bf463`）和 `harness/dsh-conf`（`977101b`）上修过，
这里是最后一处。

**决策**：

- **源**问引擎的契约变量要：`${WTOOL_PROJECT_DIR:-<按 $0 自推>}`；
- **落点**从 `WTOOL_HOME` / `WTOOL_PREFIX` 推（`prefix` 默认 `$home/.wtool/usr`），
  XDG 的默认值也从 `WTOOL_HOME` 推；**落点不认** `DSH_REMOTE_CONF_DIR` /
  `DSH_REMOTE_STATE_DIR`（那是**运行期**变量，装过一遍的人 shell 里一定有，
  认它就会把软链铺到别处）；
- 某条源找不到 = **只跳过那一条** + 打印"找的地方：…（来自 WTOOL_PROJECT_DIR /
  按脚本位置自推）"，末尾交代跳过了几条；**整脚本仍然 `exit 0`**；
- **只有真要装才 `mkdir`** —— 源找不到时一个字节都不写，连"空目录 + 指向它的软链"
  那种看着像装好了的东西也不留；
- `env.zsh` / `env.bash` 单独 source 时的兜底同样从 `${WTOOL_HOME:-$HOME}` 推。

**理由**：一个项目的源找不到不该把整个 `wtool install` 拉下水（所以不 `die`）；
但"半装 + 报成功"比直接报错更坏（所以必须大声跳过 + 什么都不写）。
写死引擎内部布局 = 给自己留第二份真相，引擎挪一次布局就坏一次。

**否决**：

- 继续用引擎的内部中转链接当源（两份真相，2026-09-23 已经挪过一次）；
- 源找不到就整脚本退出（一个项目拖垮整轮安装）；
- 源找不到静默跳过（就是这次的病）；
- 让 `install.sh` 自己去算中转链接路径（等于重新实现引擎）。

**后果 / 判据**：回归测试是 `tests/run_tests.sh` 的 **I 节（53 条，五个场景：
引擎调用 / 手工跑 / 换 `WTOOL_HOME` / 源找不到 / `--uninstall`）**，
外加两条 `grep -F` 断言守着三个脚本里不出现 `$HOME/.wtool/...` 字面量；
反证：拿改前的脚本跑同一份用例 = **148 通过 31 失败**。
