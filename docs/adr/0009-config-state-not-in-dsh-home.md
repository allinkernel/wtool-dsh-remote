# ADR-009 我们自己的配置/日志不放 `~/.dsh`

**状态**：Accepted（早于初版提交 `13734e3` —— 初版就带 `dsh-remote migrate`
子命令，专门把旧版放在 `~/.dsh` 下的配置/日志搬出来；2026-10-07 补记为 ADR）。

**背景**：`~/.dsh` 是 **DSH 自己的**目录（会话、storages、凭据这些都在里面）。
初版把 `remote.conf` / `notify.conf` / 日志也放在那儿，和 DSH 的东西混在一起：
谁的、能不能删、卸载时撤哪些都说不清。

**决策**：自己的东西放标准 XDG 位置，实体放 `$WTOOL_PREFIX` 下面再用软链引出来：

| 落点 | 是什么 |
|---|---|
| `$WTOOL_PREFIX/etc/dsh-remote/`（`~/.config/dsh-remote` 是软链） | 配置实体：`remote.conf` / `notify.conf` / `hooks.json` / 两份 `*.example` |
| `$WTOOL_PREFIX/var/dsh-remote/`（`~/.local/state/dsh-remote` 是软链） | 日志与运行期：`notify.log` / `web.log` / `web-url.txt` / `cloud-install.log` |

**唯一例外**：`$DSH_HOME/profiles/web/cordis.patch.yml` —— DSH 规定 profile patch
只能放在它自己的目录里，这个改不了（ADR-006）。

**理由**：

- 目录归属清楚：`~/.dsh` 里只有一样东西是我们的，一眼看得出来；
- 实体在 `$WTOOL_PREFIX` 下 → `wtool uninstall` 撤得干净、`wtool list` 看得见、
  别的机器上装出来布局一样；
- 符合用户级规矩（`tools/dsh-remote/AGENTS.md` 硬规矩 3）。

**否决**：

- 继续放 `~/.dsh`（谁的目录分不清，卸载不敢动）；
- 直接放 `~/.config` / `~/.local/state` 当实体（`$HOME` 里就只剩软链这条规矩被破坏，
  而且 `WTOOL_HOME` 换到影子家时落点跟不过去）；
- 放仓库里（运行期数据和机密不进 git）。

**判据 / 迁移**：

- `tests/run_tests.sh` G 节断言：`~/.dsh` 里只有 `profiles`，
  配置目录里只有我们自己的三个文件；`notify-enable` 在临时 `HOME` 里跑，
  不许往真 `~/.dsh` 写。
- `dsh-remote migrate` 负责把旧位置（`$DSH_HOME` 下的那几个文件）搬过来，
  目标已存在就不覆盖，并提醒重跑 `notify-enable` 更新 patch 里的 `configPath`。
