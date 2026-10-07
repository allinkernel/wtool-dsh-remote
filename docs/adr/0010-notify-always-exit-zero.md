# ADR-010 `dsh-notify` 的退出码永远是 0

**状态**：Accepted（2026-09-20 随初版 `13734e3` 落地；2026-10-07 补记为 ADR）。

**背景**：`dsh-notify` 会挂在 hook 桥的 `PreToolUse` 上。Claude Code 的钩子协议里
**退出码 2 = 阻止这次工具调用**；其它非 0 退出码也会让钩子 runner 把这步当失败。
而推送失败的原因基本都是外部的：没网、key 过期、Server酱/钉钉抽风、配置没写。

**决策**：

1. **所有失败路径都 `exit 0`** —— 配置不存在、`provider` 不认识、`SENDKEY` 没填、
   `curl` 失败……一律只往 `$STATE_DIR/notify.log` 写一行，然后正常退出。
2. 钩子里用 `--async`：`( push … ) </dev/null >>"$LOG" 2>&1 &` 之后父进程立刻
   `exit 0`；**子进程的 stdin/stdout/stderr 三个 fd 全部重定向走**。
3. 不给"推送失败"设计任何非 0 的对外信号 —— 要看失败就读日志。

**理由**：

- 推送是**旁路**：它失败不该影响 agent 干活，更不该把用户的工具调用拦掉；
- `--async` 是为了让钩子不阻塞：钩子 runner 会等子进程的管道 EOF，
  只 `&` 不重定向 fd 的话 `--async` 就是摆设（agent 照样被拖住），
  这条踩过一次（hazards H2）；
- 退出码只有 0 和"协议错误码"两种语义，混用会让 debug 变成猜谜。

**否决**：

- 用非 0 退出码报告推送失败（会拦工具 / 让钩子算失败）；
- 失败时弹窗或写 stdout（hook 的 stdout 会被协议当数据）；
- 同步推送（一条网络请求 20s 上限，会明显拖慢工具调用）。

**判据**（`tests/run_tests.sh` C 节，都是真跑）：

- `DSH_NOTIFY_CONF=<不存在的文件> dsh-notify x y` → 退出 0；
- `provider=不存在的渠道` → 退出 0，且日志里有"不认识的 provider"；
- `--hook --async` 必须在 **≤2s** 内返回，而且消息最后照样到达本地接收端；
- 普通推送 / `--test` / `--hook` 的退出码都是 0。
