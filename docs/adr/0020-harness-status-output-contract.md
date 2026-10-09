# ADR-0020：`harness` 的输出契约 —— 第一行永远是"状态 + 为什么"，原因必须实测

- 状态：Accepted（2026-10-09）
- 相关：ADR-0014（固定地址 + `harness` 抓 token）、ADR-0017（dsh web 常驻 + 复用三步）、
  ADR-0018（cookie 判断挪进 broker）、hazards H22（token 只在内存里）、H28（坏代理）
- 取代：无（新增）。**收窄 ADR-0017 的"三步"**：那三步的**行为**不变（复用 / 交给服务 /
  回退前台），本条只重做它们的**输出**，并给"等 systemd"加上显式、有限、有结论的等待。

## 背景（2026-10-09 用户原话）

> "`harness` 命令打印的废话太多……**明确地指出：dsh 服务到底起来没有；没起来的原因是什么**
> （是后台 systemd 已经自动起来了？还是一直在等待远端？）"

现场就是这样：本机 `dsh-web.service` 长期 `activating`（`SubState=auto-restart`，
`NRestarts` 一百多次），而 3080 上跑着的是用户手起的 `npx dsh web`。旧输出在这样的机器上
只会说：

```
[dsh-remote] 交给常驻服务 dsh-web.service …
[dsh-remote] 还没写出地址（可能端口被别的会话占着，服务会每 30 秒重试）
[dsh-remote] 看：journalctl --user -u dsh-web.service -n 20
```

三行里没有一个字是**这一次实测**出来的：没说端口上是谁、PID 多少、systemd 现在什么状态、
重试了几次、为什么"没写出地址"。用户读完仍然不知道"到底起来没有"。

## 决定

1. **输出契约**：`harness` 正常 **2–5 行**，每行都要有信息量；**第一行永远是状态**：

   ```
   harness: dsh web 已在跑 ✓  http://127.0.0.1:3080（PID 152050，非 systemd）
   harness: dsh web 已由 systemd 拉起 ✓  http://127.0.0.1:3080/?token=…（PID 152051，dsh-web.service）
   harness: dsh web 没起来 ✗ 原因：<实测出来的那一条>
   harness:   判据：<自己复现这个结论的命令>
   ```

2. **四态 + 两条，覆盖全部分支**（详细判据写进 `architecture.md` §3.5.1）：
   ① 服务在跑（systemd 托管）② 端口被**非 systemd** 实例占着（服务因此 `activating`/`failed`）
   ③ 服务 `failed` ④ 没有服务 → 走前台；外加"刚被 systemd 拉起（成功）" 与
   "等超时（原因 + 判据）"。
3. **原因不许猜，全部来自实测**：
   - 谁占着端口 → `ss -ltnp` 的 `pid=`；拿不到就写"PID 拿不到"，**不编**；
   - 是不是 systemd 管的 → `MainPID` 比对 **以及** `/proc/<pid>/cgroup` 里有没有单元名；
   - 服务状态 → `systemctl --user is-active` + `show -p SubState/NRestarts/ExecMainStatus/RestartUSec`；
   - 失败原因 → `journalctl --user -u … -o cat -n 1` 的**最后一行原文**（照抄，不总结）；
   - 别人那个实例的 token 能不能用 → 拿真请求探一次 `GET /?token=<值>`（303/200 才算有效，
     401 就是失效，H22：正在跑的实例 token 只在它内存里）。
4. **等待必须显式且有限**：开始等之前打 `harness: 等 systemd 写出地址（最多 20s）…`；
   结束**必有结论行**（成功给地址 / 失败给原因）。上限可用 `DSH_REMOTE_HARNESS_WAIT=<秒>` 调
   （默认 20；测试用它把超时那条跑快）。
5. **"地址是这次写的"不能只看 mtime**：文件时间戳用粗粒度时钟，同一次 tick 里写两个文件会
   拿到一模一样的 mtime（`test -nt` 假阴性，2026-10-09 在测试里实测到）。判据取
   "比起点标记新 **或** 内容变了"。
6. **行为不动**：`DSH_REMOTE_HARNESS_NO_REUSE=1` 仍走前台；没装单元仍走前台；
   token 落盘规则（含"没抓到就不许删别人的 token 文件"）一个字不改。

## 理由

- 用户要的是**判定**，不是"过程叙述"：状态行 + 原因行才能一眼看完；
- 判据命令放在输出里，用户/下一个助手**不必信我们**，复制一条就能自己复核
  （这是本仓库"H 系列 hazard 必须配可复现命令"的同一条纪律）；
- 原因全部实测 → 输出与 `dsh-remote serve-status` / `tunnel-status` 的口径一致，
  不会出现"harness 说 A、status 说 B"。

## 否决

- **"最短化"（只打一行状态）**：用户明确说"不许压行、不许为了短而丢原因"；
  端口被占时不给 PID/接管办法，用户下一步还是得自己查。
- **只比 `web-url.txt` 存不存在**（旧行为）：旧文件会把"上一次的地址"冒充成"刚起来"，
  这正是"看不出来起来没有"的来源；现在要求"这次刚写的"。
- **失败时返回非 0 退出码**：会让 `dsh-remote server` 的 `exec … harness` 那一步变成失败
  语义，而"服务没起来但别人的实例在跑"并不是命令失败。维持恒 0。
- **把原因判断放进 `dsh-remote` 的子命令里让 harness 去调**：shell 函数在用户交互 shell 里
  跑，多一层进程通信不值得；探测都是只读的几行 shell，放 env 里（`_hr_*`）最直接。

## 判据 / 后果

- 回归：`tests/run_tests.sh` O 节 —— `systemctl`/`journalctl` 桩 + 真回环监听，
  **四态 bash/zsh 各跑一遍同一张表**（态②还断言"原因是实测的 PID"、态②b 断言
  "token 实测有效才打出来"、态⑥断言"旧 `web-url.txt` 不许当成刚起来"）。
- 现场判据（本机，只读）：

  ```sh
  bash -c '. ~/self/wtool/tools/dsh-remote/env.bash; harness'
  # → harness: dsh web 没起来 ✗ 原因：3080 被另一个实例占着（PID 152050，不是 systemd 管的）
  systemctl --user is-active dsh-web.service      # activating
  ```
