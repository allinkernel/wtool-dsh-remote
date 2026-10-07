# ADR-0017：dsh web 常驻化（开机自启）+ `harness` 复用 + 会话起来后重连隧道

- 状态：Accepted（2026-10-07）
- 相关：ADR-0013（隧道常驻用 systemd --user）、ADR-0014（固定手机入口 + broker）、ADR-0015（一条命令装好）
- 取代：无（新增）

## 背景（用户 2026-10-07 的要求）

> "整个系统上，开机的时候系统自动执行 harness 打开一个 dsh 会话，后续再执行的时候就不打开新会话了，
> 而是继续使用老的已经打开的会话。然后 dsh-remote 在 harness 启动后自动触发重连到阿里云服务器转发。"

现状（改之前）：`harness` 是**前台**跑 `npx @deepseek-ai/dsh web` 并抓 token；关掉终端会话就没了，
而且**退出时会把 token 文件删掉**（broker 随即 503）。隧道 / broker 倒已经是 systemd --user 常驻
（ADR-0013），但"家里那头的 dsh web"没人常驻 —— 开机后隧道和 broker 都活着，却没有会话可转发。

## 决定

1. **新增 `dsh-web.service`（systemd --user）**：`ExecStart` 跑 `bin/dsh-web-run`（项目里的包装脚本），
   `Restart=always`、**`RestartSec=30`**、`WantedBy=default.target`（配合 `loginctl enable-linger` 开机即起）。
   命令：`dsh-remote serve-install / serve-status / serve-uninstall`。
2. **`dsh-web-run` 与 `harness` 分工**：
   - `dsh-web-run`：给 systemd 用 —— 前台跑 `npx dsh web`、抓 token、写 `current-token.txt`/`web-url.txt`，
     **退出不删 token**（服务要一直活着；重启会覆盖）。
   - `harness`：给人用 —— **① 已经有会话在跑 → 复用**（打印带 token 的本地地址 + 手机固定地址，不起第二个）；
     **② 装了服务但没跑 → `systemctl --user start --no-block` 交给它**并等地址；
     **③ 没装服务 → 退回原来的前台行为**。逃生阀 `DSH_REMOTE_HARNESS_NO_REUSE=1` 跳过 ①②。
3. **端口被占时不抢**：`dsh-web-run` 发现 `local_port` 已有人听 → 打印说明、**退出 1**；
   systemd 按 `RestartSec=30` 重试 —— 等用户手起的那个会话结束，服务自然接管。**绝不打断在跑的会话**。
4. **重连隧道放在"真抓到 token"之后**（在 `dsh-web-run` 里），**不是** systemd 的 `ExecStartPost`。

## 为什么第 4 条这么定（实测踩过）

第一版把 `ExecStartPost=-systemctl --user try-restart dsh-tunnel.service` 写进单元。看着对，
实际是错的：**"端口被占 → 本服务立刻退出 → 每 30 秒重试"这种失败尝试里，`ExecStartPost` 也会跑**
→ 隧道被每 30 秒重启一次，手机链路跟着断（实测看到 `dsh-tunnel.service` 的
`ActiveEnterTimestamp` 在 web 服务重试时被刷新）。改成在 `dsh-web-run` 里、
**只有解析到 token 那一段**才 `try-restart`，语义才真的对上"会话起来了再重连"。
回归守卫：`tests/run_tests.sh` O 节断言渲染出的单元里**没有**行首 `ExecStartPost=`。

## 后果

- 好处：开机即有会话；`harness` 幂等（不再可能起第二个、不再一退出就让手机入口 503）；
  手机链路只在"会话真的换了"时才重连。
- 代价/风险：多一个常驻服务与一个包装脚本；`dsh-web-run` 里带 `systemctl` 调用（有 `command -v` 守卫，
  并可用 `DSH_REMOTE_NO_TUNNEL_RESTART=1` 关掉，测试就是这么跑的）。
- 可回退：`dsh-remote serve-uninstall`（停服务 + 移走单元，**不动在跑的会话**）；
  `harness` 的 ①② 都可由 `DSH_REMOTE_HARNESS_NO_REUSE=1` 旁路 → 行为退回改之前。
