#!/bin/sh
# run_tests.sh —— tools/dsh-remote 的用例（**不联网、不碰真 $HOME**）
#
# ⚠️ 它**会碰 docker**：本机装了 docker 时，D 节经 `cloud/relay.sh --dry-run`
#    会真跑 `docker run --rm caddy:2.11.4 caddy hash-password / caddy version /
#    caddy validate`（镜像不在本地会去拉，约 50MB）。别的节不碰 docker。见 hazards H8。
#
#   sh tests/run_tests.sh         # 全跑
#   sh tests/run_tests.sh -v      # 每条都打印
#
# 覆盖：
#   A 语法（dash/bash 两种解释器都过一遍 —— 别把 bashism 放过去）
#   B env.zsh / env.bash 等价
#   C dsh-notify：真发一条到本地 HTTP 接收端；退出码永远是 0；--hook 解析；
#     --async 不拖住钩子；on_stop 开关
#   D cloud/relay.sh 的渲染：占位符替换干净、host/origin 改写、
#     basic_auth、allow-ip、参数校验
#   E dsh-remote 子命令：help/未知命令/status/notify-enable/notify-disable 幂等
#     （help 不越界、status 提示的落点是我们自己的目录 —— H9/H10）
#   F cloud-install（假 ssh/scp）
#   G 目录边界：自己的东西不放 ~/.dsh
#   H check-hooks
#   I 安装脚本：源问 WTOOL_PROJECT_DIR 要（手跑按 $0 自推）、落点从
#     WTOOL_HOME/WTOOL_PREFIX 推、换 WTOOL_HOME 装到别处、源找不到不建悬空链、
#     --uninstall 撤干净 —— 全程临时 HOME（跑完比真 $HOME 的指纹）
#   J 隧道常驻：systemd 单元渲染（Restart=always/保活参数/journald/**防风暴三个键**）、
#     daemon-reload + enable --now 的调用、幂等、旧 tmux 会话抢端口的检测与停掉、
#     用户管理器不可用时"还没动旧隧道就停手"、tunnel-status 的漂移检测、卸载；
#     **自愈件（内部件）**：脚本落点/可执行/sh -n/内容、两个单元、timer 被 enable、
#     拿假端口真跑一遍脚本（rc 非 0 且调用了 restart）、--no-watch 不写、卸载撤三件
#     —— 单元落点用 DSH_REMOTE_UNIT_DIR、脚本落点用 DSH_REMOTE_LIB_DIR 钉到临时目录，
#     systemctl/tmux/ssh/logger 全是桩（真 tmux 上可能正跑着生产隧道），
#     跑完比真 ~/.config/systemd/user 与真 ~/.local/lib/dsh-remote 的指纹
#   K token 重定向（固定地址那半）：Caddyfile 两份模板的 @entry 只按 token 排、
#     不按 cookie 排；broker 起真进程 + **假 dsh web 夹具**（tests/fake_dsh_web.py，
#     按 cookie 的值造 401/200/303/500/慢响应）验：过期 cookie → 302 + 清 cookie、
#     有效 cookie → 代发首页 200（探测+代发恰好两条请求）、3xx 指回入口 → 换 token
#     跳转、判断不出 → 503、没有 token 文件 → 503（ADR-0018）
#   L 二维码（矩阵对账 / PNG / SVG / 终端画）
#   M server（一条命令装好：自检失败指引、--dry-run 不写、部署失败不能吞）
#   N passwd（改密码：只换那一行哈希、只 restart、新密码 302 旧密码 401）
#   O dsh web 常驻 + **harness 的新语义**（2026-10-09 用户重做；ADR-0024）：
#     "有则开、无则起、绝不起第二个、不等待"—— 单元渲染 / 端口被占不抢 /
#     **六种情形**各一条：端口有人听（手工起的）／端口有人听且是 systemd 托管／
#     有带 token 的 web-url.txt 就开那个／没人在听但有单元（start 后端口出现）／
#     没人在听也没单元（前台 npx：端口一出现就开浏览器 + 参数原样透传 + token 抓/清）／
#     命令行换了端口（不拿服务去顶）。断言里有两条硬判据：
#     ① **那个端口上的 PID 前后不变**（证明没起第二个）；② 桩 opener 收到的第一个参数
#     **逐字节**等于完整 URL、argc=1（证明 URL 没经 shell 被糟蹋）。
#     外加 opener 三档退（指定命令缺失 / quiet / 空）+ **dsh-web-run 的代理处理**
#     （桩 npx 把子进程的 `env | grep -i proxy` dump 出来对账）。
#   Q harness-remote（云上那半的薄封装）：--help 说清"本地那半是 harness"；
#     status 压成 ≤6 行（隧道/broker/web/入口/容器/结论，数据来自
#     `tunnel-status --probe` + `force-restart-dsh-remote --json` 两条现成输出）；
#     open 用同一个 opener（桩断言 argv 逐字节）；reset 走安全档且**拒绝** --restart-web；
#     passwd 原样转发；url/qr；参数写错要指路 —— 全程桩 dsh-remote，绝不碰云上。
#
# 要 docker 的两条在 tests/ 下单独放：caddy-validate.sh（3 条）、relay-e2e.sh（9 条）。
# 它们**没有 docker 时 exit 77**（跳过码）—— 别把 77 当通过（H8）。

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
proj=$(CDPATH= cd -- "$here/.." && pwd)
pass=0
fail=0
verbose=0
[ "${1:-}" = "-v" ] && verbose=1

ok() {
    pass=$((pass + 1))
    [ "$verbose" = 1 ] && printf '  ok   %s\n' "$1"
    return 0
}
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    [ -n "${2:-}" ] && printf '       %s\n' "$2"
    return 0
}

# check <描述> <期望> <实际>
check() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望 [$2] 实际 [$3]"; fi
}
# check_contains <描述> <针> <草堆>
check_contains() {
    case $3 in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "在输出里找不到 [$2]" ;;
    esac
}
check_not_contains() {
    case $3 in
    *"$2"*) bad "$1" "输出里不该有 [$2]" ;;
    *) ok "$1" ;;
    esac
}

TMP=$(mktemp -d)
PATH_BASE=$PATH          # 原始 PATH：每一节跑测试前从它重建，避免"顺延膨胀/被前一段污染"
trap 'rm -rf "$TMP"; [ -n "${sink_pid:-}" ] && kill "$sink_pid" 2>/dev/null' EXIT INT TERM

# ---------------------------------------------------------------- A 语法
printf 'A. 语法（dash + bash）\n'
# ⚠️ bin/dsh-token-broker 是 **python3**（只借了个 sh 头），不在这张表里
for f in bin/dsh-remote bin/dsh-notify bin/harness-remote bin/dsh-web-run \
    cloud/relay.sh scripts/install.sh tests/run_tests.sh; do
    if sh -n "$proj/$f" 2>"$TMP/err"; then ok "sh -n $f"; else bad "sh -n $f" "$(cat "$TMP/err")"; fi
    if bash -n "$proj/$f" 2>"$TMP/err"; then ok "bash -n $f"; else bad "bash -n $f" "$(cat "$TMP/err")"; fi
done

# ---------------------------------------------------------------- B env 两份
printf 'B. env.zsh / env.bash 等价\n'
for shname in bash zsh; do
    command -v "$shname" >/dev/null 2>&1 || {
        printf '  skip %s（没装）\n' "$shname"
        continue
    }
done

vars_of() { # 从一个 shell 文件里抓出被 export 的变量名（排序后一行一个）
    sed -n 's/^\(export \)\{0,1\}\([A-Z_][A-Z0-9_]*\)=.*$/\2/p' "$1" | sort -u | tr '\n' ' '
}
zv=$(vars_of "$proj/env.zsh")
bv=$(vars_of "$proj/env.bash")
check "两份导出的变量名一致" "$zv" "$bv"
check_contains "env.bash 设了 DSH_REMOTE_DIR" "DSH_REMOTE_DIR" "$bv"
check_contains "env.bash 设了 DSH_REMOTE_CONF_DIR" "DSH_REMOTE_CONF_DIR" "$bv"
check_contains "env.bash 设了 DSH_REMOTE_STATE_DIR" "DSH_REMOTE_STATE_DIR" "$bv"

fake_home="$TMP/home"
mkdir -p "$fake_home"
for shname in bash zsh; do
    command -v "$shname" >/dev/null 2>&1 || continue
    ext=$([ "$shname" = zsh ] && printf zsh || printf bash)
    cat >"$TMP/probe.$shname" <<EOF
. '$proj/env.$ext'
printf '%s|%s|%s' "\$DSH_REMOTE_DIR" "\$DSH_REMOTE_CONF_DIR" "\$DSH_REMOTE_STATE_DIR"
EOF
    got=$(HOME="$fake_home" WTOOL_PROJECT_DIR=/x/y "$shname" "$TMP/probe.$shname")
    check "$shname source 后三个变量正确" \
        "/x/y|$fake_home/.config/dsh-remote|$fake_home/.local/state/dsh-remote" "$got"
done

# ---------------------------------------------------------------- C dsh-notify
printf 'C. dsh-notify\n'
NOTIFY=$proj/bin/dsh-notify
cfg="$TMP/notify.conf"
logf="$TMP/notify.log"

pick_port() {
    python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}
port=$(pick_port)
sink_out="$TMP/sink.txt"
: >"$sink_out"
python3 "$here/http_sink.py" "$port" "$sink_out" &
sink_pid=$!
i=0
while [ "$i" -lt 40 ]; do
    if python3 -c "import socket,sys;s=socket.socket();s.settimeout(0.3);sys.exit(0 if s.connect_ex(('127.0.0.1',$port))==0 else 1)" 2>/dev/null; then break; fi
    sleep 0.1
    i=$((i + 1))
done

cat >"$cfg" <<EOF
provider=generic
URL=http://127.0.0.1:$port/hook
public_url=https://dsh.example.com/
on_stop=1
EOF
export DSH_NOTIFY_CONF="$cfg"
export DSH_REMOTE_HOME="$TMP/home"
export DSH_NOTIFY_LOG="$logf"

run_notify() { "$NOTIFY" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null; printf '%s' "$?"; }

if [ -s "$cfg" ]; then ok "接收端起来了（端口 $port）"; else bad "接收端"; fi

"$NOTIFY" --help >"$TMP/help" 2>&1
check "--help 退出 0" "0" "$?"
check_contains "--help 里有用法" "dsh-notify" "$(cat "$TMP/help")"
# H10：范围写死成 2,20p 时，把"退出码永远是 0"那段的最后一截掉了
check_contains '--help 不截断"退出码永远是 0"那段（H10）' "失败只写一行到" "$(cat "$TMP/help")"
check_not_contains "--help 不越界（没有 set -u）" "set -u" "$(cat "$TMP/help")"

: >"$sink_out"
code=$(run_notify --test)
check "--test 退出码 0" "0" "$code"
i=0
while [ ! -s "$sink_out" ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
done
check_contains "--test 真发出去了（标题）" "dsh-notify 测试" "$(cat "$sink_out")"

: >"$sink_out"
code=$(run_notify "标题甲" "正文乙")
check "普通推送退出码 0" "0" "$code"
check_contains "普通推送内容正确" "正文乙" "$(cat "$sink_out")"
check_contains "正文带上了 public_url" "https://dsh.example.com/" "$(cat "$sink_out")"

# 配置不存在 → 仍然 0（绝不能因为配置缺失挡住工具调用）
code=$(DSH_NOTIFY_CONF="$TMP/不存在.conf" "$NOTIFY" "x" "y" >/dev/null 2>&1; printf '%s' "$?")
check "配置不存在时退出码仍是 0" "0" "$code"

# 不认识的 provider → 仍然 0
sed 's/^provider=generic/provider=不存在的渠道/' "$cfg" >"$TMP/bad.conf"
code=$(DSH_NOTIFY_CONF="$TMP/bad.conf" "$NOTIFY" "x" "y" >/dev/null 2>&1; printf '%s' "$?")
check "provider 不认识时退出码仍是 0" "0" "$code"
check_contains "失败写进了日志" "不认识的 provider" "$(cat "$logf" 2>/dev/null || printf '')"

# --hook：PreToolUse / ask_user_question
: >"$sink_out"
cat >"$TMP/hook-q.json" <<'EOF'
{"session_id":"s1","transcript_path":"","cwd":"/home/u/self/wtool","hook_event_name":"PreToolUse",
 "tool_name":"ask_user_question",
 "tool_input":{"questions":[{"id":"q1","header":"选方案","question":"用哪个方案？","options":[{"label":"A（推荐）"},{"label":"B"}]}]}}
EOF
code=$("$NOTIFY" --hook <"$TMP/hook-q.json" >/dev/null 2>&1; printf '%s' "$?")
check "--hook 退出码 0" "0" "$code"
i=0
while [ ! -s "$sink_out" ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
done
got=$(cat "$sink_out")
check_contains "hook：标题是等用户回答" "在等你回答" "$got"
check_contains "hook：带上了问题文本" "用哪个方案？" "$got"
check_contains "hook：带上了选项" "A（推荐）" "$got"
check_contains "hook：带上了工作区名" "wtool" "$got"

# --hook：Stop，on_stop=0 时不该推
: >"$sink_out"
sed 's/^on_stop=1/on_stop=0/' "$cfg" >"$TMP/nostop.conf"
printf '{"hook_event_name":"Stop","cwd":"/home/u/self/wtool"}' |
    DSH_NOTIFY_CONF="$TMP/nostop.conf" "$NOTIFY" --hook >/dev/null 2>&1
sleep 0.6
check "on_stop=0 时不推 Stop" "" "$(cat "$sink_out")"

# --hook：Stop，默认要推
: >"$sink_out"
printf '{"hook_event_name":"Stop","cwd":"/home/u/self/wtool"}' | "$NOTIFY" --hook >/dev/null 2>&1
i=0
while [ ! -s "$sink_out" ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
done
check_contains "Stop 推的是"跑完了"" "跑完了" "$(cat "$sink_out")"

# --hook --async：必须立刻返回，而且消息照样到
: >"$sink_out"
t0=$(date +%s)
printf '{"hook_event_name":"Stop","cwd":"/home/u/self/wtool"}' | "$NOTIFY" --hook --async >/dev/null 2>&1
t1=$(date +%s)
check "--async 立刻返回（≤2s）" "1" "$([ $((t1 - t0)) -le 2 ] && printf 1 || printf 0)"
i=0
while [ ! -s "$sink_out" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
check_contains "--async 的消息最后还是到了" "跑完了" "$(cat "$sink_out")"

# ---------------------------------------------------------------- D Caddyfile
printf 'D. cloud/relay.sh 渲染（中继器容器化）\n'
setup=$proj/cloud/relay.sh

# 模板注释里本来就有 {{...}}（给人看的说明），所以按名字逐个查有没有漏替换
leaked_placeholders() {
    _leak=""
    for ph in DOMAIN EMAIL USER HASH PORT IP TUNNEL_PORT LOCAL_PORT ALLOW_BLOCK; do
        case $1 in *"{{$ph}}"*) _leak="$_leak {{$ph}}" ;; esac
    done
    printf '%s' "$_leak"
}

out=$("$setup" --domain dsh.example.com --email me@example.com --dry-run 2>&1)
check "domain dry-run 退出 0" "0" "$?"
check "domain：占位符都替换了" "" "$(leaked_placeholders "$out")"
check_contains "domain：有 basic_auth" "basic_auth" "$out"
check_contains "domain：Host 改写成回环" "header_up Host 127.0.0.1:3080" "$out"
check_contains "domain：Origin 也改了" "header_up Origin http://127.0.0.1:3080" "$out"
check_contains "domain：反代到隧道端口" "reverse_proxy 127.0.0.1:18080" "$out"
check_contains "domain：写了域名" "dsh.example.com" "$out"
check_contains "domain：配了 ACME 邮箱" "me@example.com" "$out"
# default_sni 只该出现在 IP 模式（域名本来就会进 SNI，见 hazards H13）
check_not_contains "domain：不该有 default_sni" "default_sni" "$out"

out=$("$setup" --ip 47.98.1.2 --dry-run 2>&1)
check "ip dry-run 退出 0" "0" "$?"
check "ip：占位符都替换了" "" "$(leaked_placeholders "$out")"
check_contains "ip：自签证书" "tls internal" "$out"
check_contains "ip：站点地址带端口" "47.98.1.2:8443" "$out"
check_contains "ip：Host 也改写" "header_up Host 127.0.0.1:3080" "$out"
# IP 模式必须有 default_sni：浏览器连 https://<IP> 不发 SNI，没它握手直接失败（H13）
check_contains "ip：带 default_sni（连 IP 没有 SNI，没它就是握手 Internal Error）" "default_sni 47.98.1.2" "$out"

out=$("$setup" --ip 47.98.1.2 --allow-ip 1.2.3.4/32 --dry-run 2>&1)
check_contains "allow-ip：插入了 remote_ip 规则" "not remote_ip 1.2.3.4/32" "$out"
check_contains "allow-ip：被挡的返回 403" 'respond @notme "forbidden" 403' "$out"

out=$("$setup" --ip 1.2.3.4 --allow-ip 5.6.7.8 --allow-ip 6.7.8.9 --dry-run 2>&1)
check_contains "allow-ip：多个 IP 空格分隔" "not remote_ip 5.6.7.8 6.7.8.9" "$out"

"$setup" --domain a.com --ip 1.2.3.4 --dry-run >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "--domain 和 --ip 同时给会报错" || bad "--domain 和 --ip 同时给会报错"

"$setup" --dry-run >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "两个都不给会报错" || bad "两个都不给会报错"

out=$("$setup" --domain a.com --tunnel-port 19999 --local-port 3999 --user bob --dry-run 2>&1)
check_contains "端口/用户名可覆盖（隧道）" "reverse_proxy 127.0.0.1:19999" "$out"
check_contains "端口/用户名可覆盖（本地）" "header_up Host 127.0.0.1:3999" "$out"
check_contains "端口/用户名可覆盖（用户）" "bob " "$out"

# 用户空间模式：没有 compose 插件 / 不在 docker 组的机器（真阿里云那台就是）
out=$("$setup" --ip 47.98.1.2 --no-compose --dir "$TMP/relaydir" --docker-cmd docker --dry-run 2>&1)
check "--no-compose --dir 的 dry-run 退出 0" "0" "$?"
check_contains "--no-compose：打印真跑时会执行的 docker run" "docker run -d --name dsh-relay" "$out"
check_contains "--no-compose：数据挂在 --dir 指定的目录" "$TMP/relaydir/Caddyfile" "$out"
check_contains "--no-compose：提示里说要先 rm -f（可重复跑）" "docker rm -f dsh-relay" "$out"

# ---------------------------------------------------------------- E dsh-remote
# 提示语里那条"手工等价命令"必须**真能跑通**（不是字符串断言）：dry-run 会把它打成
# `HINT-CMD: …`；这里把它抽出来、换掉密码占位符、追加 --dry-run 再跑一遍。
mkdir -p "$TMP/hint"
sh "$proj/cloud/relay.sh" --ip 127.0.0.1 --port 9443 --tunnel-port 3090 --broker-port 3082 \
    --local-port 3090 --user u --password pw --no-compose --dir "$TMP/hint" --docker-cmd docker \
    --dry-run >"$TMP/hint.out" 2>"$TMP/hint.err"
hint=$(sed -n 's/^HINT-CMD: //p' "$TMP/hint.err" | head -n 1)
check_contains "relay.sh：dry-run 也打印那条可复制的改密码命令" "--no-compose" "$hint"
check_contains "relay.sh：那条命令带了 --dir" "--dir $TMP/hint" "$hint"
check_contains "relay.sh：那条命令带了 --docker-cmd" "--docker-cmd 'docker'" "$hint"
check_contains "relay.sh：那条命令带了模式参数（--ip）" "--ip 127.0.0.1" "$hint"
hint2=$(printf '%s' "$hint" | sed "s/'<新密码>'/'pw2'/")
# shellcheck disable=SC2086
sh -c "$hint2 --dry-run" >"$TMP/hint2.out" 2>/dev/null
check "relay.sh：提示里那条命令本机 --dry-run 跑得通（参数没掉）" "0" "$?"
if grep -q "{{[A-Z_]\{1,\}}}" "$TMP/hint2.out"; then
    bad "relay.sh：提示命令渲染后没有残留占位符" "$(grep -o "{{[A-Z_]\{1,\}}}" "$TMP/hint2.out" | head -1)"
else
    ok "relay.sh：提示命令渲染后没有残留占位符"
fi
check_contains "relay.sh：提示命令复现的是同一套上游（broker 3082）" \
    "reverse_proxy @entry 127.0.0.1:3082" "$(cat "$TMP/hint2.out")"

printf 'E. dsh-remote 子命令\n'
remote=$proj/bin/dsh-remote
export DSH_REMOTE_CONF="$TMP/remote.conf"
export DSH_NOTIFY_BIN="$NOTIFY"

"$remote" help >"$TMP/help2" 2>&1
check "help 退出 0" "0" "$?"
check_contains "help 里有 status" "status" "$(cat "$TMP/help2")"
# H10：范围写死成 2,25p 时会多打 `set -u` 和两行无关注释；末行应是注释块最后一行
check_not_contains "help 不越界（没有 set -u）" "set -u" "$(cat "$TMP/help2")"
check "help 最后一行就是注释块末行" \
    "安全边界、威胁模型、为什么这么设计：见同目录 README.md。" "$(tail -n 1 "$TMP/help2")"

"$remote" 不存在 >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "未知子命令非 0" || bad "未知子命令非 0"

# status 在没有配置时也要能跑（这是最常见的第一次调用）
DSH_REMOTE_HOME="$TMP/home" "$remote" status >"$TMP/st" 2>&1
check "status（无配置）退出 0" "0" "$?"
check_contains "status 会提示还没配置" "还没有" "$(cat "$TMP/st")"
# H9：提示要指到我们自己的目录（DSH_REMOTE_HOME 之下），不是 ~/.dsh
check_contains "status 提示的 notify.conf 落在我们自己的目录（H9）" "$TMP/home/notify.conf" "$(cat "$TMP/st")"
check_not_contains "status 不再把人指向 ~/.dsh/notify.conf（H9）" "~/.dsh/notify.conf" "$(cat "$TMP/st")"
check_contains "status 打印的项目目录是对的" "$proj" "$(cat "$TMP/st")"

# 软链下也要能解出"我是谁"：真实用法就是 ~/.local/bin/dsh-remote 这种软链，
# 不解软链的话 PROJ_DIR 会算成 ~/.local，然后 hooks 模板就找不到了
mkdir -p "$TMP/bin"
ln -sfn "$remote" "$TMP/bin/dsh-remote-link"
DSH_REMOTE_HOME="$TMP/home" "$TMP/bin/dsh-remote-link" status >"$TMP/st2" 2>&1
check_contains "软链下项目目录仍然正确" "$proj" "$(cat "$TMP/st2")"
DSH_REMOTE_HOME="$TMP/home" "$TMP/bin/dsh-remote-link" cloud-setup >"$TMP/cs2" 2>&1
check_contains "软链下 cloud-setup 也能找到 cloud/ 目录" "$proj/cloud" "$(cat "$TMP/cs2")"

DSH_REMOTE_HOME="$TMP/home" "$remote" url >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "url（没配 public_url）非 0" || bad "url（没配 public_url）非 0"

# notify-enable / disable，全程在临时 DSH_REMOTE_HOME 里
rh="$TMP/rh"
mkdir -p "$rh"
# profile patch 只能待在 harness 自己的目录里，测试里也给它一个临时目录 ——
# 绝不能碰真的 ~/.dsh
export DSH_HOME="$rh/.dsh"
DSH_REMOTE_HOME="$rh" "$remote" notify-enable >"$TMP/en" 2>&1
check "notify-enable 退出 0" "0" "$?"

hooks="$rh/hooks.json"
patch="$DSH_HOME/profiles/web/cordis.patch.yml"
[ -f "$hooks" ] && ok "生成了 hooks.json" || bad "生成了 hooks.json"
[ -f "$patch" ] && ok "生成了 profile patch" || bad "生成了 profile patch"

if python3 -c "import json,sys;json.load(open('$hooks'))" 2>/dev/null; then
    ok "hooks.json 是合法 JSON"
else
    bad "hooks.json 是合法 JSON"
fi
hj=$(cat "$hooks")
check_contains "hooks.json 里挂了 PreToolUse" "PreToolUse" "$hj"
check_contains "只对 ask_user_question 生效" "ask_user_question" "$hj"
check_contains "命令指向 dsh-notify" "$NOTIFY" "$hj"
check_contains "命令带 --hook --async" "--hook --async" "$hj"
check_not_contains "hooks.json 里没有残留占位符" "__DSH_NOTIFY__" "$hj"

pj=$(cat "$patch")
check_contains "patch：挂的是 hooks-claude-code" "dsh-hooks-claude-code" "$pj"
check_contains "patch：configPath 指向 hooks.json" "configPath: $hooks" "$pj"
check_contains "patch：用 id 挂载" "id: hooks-claude-code" "$pj"
# 这条是踩过的坑：patch 层里光写 - id: 会被当成"覆盖已有的行"，
# 必须写成 - insert: 才会真的插进去
check_contains "patch：用 insert 插入（不是 id 覆盖）" "- insert:" "$pj"

# 幂等
DSH_REMOTE_HOME="$rh" "$remote" notify-enable >/dev/null 2>&1
n=$(grep -c '^# >>> dsh-remote notify' "$patch")
check "notify-enable 幂等（只有一段）" "1" "$n"

# disable 之后那段要干净消失，文件还得是合法 YAML（至少不能留空文件）
DSH_REMOTE_HOME="$rh" "$remote" notify-disable >/dev/null 2>&1
check "notify-disable 退出 0" "0" "$?"
pj=$(cat "$patch")
check_not_contains "disable 后没有钩子那一段" "hooks-claude-code" "$pj"
check_not_contains "disable 后标记也没了" "dsh-remote notify" "$pj"
[ -s "$patch" ] && ok "disable 后文件没被清空" || bad "disable 后文件没被清空"
check "disable 后内容是空层 []" "[]" "$(sed '/^#/d;/^$/d' "$patch" | tr -d '[:space:]')"
# 再开一次还能开回来
DSH_REMOTE_HOME="$rh" "$remote" notify-enable >/dev/null 2>&1
check_contains "disable 之后还能再 enable" "hooks-claude-code" "$(cat "$patch")"

# cloud-setup 只打印命令，不该失败
DSH_REMOTE_HOME="$rh" "$remote" cloud-setup >"$TMP/cs" 2>&1
check "cloud-setup 退出 0" "0" "$?"
check_contains "cloud-setup 里有 scp" "scp -r" "$(cat "$TMP/cs")"
check_contains "cloud-setup 里有 relay.sh" "relay.sh" "$(cat "$TMP/cs")"

# 容器化：中继器必须是"一个容器 + compose 管"，不是宿主上装包
[ -f "$proj/cloud/docker-compose.yml" ] && ok "有 docker-compose.yml" || bad "有 docker-compose.yml"
cmp=$(cat "$proj/cloud/docker-compose.yml" 2>/dev/null)
check_contains "compose：用 caddy 官方镜像" "image: caddy:2" "$cmp"
check_contains "compose：host 网络（要连宿主 127.0.0.1 的隧道口）" "network_mode: host" "$cmp"
check_contains "compose：证书放命名卷" "caddy-data:" "$cmp"
check_contains "compose：Caddyfile 只读挂载" "/etc/caddy/Caddyfile:ro" "$cmp"
# 镜像 tag 必须钉住：浮动 tag 会被国内 mirror 兑成几年前的旧镜像（H13）
check_contains "compose：镜像 tag 钉到 caddy:2.11.4（不是浮动的 caddy:2）" "image: caddy:2.11.4" "$cmp"
rl=$(cat "$setup")
check_contains "relay.sh：哈希在容器里算" "dk run --rm" "$rl"
check_contains "relay.sh：用 compose 起服务" "compose up -d" "$rl"
check_not_contains "relay.sh：不再 apt 装 caddy" "apt-get install -y --no-install-recommends caddy" "$rl"
check_contains "relay.sh：宿主只要求 docker" "docker" "$rl"
check_contains "relay.sh：默认镜像也钉住" "caddy:2.11.4" "$rl"
check_not_contains "relay.sh：默认不再是浮动的 caddy:2" 'CADDY_IMAGE:-caddy:2}' "$rl"
check_contains "relay.sh：有用户空间模式（--no-compose）" "--no-compose" "$rl"
check_contains "relay.sh：docker 命令可换（--docker-cmd，给要 sudo 的机器）" 'DOCKER=${DOCKER_CMD:-docker}' "$rl"
check_contains "relay.sh：起容器走 \$DOCKER，不写死 docker" '$DOCKER run -d --name "$CONTAINER_NAME"' "$rl"
check_contains "relay.sh：--help 会用算出来的注释块范围（别再写死行号）" "awk 'NR == 1 { next }" "$rl"
check_contains "relay.sh：版本自检（太老的镜像直接拦下来）" "basic_auth 指令要 ≥ 2.8" "$rl"

# ---------------------------------------------------------------- F cloud-install
printf 'F. cloud-install（一条命令装到阿里云；用假的 ssh/scp 验参数）\n'
stub="$TMP/stub"
mkdir -p "$stub"
cat >"$stub/ssh" <<'STUB'
#!/bin/sh
printf 'SSH: %s\n' "$*" >>"$DSH_TEST_LOG"
printf '== 渲染 Caddyfile（domain 模式，对外端口 443）\n'
printf '手机收藏这个地址：https://dsh.example.com\n用户名：dsh\n密码：  pw-abc-123\n'
STUB
cat >"$stub/scp" <<'STUB'
#!/bin/sh
printf 'SCP: %s\n' "$*" >>"$DSH_TEST_LOG"
STUB
chmod +x "$stub/ssh" "$stub/scp"
export DSH_TEST_LOG="$TMP/stub.log"
: >"$DSH_TEST_LOG"

cat >"$TMP/ci.conf" <<EOF
cloud_host=47.98.1.2
cloud_user=root
cloud_ssh_port=22
remote_port=18080
local_port=3080
public_url=
EOF
PATH="$stub:$PATH" DSH_REMOTE_CONF="$TMP/ci.conf" DSH_REMOTE_HOME="$TMP/cihome" \
    "$remote" cloud-install --domain dsh.example.com --email me@example.com >"$TMP/ci.out" 2>&1
check "cloud-install（域名）退出 0" "0" "$?"
sl=$(cat "$DSH_TEST_LOG")
check_contains "cloud-install：scp 传的是 cloud/ 目录" "cloud" "$sl"
check_contains "cloud-install：云上目录在 /opt/dsh-relay" "/opt/dsh-relay" "$sl"
check_contains "cloud-install：ssh 里带了 --domain" "--domain dsh.example.com" "$sl"
check_contains "cloud-install：ssh 里带了 --tunnel-port" "--tunnel-port 18080" "$sl"
check_contains "cloud-install：云上跑的是 relay.sh" "relay.sh" "$sl"
check_contains "cloud-install：把打印的地址写回 public_url" "public_url=https://dsh.example.com" "$(cat "$TMP/ci.conf")"
check_contains "cloud-install：输出里告诉用户下一步" "dsh-remote tunnel" "$(cat "$TMP/ci.out")"

# 不给 --domain/--ip 时，cloud_host 是 IP 就自己当 --ip 用
: >"$DSH_TEST_LOG"
PATH="$stub:$PATH" DSH_REMOTE_CONF="$TMP/ci.conf" DSH_REMOTE_HOME="$TMP/cihome" \
    "$remote" cloud-install >/dev/null 2>&1
check "cloud-install（cloud_host 是 IP，自动 --ip）退出 0" "0" "$?"
check_contains "自动补上了 --ip" "--ip 47.98.1.2" "$(cat "$DSH_TEST_LOG")"

# 既没有 --domain/--ip，cloud_host 又是域名 → 必须报错，别瞎猜
sed 's/^cloud_host=.*/cloud_host=vpn.example.com/' "$TMP/ci.conf" >"$TMP/ci2.conf"
PATH="$stub:$PATH" DSH_REMOTE_CONF="$TMP/ci2.conf" DSH_REMOTE_HOME="$TMP/cihome" \
    "$remote" cloud-install >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "说不清装到哪就报错（不瞎猜）" || bad "说不清装到哪就报错（不瞎猜）"

# --dry-run 不许真的调 ssh/scp
: >"$DSH_TEST_LOG"
PATH="$stub:$PATH" DSH_REMOTE_CONF="$TMP/ci.conf" DSH_REMOTE_HOME="$TMP/cihome" \
    "$remote" cloud-install --ip 1.2.3.4 --dry-run >"$TMP/ci3.out" 2>&1
check "--dry-run 退出 0" "0" "$?"
check "--dry-run 不碰远近两端（没调 ssh/scp）" "" "$(cat "$DSH_TEST_LOG")"
check_contains "--dry-run 会把要执行的命令打出来" "relay.sh" "$(cat "$TMP/ci3.out")"

# ---------------------------------------------------------------- G ~/.dsh 边界 + migrate
printf 'G. 目录边界：自己的东西不放 ~/.dsh\n'
bh="$TMP/bh"
mkdir -p "$bh/.dsh" "$bh/.config" "$bh/.local/state"
# 假装旧版本把配置放在了 ~/.dsh
printf 'provider=generic\nURL=http://127.0.0.1:1/x\n' >"$bh/.dsh/notify.conf"
printf 'cloud_host=1.2.3.4\n' >"$bh/.dsh/remote.conf"
printf 'x\n' >"$bh/.dsh/notify.log"
HOME="$bh" DSH_HOME="$bh/.dsh" DSH_REMOTE_HOME= "$remote" migrate >"$TMP/mig.out" 2>&1
check "migrate 退出 0" "0" "$?"
[ -f "$bh/.config/dsh-remote/notify.conf" ] && ok "notify.conf 搬到了 ~/.config/dsh-remote" || bad "notify.conf 搬到了 ~/.config/dsh-remote"
[ -f "$bh/.local/state/dsh-remote/notify.log" ] && ok "日志搬到了 ~/.local/state/dsh-remote" || bad "日志搬到了 ~/.local/state/dsh-remote"
[ ! -f "$bh/.dsh/notify.conf" ] && ok "旧位置清干净了" || bad "旧位置清干净了"

# notify-enable 在临时 HOME 里跑，不许往真 ~/.dsh 写
HOME="$bh" DSH_HOME="$bh/.dsh" DSH_REMOTE_HOME= "$remote" notify-enable >/dev/null 2>&1
[ -f "$bh/.config/dsh-remote/hooks.json" ] && ok "hooks.json 写进了自己的配置目录" || bad "hooks.json 写进了自己的配置目录"
[ -f "$bh/.dsh/profiles/web/cordis.patch.yml" ] && ok "只有 profile patch 落在 ~/.dsh（harness 规定的位置）" || bad "只有 profile patch 落在 ~/.dsh（harness 规定的位置）"
check "~/.dsh 里除了 profiles/ 没别的东西" "profiles" "$(ls -A "$bh/.dsh" | tr '\n' ' ' | sed 's/ *$//')"
check "配置目录里放的是我们自己的东西" "hooks.json notify.conf remote.conf" "$(ls -A "$bh/.config/dsh-remote" | tr '\n' ' ' | sed 's/ *$//')"

# ------------------------------------------------ H check-hooks（用假 dsh 验两条路）
printf 'H. check-hooks：能不能识别"钩子桥没触发"\n'
stub2="$TMP/stub2"
mkdir -p "$stub2"
cat >"$stub2/dsh" <<'S'
#!/bin/sh
exit 0
S
chmod +x "$stub2/dsh"
PATH="$stub2:$PATH" DSH_REMOTE_HOME="$rh" DSH_HOME="$DSH_HOME" sh "$remote" check-hooks >"$TMP/ch1" 2>&1
check "钩子没触发 → 退出码 1（能当检查用）" "1" "$?"
ch1=$(cat "$TMP/ch1")
check_contains "说清是"没触发"" "没有触发" "$ch1"
check_contains "给了 A 路线（装 pnpm + dsh plugin）" "dsh plugin" "$ch1"
check_contains "给了 B 路线（手动 dsh-notify）" "notify-test" "$ch1"

cat >"$stub2/dsh" <<S
#!/bin/sh
printf '{"hook_event_name":"Stop","cwd":"/tmp"}' | DSH_NOTIFY_CONF="\$DSH_NOTIFY_CONF" DSH_NOTIFY_LOG="\$DSH_NOTIFY_LOG" "$NOTIFY" --hook >/dev/null 2>&1
exit 0
S
chmod +x "$stub2/dsh"
PATH="$stub2:$PATH" DSH_REMOTE_HOME="$rh" DSH_HOME="$DSH_HOME" sh "$remote" check-hooks >"$TMP/ch2" 2>&1
check "钩子真的触发 → 退出码 0" "0" "$?"
check_contains "报成功" "真的会触发" "$(cat "$TMP/ch2")"

# ---------------------------------------------------------------- I 安装脚本
# 2026-10-04 那个"报成功却什么都没装"的回归测试。五件事：
#   A 引擎调用（WTOOL_PROJECT_DIR 由 wt_run_project_script 导出）→ 装 / 幂等
#   B 手工跑（没设 WTOOL_PROJECT_DIR）→ 按 $0 自推项目目录
#   C 换 WTOOL_HOME（≠ HOME）→ 落点从 WTOOL_HOME/WTOOL_PREFIX 推，不写回 $HOME
#   D 源找不到 → 只跳过那一条 + 打印去哪儿找了 + 一个字节都不写（不留空目录软链）
#   E --uninstall 撤干净
# 老脚本（源写死 $HOME/.wtool/wtool-work-dir/links/tools/dsh-remote）拿这一节跑会挂。
printf 'I. 安装脚本：临时 HOME/WTOOL_HOME/WTOOL_PREFIX 里真装一遍\n'

check_link() { # <描述> <软链路径> <期望目标>
    if [ -L "$2" ]; then
        check "$1" "$3" "$(readlink -- "$2")"
    else
        bad "$1" "$2 不是软链"
    fi
}

# 真 $HOME 里"被写坏就说明漏进真家目录"的那几个东西（跑完必须逐字不变）。
# 注意**不比 mtime 会自己动的活文件**（比如 ~/.dsh 下的会话数据）——
# 这个测试跟正在跑的会话并行，那种断言只会假红。
real_home_fp() {
    for p in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.config/dsh-remote" "$HOME/.local/state/dsh-remote"; do
        if [ -L "$p" ]; then
            printf '%s|link->%s|%s\n' "$p" "$(readlink -- "$p")" "$(stat -c '%Y' "$p")"
        elif [ -e "$p" ]; then
            printf '%s|%s|%s|%s\n' "$p" "$(stat -c '%F' "$p")" "$(stat -c '%s' "$p")" "$(stat -c '%Y' "$p")"
        else
            printf '%s|absent\n' "$p"
        fi
    done
}

inst="$TMP/install"
mkdir -p -- "$inst/home"
home_fp_before=$(real_home_fp)

# ---- A 引擎调用（WTOOL_PROJECT_DIR 是引擎的契约变量）
# 引擎内部那格"稳定中转链接"里**故意埋一份假的**：脚本要是还从那儿取源，
# 软链就会指到 .wtool 里那份假的 —— 断言挂，正是要它挂。
decoy="$inst/home/.wtool/wtool-work-dir/links/tools/dsh-remote"
mkdir -p -- "$decoy/bin"
printf '#!/bin/sh\n# decoy\nexit 9\n' >"$decoy/bin/dsh-remote"
printf '#!/bin/sh\n# decoy\nexit 9\n' >"$decoy/bin/dsh-notify"
chmod +x "$decoy/bin/dsh-remote" "$decoy/bin/dsh-notify"

run_install_a() {
    env HOME="$inst/home" WTOOL_HOME="$inst/home" WTOOL_PREFIX="$inst/prefix" \
        WTOOL_PROJECT_DIR="$proj" DSH_HOME="$inst/dsh" \
        XDG_CONFIG_HOME="$inst/xdg-conf" XDG_STATE_HOME="$inst/xdg-state" \
        sh "$proj/scripts/install.sh" "$@"
}
run_install_a >"$TMP/i-a.out" 2>&1
check "引擎调用：退出 0" "0" "$?"
check_link "dsh-remote 装进 \$WTOOL_PREFIX/bin" "$inst/prefix/bin/dsh-remote" "$proj/bin/dsh-remote"
check_link "dsh-notify 装进 \$WTOOL_PREFIX/bin" "$inst/prefix/bin/dsh-notify" "$proj/bin/dsh-notify"
check_link "配置软链 -> \$WTOOL_PREFIX/etc/dsh-remote" "$inst/xdg-conf/dsh-remote" "$inst/prefix/etc/dsh-remote"
check_link "日志软链 -> \$WTOOL_PREFIX/var/dsh-remote" "$inst/xdg-state/dsh-remote" "$inst/prefix/var/dsh-remote"
[ -f "$inst/xdg-conf/dsh-remote/notify.conf.example" ] &&
    ok "样板 notify.conf.example 复制进来了" || bad "样板 notify.conf.example 复制进来了"
[ -f "$inst/xdg-conf/dsh-remote/remote.conf.example" ] &&
    ok "样板 remote.conf.example 复制进来了" || bad "样板 remote.conf.example 复制进来了"
check "样板内容和项目里那份一致" "$(cat -- "$proj/notify.conf.example")" \
    "$(cat -- "$inst/xdg-conf/dsh-remote/notify.conf.example" 2>/dev/null || printf '缺')"
check_not_contains "没从引擎内部那格取源（软链不是指向埋的假链接）" "$decoy" \
    "$(readlink -- "$inst/prefix/bin/dsh-remote" 2>/dev/null || printf '不是软链')"
grep -q 'decoy' "$decoy/bin/dsh-remote" 2>/dev/null &&
    ok "埋的假中转链接原样没动" || bad "埋的假中转链接原样没动"
[ ! -e "$inst/home/.config/dsh-remote" ] &&
    ok "XDG_CONFIG_HOME 设了时不在 \$HOME/.config 下另起一份" ||
    bad "XDG_CONFIG_HOME 设了时不在 \$HOME/.config 下另起一份"
out=$(env HOME="$inst/home" DSH_HOME="$inst/dsh" "$inst/prefix/bin/dsh-remote" help 2>&1 </dev/null)
check "装出来的 dsh-remote 真能跑（help 退出 0）" "0" "$?"
check_contains "help 打的是用法" "status" "$out"
grep -q -F -- '$HOME/.wtool' "$proj/scripts/install.sh" &&
    bad "install.sh 里不再有 \$HOME/.wtool/... 字面量" \
        "$(grep -n -F -- '$HOME/.wtool' "$proj/scripts/install.sh" | head -1)" ||
    ok "install.sh 里不再有 \$HOME/.wtool/... 字面量"
grep -q -F -- 'WTOOL_PROJECT_DIR' "$proj/scripts/install.sh" &&
    ok "install.sh 的源问 WTOOL_PROJECT_DIR 要" || bad "install.sh 的源问 WTOOL_PROJECT_DIR 要"
for f in env.zsh env.bash; do
    grep -q -F -- '$HOME/.wtool' "$proj/$f" &&
        bad "$f 里不再有 \$HOME/.wtool/... 字面量" \
            "$(grep -n -F -- '$HOME/.wtool' "$proj/$f" | head -1)" ||
        ok "$f 里不再有 \$HOME/.wtool/... 字面量"
done

# ---- A2 幂等
run_install_a >"$TMP/i-a2.out" 2>&1
check "重复 install 退出 0" "0" "$?"
check_link "重复 install 后还是同一条软链" "$inst/prefix/bin/dsh-remote" "$proj/bin/dsh-remote"
check_link "token broker 也装上了（dsh-token-broker）" \
    "$inst/prefix/bin/dsh-token-broker" "$proj/bin/dsh-token-broker"
check_link "server 的薄封装也装上了（dsh-remote-server）" \
    "$inst/prefix/bin/dsh-remote-server" "$proj/bin/dsh-remote-server"
check_link "云上那半的管理器也装上了（harness-remote）" \
    "$inst/prefix/bin/harness-remote" "$proj/bin/harness-remote"
check_not_contains "重复 install 不重复复制样板" "配置样板：" "$(cat "$TMP/i-a2.out")"
check_not_contains "重复 install 没有'找不到源文件'" "找不到源文件" "$(cat "$TMP/i-a2.out")"

# ---- B 手工跑：按 $0 自推项目目录（cwd 在别处 / 相对路径两种）
(
    cd -- "$TMP" &&
        env -u WTOOL_PROJECT_DIR HOME="$inst/b/home" WTOOL_HOME="$inst/b/home" \
            WTOOL_PREFIX="$inst/b/prefix" XDG_CONFIG_HOME="$inst/b/xdg-conf" \
            XDG_STATE_HOME="$inst/b/xdg-state" DSH_HOME="$inst/b/dsh" \
            sh "$proj/scripts/install.sh"
) >"$TMP/i-b.out" 2>&1
check "手工跑（绝对路径、cwd 在别处）退出 0" "0" "$?"
check_link "手工跑：源按 \$0 自推（指到项目检出目录）" "$inst/b/prefix/bin/dsh-remote" "$proj/bin/dsh-remote"
check_not_contains "手工跑没有'找不到源文件'" "找不到源文件" "$(cat "$TMP/i-b.out")"
(
    cd -- "$proj" &&
        env -u WTOOL_PROJECT_DIR HOME="$inst/b2/home" WTOOL_HOME="$inst/b2/home" \
            WTOOL_PREFIX="$inst/b2/prefix" XDG_CONFIG_HOME="$inst/b2/xdg-conf" \
            XDG_STATE_HOME="$inst/b2/xdg-state" DSH_HOME="$inst/b2/dsh" \
            sh scripts/install.sh
) >"$TMP/i-b2.out" 2>&1
check "手工跑（相对路径 scripts/install.sh）退出 0" "0" "$?"
check "手工跑（相对路径）也指到项目检出目录" "$(readlink -f -- "$proj/bin/dsh-remote")" \
    "$(readlink -f -- "$inst/b2/prefix/bin/dsh-remote" 2>/dev/null || printf '没装上')"

# ---- C 换 WTOOL_HOME：落点跟着走，不写回 $HOME
# 这一场要验的正是默认推导，所以用 `env -u` 把 XDG_CONFIG_HOME / XDG_STATE_HOME /
# WTOOL_PREFIX 都挡住：外面真设了也影响不到它。
c_home="$inst/c/home"
c_whome="$inst/c/whome"
mkdir -p -- "$c_home" "$c_whome"
env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u WTOOL_PREFIX \
    HOME="$c_home" WTOOL_HOME="$c_whome" WTOOL_PROJECT_DIR="$proj" DSH_HOME="$inst/c/dsh" \
    sh "$proj/scripts/install.sh" >"$TMP/i-c.out" 2>&1
check "换 WTOOL_HOME 装：退出 0" "0" "$?"
check_link "命令落在 \$WTOOL_HOME/.wtool/usr/bin（WTOOL_PREFIX 默认值也跟它走）" \
    "$c_whome/.wtool/usr/bin/dsh-remote" "$proj/bin/dsh-remote"
check_link "配置软链落在 \$WTOOL_HOME/.config/dsh-remote" \
    "$c_whome/.config/dsh-remote" "$c_whome/.wtool/usr/etc/dsh-remote"
check_link "日志软链落在 \$WTOOL_HOME/.local/state/dsh-remote" \
    "$c_whome/.local/state/dsh-remote" "$c_whome/.wtool/usr/var/dsh-remote"
if [ ! -e "$c_home/.config" ] && [ ! -e "$c_home/.local" ] && [ ! -e "$c_home/.wtool" ]; then
    ok "落点没写回 \$HOME（那个家目录一个东西都没多）"
else
    bad "落点没写回 \$HOME（那个家目录一个东西都没多）" "$(ls -A "$c_home" | tr '\n' ' ')"
fi

# ---- D 源找不到：只跳过那一条 + 说清去哪儿找了 + 什么都不建
d_missing="$inst/d/没有这个目录"
env HOME="$inst/d/home" WTOOL_HOME="$inst/d/home" WTOOL_PREFIX="$inst/d/prefix" \
    WTOOL_PROJECT_DIR="$d_missing" DSH_HOME="$inst/d/dsh" \
    XDG_CONFIG_HOME="$inst/d/xdg-conf" XDG_STATE_HOME="$inst/d/xdg-state" \
    sh "$proj/scripts/install.sh" >"$TMP/i-d.out" 2>&1
check "源整个找不到：仍然退出 0（不把整个 wtool install 拉下水）" "0" "$?"
d_out=$(cat "$TMP/i-d.out")
check_contains "警告里点名了缺的源（命令）" "$d_missing/bin/dsh-remote" "$d_out"
check_contains "警告里说了去哪儿找" "找的地方：$d_missing" "$d_out"
check_contains "警告里说明来源是 WTOOL_PROJECT_DIR" "来自 WTOOL_PROJECT_DIR" "$d_out"
check_contains "末尾交代跳过了几条" "有 8 条源没找到" "$d_out"   # 6 条命令 + 2 张样板
if [ ! -e "$inst/d/prefix" ] && [ ! -e "$inst/d/xdg-conf" ] && [ ! -e "$inst/d/xdg-state" ]; then
    ok "一个字节都没写：\$WTOOL_PREFIX / 配置 / 日志落点都没被建"
else
    bad "一个字节都没写：\$WTOOL_PREFIX / 配置 / 日志落点都没被建" \
        "$(ls -d "$inst/d"/* 2>/dev/null | tr '\n' ' ')"
fi
[ ! -e "$inst/d/home" ] && ok "\$HOME 也没被建" || bad "\$HOME 也没被建"

# 找不全的项目：只有 bin/dsh-remote，别的都没有 → 找到的照装，缺的只警告
d_fake="$inst/d/fake-project"
mkdir -p -- "$d_fake/bin"
printf '#!/bin/sh\n# fake\nexit 0\n' >"$d_fake/bin/dsh-remote"
chmod +x "$d_fake/bin/dsh-remote"
env HOME="$inst/d/home" WTOOL_HOME="$inst/d/home" WTOOL_PREFIX="$inst/d/prefix2" \
    WTOOL_PROJECT_DIR="$d_fake" DSH_HOME="$inst/d/dsh" \
    XDG_CONFIG_HOME="$inst/d/xdg-conf2" XDG_STATE_HOME="$inst/d/xdg-state2" \
    sh "$proj/scripts/install.sh" >"$TMP/i-d2.out" 2>&1
check "源不全：退出 0（不 die、也不吞掉其余动作）" "0" "$?"
check_link "找到的那条照装（dsh-remote）" "$inst/d/prefix2/bin/dsh-remote" "$d_fake/bin/dsh-remote"
if [ ! -e "$inst/d/prefix2/bin/dsh-notify" ] && [ ! -L "$inst/d/prefix2/bin/dsh-notify" ]; then
    ok "缺的那条（dsh-notify）没装、也没留悬空链接"
else
    bad "缺的那条（dsh-notify）没装、也没留悬空链接"
fi
if [ ! -e "$inst/d/xdg-conf2/dsh-remote" ] && [ ! -L "$inst/d/xdg-conf2/dsh-remote" ]; then
    ok "配置软链没建（两张样板一个都没找到，就不铺这一摊）"
else
    bad "配置软链没建（两张样板一个都没找到，就不铺这一摊）"
fi
if [ ! -e "$inst/d/prefix2/etc" ] && [ ! -e "$inst/d/prefix2/var" ]; then
    ok "没为缺的源建目录（只有真要装才 mkdir）"
else
    bad "没为缺的源建目录（只有真要装才 mkdir）" "$(ls -d "$inst/d/prefix2"/* 2>/dev/null | tr '\n' ' ')"
fi
d2_out=$(cat "$TMP/i-d2.out")
check_contains "警告里点名缺的样板" "$d_fake/notify.conf.example" "$d2_out"
check_contains "警告里点名缺的命令" "$d_fake/bin/dsh-notify" "$d2_out"
check_contains "末尾交代跳过了 7 条" "有 7 条源没找到" "$d2_out"   # 缺 5 条命令 + 2 张样板

# ---- E --uninstall：撤掉自己铺的软链，实体（配置/日志）留着
run_install_a --uninstall >"$TMP/i-e.out" 2>&1
check "uninstall 退出 0" "0" "$?"
if [ ! -e "$inst/prefix/bin/dsh-remote" ] && [ ! -L "$inst/prefix/bin/dsh-remote" ]; then
    ok "dsh-remote 软链撤掉了"
else
    bad "dsh-remote 软链撤掉了"
fi
if [ ! -e "$inst/prefix/bin/dsh-notify" ] && [ ! -L "$inst/prefix/bin/dsh-notify" ]; then
    ok "dsh-notify 软链撤掉了"
else
    bad "dsh-notify 软链撤掉了"
fi
if [ ! -e "$inst/xdg-conf/dsh-remote" ] && [ ! -L "$inst/xdg-conf/dsh-remote" ]; then
    ok "配置软链撤掉了"
else
    bad "配置软链撤掉了"
fi
if [ ! -e "$inst/xdg-state/dsh-remote" ] && [ ! -L "$inst/xdg-state/dsh-remote" ]; then
    ok "日志软链撤掉了"
else
    bad "日志软链撤掉了"
fi
[ -f "$inst/prefix/etc/dsh-remote/notify.conf.example" ] &&
    ok "实体（配置目录里的样板）留着 —— 那是用户的东西" ||
    bad "实体（配置目录里的样板）留着 —— 那是用户的东西"

# ---- 真 $HOME 没被碰（整节跑完比指纹）
check "真 \$HOME 的指纹跑完逐字不变（只写临时目录）" "$home_fp_before" "$(real_home_fp)"

# ------------------------------------------------- J 隧道常驻（systemd 单元）
printf 'J. 隧道常驻：单元渲染 / 旧 tmux 抢端口 / 卸载\n'
# 这一节**只在临时目录 + 桩命令里跑**：
#   * 单元落点用 DSH_REMOTE_UNIT_DIR 钉到临时目录（绝不碰真 ~/.config/systemd/user）
#   * systemctl / tmux /（probe 用的）ssh 全是桩（真 tmux 上可能正跑着生产隧道）
real_unit_fp() {
    for p in "$HOME/.config/systemd/user/dsh-tunnel.service" "$HOME/.config/systemd/user/dsh-remote-tunnel.service" \
        "$HOME/.config/systemd/user/dsh-tunnel-watch.service" "$HOME/.config/systemd/user/dsh-tunnel-watch.timer" \
        "$HOME/.local/lib/dsh-remote/tunnel-watch.sh"; do
        if [ -e "$p" ]; then
            printf '%s|%s|%s\n' "$p" "$(stat -c '%s' "$p")" "$(stat -c '%Y' "$p")"
        else
            printf '%s|absent\n' "$p"
        fi
    done
}
unit_fp_before=$(real_unit_fp)

jstub="$TMP/jstub"
mkdir -p "$jstub"
cat >"$jstub/systemctl" <<'STUB'
#!/bin/sh
printf 'SYSTEMCTL: %s\n' "$*" >>"$J_LOG"
case "$*" in
*show-environment*) [ "${J_SD_OK:-1}" = 1 ] && exit 0 || exit 1 ;;
*"show -p MainPID"*) printf '%s\n' "${J_MAINPID:-4242}"; exit 0 ;;
*"show -p NRestarts"*) printf '%s\n' "${J_NRESTARTS:-0}"; exit 0 ;;
*is-active*) printf '%s\n' "${J_ACTIVE:-active}"; exit 0 ;;
*is-enabled*) printf '%s\n' "${J_ENABLED:-enabled}"; exit 0 ;;
*status*) printf '● dsh-tunnel.service（桩）\n'; exit 0 ;;
esac
exit 0
STUB
cat >"$jstub/tmux" <<'STUB'
#!/bin/sh
printf 'TMUX: %s\n' "$*" >>"$J_LOG"
case "$*" in
*has-session*) [ "${J_TMUX_HAS:-0}" = 1 ] && exit 0 || exit 1 ;;
esac
exit 0
STUB
chmod +x "$jstub/systemctl" "$jstub/tmux"

export J_LOG="$TMP/j.log"
export DSH_REMOTE_UNIT_DIR="$TMP/junits"
# 自愈件（内部件）的脚本落点也要钉到临时目录 —— 不钉就写到真 ~/.local/lib 去了
export DSH_REMOTE_LIB_DIR="$TMP/jlib"
export DSH_REMOTE_SYSTEMCTL="$jstub/systemctl"
export DSH_REMOTE_TMUX="$jstub/tmux"
export DSH_REMOTE_CONF="$TMP/j-remote.conf"
: >"$J_LOG"
cat >"$TMP/j-remote.conf" <<EOF
cloud_host=203.0.113.9
cloud_user=alice
cloud_ssh_port=2222
identity=~/.ssh/id_j
remote_port=18099
local_port=3099
tmux_session=dsh-j-stub
EOF

# ① --dry-run：只打印，不写文件、不调 systemctl、不碰 tmux
"$remote" tunnel-install --dry-run >"$TMP/j1.out" 2>&1
check "tunnel-install --dry-run 退出 0" "0" "$?"
j1=$(cat "$TMP/j1.out")
check_contains "dry-run 打出单元全文（Restart=always）" "Restart=always" "$j1"
check_contains "dry-run：ExitOnForwardFailure=yes" "ExitOnForwardFailure=yes" "$j1"
check_contains "dry-run：ServerAliveInterval=15" "ServerAliveInterval=15" "$j1"
check_contains "dry-run：反向转发用 conf 里的端口" "-R 127.0.0.1:18099:127.0.0.1:3099" "$j1"
check "dry-run 一个字节都没写" "" "$(ls -A "$DSH_REMOTE_UNIT_DIR" 2>/dev/null)"
check "dry-run 没调 systemctl（没连用户管理器）" "0" "$(grep -c SYSTEMCTL "$J_LOG" 2>/dev/null || true)"
check "dry-run 没碰 tmux（只 has-session 看一眼，不 kill）" "0" "$(grep -c 'kill-session' "$J_LOG" 2>/dev/null || true)"

# ② 真装（systemd 后端）
: >"$J_LOG"
"$remote" tunnel-install >"$TMP/j2.out" 2>&1
check "tunnel-install 退出 0" "0" "$?"
junit="$DSH_REMOTE_UNIT_DIR/dsh-tunnel.service"
if [ -f "$junit" ]; then ok "单元落在 \$DSH_REMOTE_UNIT_DIR/dsh-tunnel.service"; else bad "单元落点" "$(ls -A "$DSH_REMOTE_UNIT_DIR" 2>/dev/null)"; fi
ju=$(cat "$junit" 2>/dev/null)
check_contains "单元：Restart=always" "Restart=always" "$ju"
check_contains "单元：RestartSec=5（2026-10-09 起默认 5，别 3 秒一锤对端）" "RestartSec=5" "$ju"
# 防风暴（ADR-0019 / hazards H27）：对端持续掐连接时，RestartSec 小 + StartLimitIntervalSec=0
# 会自我维持成风暴（实测 NRestarts 累计到 1708）→ 默认改成"300 秒内失败 10 次就停下"
check_contains "单元：StartLimitIntervalSec=300（默认防风暴）" "StartLimitIntervalSec=300" "$ju"
check_contains "单元：StartLimitBurst=10" "StartLimitBurst=10" "$ju"
# 这个键属于 [Unit]；写在 [Service] 里 systemd 只警告 Unknown key 然后忽略（实测踩过）
check "单元：StartLimit 两个键都不在 [Service] 段（放那儿会被忽略）" "0" \
    "$(sed -n '/^\[Service\]/,$p' "$junit" | grep -c StartLimit || true)"
check_contains "单元：ServerAliveInterval=15" "ServerAliveInterval=15" "$ju"
check_contains "单元：ServerAliveCountMax=3" "ServerAliveCountMax=3" "$ju"
check_contains "单元：TCPKeepAlive=yes" "TCPKeepAlive=yes" "$ju"
check_contains "单元：日志走 journald" "StandardOutput=journal" "$ju"
check_contains "单元：开机自启（WantedBy=default.target）" "WantedBy=default.target" "$ju"
check_contains "单元：ExecStart 是绝对路径的 ssh" "ExecStart=/usr/bin/ssh" "$ju"
check_contains "单元：BatchMode（服务里没终端，别等密码提示）" "BatchMode=yes" "$ju"
check_contains "单元：远程端口可配（conf 里的 18099）" "-R 127.0.0.1:18099:127.0.0.1:3099" "$ju"
check_contains "单元：登录用户走 cloud_user" "alice@203.0.113.9" "$ju"
check_contains "单元：ssh 端口走 cloud_ssh_port" "-p 2222" "$ju"
check_contains "单元：identity 的 ~ 展开成 \$HOME" "-i $HOME/.ssh/id_j" "$ju"
if command -v systemd-analyze >/dev/null 2>&1; then
    jv=$(systemd-analyze verify "$junit" 2>&1)
    check_not_contains "systemd-analyze verify：没有 Unknown key" "Unknown key name" "$jv"
    check_not_contains "systemd-analyze verify：没点名我们的单元" "$junit:" "$jv"
else
    ok "没有 systemd-analyze，跳过单元语法校验"
fi

# ②b 内部件（自愈检查，ADR-0019）：脚本落在 lib 目录、两个单元落在 unit 目录、timer 被 enable
#     它**不是给用户敲的命令**（不进 PATH），所以只在 install 的输出和这里出现
jwscript="$DSH_REMOTE_LIB_DIR/tunnel-watch.sh"
jwunit="$DSH_REMOTE_UNIT_DIR/dsh-tunnel-watch.service"
jwtimer="$DSH_REMOTE_UNIT_DIR/dsh-tunnel-watch.timer"
if [ -f "$jwscript" ]; then ok "自愈件：脚本落在 \$DSH_REMOTE_LIB_DIR（不进 PATH）"; else bad "自愈件：脚本落点" "$(ls -A "$DSH_REMOTE_LIB_DIR" 2>/dev/null)"; fi
if [ -x "$jwscript" ]; then ok "自愈件：脚本可执行（timer 直接跑它）"; else bad "自愈件：脚本可执行"; fi
if sh -n "$jwscript" 2>"$TMP/jw.err"; then ok "自愈件：脚本过 sh -n"; else bad "自愈件：脚本过 sh -n" "$(cat "$TMP/jw.err")"; fi
jws=$(cat "$jwscript" 2>/dev/null)
check_contains "自愈件：探的是 remote.conf 里的主机" "alice@203.0.113.9" "$jws"
check_contains "自愈件：端口默认取 remote_port（18099）" 'WATCH_PORT:-18099' "$jws"
check_contains "自愈件：ssh 带上 conf 里的端口（-p 2222）" '-p "$SSH_PORT"' "$jws"
check_contains "自愈件：不在听就重启隧道" "--user restart dsh-tunnel.service" "$jws"
check_contains "自愈件：重启后复检、没恢复就非 0（写进 journal）" 'logger -t dsh-tunnel-watch' "$jws"
jwu=$(cat "$jwunit" 2>/dev/null)
check_contains "自愈件：service 是 oneshot" "Type=oneshot" "$jwu"
check_contains "自愈件：service 的 ExecStart 指向那个脚本" "ExecStart=$jwscript" "$jwu"
jwt=$(cat "$jwtimer" 2>/dev/null)
check_contains "自愈件：timer 开机 2 分钟后第一次" "OnBootSec=2min" "$jwt"
check_contains "自愈件：timer 每 5 分钟一次" "OnUnitActiveSec=5min" "$jwt"
check_contains "自愈件：timer 挂 timers.target（开机自启）" "WantedBy=timers.target" "$jwt"
check "自愈件：install 会把 timer enable --now" "1" \
    "$(grep -c -- '--user enable --now dsh-tunnel-watch.timer' "$J_LOG" || true)"
if command -v systemd-analyze >/dev/null 2>&1; then
    jwv=$(systemd-analyze verify "$jwunit" "$jwtimer" 2>&1)
    check_not_contains "systemd-analyze verify（自愈件）：没有 Unknown key" "Unknown key name" "$jwv"
fi
jlg=$(cat "$J_LOG")
check_contains "装的时候 daemon-reload" "--user daemon-reload" "$jlg"
check_contains "装的时候 enable --now dsh-tunnel.service" "--user enable --now dsh-tunnel.service" "$jlg"
j2=$(cat "$TMP/j2.out")
check_contains "打印判据：is-active" "is-active=active" "$j2"
check_contains "打印判据：云上 ss 那条命令" "ss -ltn | grep 18099" "$j2"
check_contains "打印判据：本机不该看到远程端口" "不该" "$j2"

# ③ 幂等：再装一次，内容逐字不变、不产生 .bak
: >"$J_LOG"
ju_before=$(cat "$junit")
"$remote" tunnel-install >/dev/null 2>&1
check "重复 install 退出 0" "0" "$?"
check "重复 install 单元内容逐字不变" "$ju_before" "$(cat "$junit")"
check "重复 install 没留 .bak（内容没变就不备份）" "0" "$(ls "$DSH_REMOTE_UNIT_DIR" | grep -c '\.bak-' || true)"
check "重复 install 不 restart（内容没变，别白断一次隧道）" "0" \
    "$(grep -c -- '--user restart dsh-tunnel.service' "$J_LOG" || true)"

# ④ 旧的一次性 tmux 会话还在：要提示 + 停掉（不然两条隧道抢云上同一个端口）
: >"$J_LOG"
J_TMUX_HAS=1 "$remote" tunnel-install >"$TMP/j3.out" 2>&1
check "有旧 tmux 会话时 install 仍然退出 0" "0" "$?"
j3=$(cat "$TMP/j3.out")
check_contains "认出旧 tmux 会话并 kill-session" "TMUX: kill-session -t dsh-j-stub" "$(cat "$J_LOG")"
check_contains "提示里点明会抢同一个端口" "抢同一个端口" "$j3"
: >"$J_LOG"
J_TMUX_HAS=1 "$remote" tunnel-install --keep-tmux >/dev/null 2>&1
check "--keep-tmux：不动别人的会话" "0" "$(grep -c 'kill-session' "$J_LOG" || true)"

# ⑤ systemctl --user 不可用：**在停旧隧道之前**就要停手，别把正在跑的弄没了
: >"$J_LOG"
J_SD_OK=0 DSH_REMOTE_UNIT_DIR="$TMP/junits2" "$remote" tunnel-install >"$TMP/j4.out" 2>&1
j4_rc=$?
[ "$j4_rc" -ne 0 ] && ok "用户管理器不可用时 install 非 0（不假装成功）" || bad "用户管理器不可用时 install 非 0"
j4=$(cat "$TMP/j4.out")
check_contains "给出出路：enable-linger" "loginctl enable-linger" "$j4"
check "不可用时一个字节都没写" "" "$(ls -A "$TMP/junits2" 2>/dev/null)"
check "不可用时没碰 tmux（旧隧道还在跑）" "0" "$(grep -c TMUX "$J_LOG" 2>/dev/null || true)"

# ⑥ tunnel-status：看状态 + 认配置漂移 + 点名旧 tmux
DSH_REMOTE_UNIT_DIR="$TMP/junits" "$remote" tunnel-status >"$TMP/j5.out" 2>&1
check "tunnel-status 退出 0" "0" "$?"
j5=$(cat "$TMP/j5.out")
check_contains "status：打印单元完整路径" "$TMP/junits/dsh-tunnel.service" "$j5"
check_contains "status：打印 is-active" "is-active=active" "$j5"
check_contains "status：参数与 remote.conf 一致" "单元里的 ssh 参数和现在的 remote.conf 一致" "$j5"
check_contains "status：说清反向隧道不该在本地听" "18099 本地没听" "$j5"
sed 's/^remote_port=.*/remote_port=18111/' "$DSH_REMOTE_CONF" >"$TMP/j-remote2.conf"
DSH_REMOTE_CONF="$TMP/j-remote2.conf" DSH_REMOTE_UNIT_DIR="$TMP/junits" \
    "$remote" tunnel-status >"$TMP/j6.out" 2>&1
check_contains "status：配置改了能认出来（漂移）" "对不上了" "$(cat "$TMP/j6.out")"
check_contains "status：漂移时打印重新渲染的 ExecStart（非空）" "现在渲染：/usr/bin/ssh" "$(cat "$TMP/j6.out")"
J_TMUX_HAS=1 DSH_REMOTE_UNIT_DIR="$TMP/junits" "$remote" tunnel-status >"$TMP/j7.out" 2>&1
check_contains "status：点名还在抢端口的旧 tmux 会话" "会话 dsh-j-stub 还在" "$(cat "$TMP/j7.out")"

# ⑦ --probe：上云那条 ssh 是只读的（桩 ssh 只回结果，不真连）
mkdir -p "$TMP/jssh"
cat >"$TMP/jssh/ssh" <<'STUB'
#!/bin/sh
# 远端脚本现在走 stdin（ssh … sh -s），所以把 stdin 也记进日志再回结果
cat >>"$J_LOG"
printf 'SSH: %s\n' "$*" >>"$J_LOG"
printf 'LISTEN 0 128 127.0.0.1:18099 0.0.0.0:*\nhttp_code=401\nbroker_http_code=302\n'
STUB
chmod +x "$TMP/jssh/ssh"
: >"$J_LOG"
PATH="$TMP/jssh:$PATH" DSH_REMOTE_CONF="$TMP/j-remote.conf" DSH_REMOTE_UNIT_DIR="$TMP/junits" \
    "$remote" tunnel-status --probe >"$TMP/j8.out" 2>&1
check "--probe 退出 0" "0" "$?"
j8=$(cat "$TMP/j8.out")
check_contains "--probe：认得出云上在听、请求到家里了" "请求穿到了家里" "$j8"
check_contains "--probe：ssh 真的是只读命令（ss / curl，没别的）" "ss -ltn | grep '127.0.0.1:18099'" "$(cat "$J_LOG")"

# ⑧ 改了配置再装：单元要跟着变，而且**要 restart 一次**
#    （systemctl enable --now 对已经在跑的单元不会重启它，不补一刀就是"文件变了、跑的还是旧参数"）
sed 's/^remote_port=.*/remote_port=18222/' "$DSH_REMOTE_CONF" >"$TMP/j-remote3.conf"
: >"$J_LOG"
DSH_REMOTE_CONF="$TMP/j-remote3.conf" "$remote" tunnel-install >"$TMP/j12.out" 2>&1
check "改端口后 install 退出 0" "0" "$?"
check_contains "单元跟着配置变（18222）" "-R 127.0.0.1:18222:127.0.0.1:3099" "$(cat "$junit")"
check_contains "内容变了会 restart" "--user restart dsh-tunnel.service" "$(cat "$J_LOG")"
check "内容变了会留 .bak" "1" "$(ls "$DSH_REMOTE_UNIT_DIR" | grep -c '\.bak-' || true)"

# ⑨b 自愈件的演练（ADR-0019）：拿一个**假端口**跑一遍渲染出来的脚本 ——
#     不在听 → 重启一次隧道 → 复检还是不在 → 非 0。ssh / systemctl / logger 全是桩，
#     **绝不可能**碰到真云端和真隧道。
mkdir -p "$TMP/jwatchbin"
cat >"$TMP/jwatchbin/ssh" <<'STUB'
#!/bin/sh
printf 'SSH: %s\n' "$*" >>"$J_LOG"
printf '0\n'   # 假装云上那个端口不在听
STUB
cat >"$TMP/jwatchbin/logger" <<'STUB'
#!/bin/sh
printf 'LOGGER: %s\n' "$*" >>"$J_LOG"
STUB
chmod +x "$TMP/jwatchbin/ssh" "$TMP/jwatchbin/logger"
: >"$J_LOG"
PATH="$TMP/jwatchbin:$PATH" WATCH_PORT=19999 sh "$jwscript" >"$TMP/jwatch.out" 2>&1
jw_rc=$?
[ "$jw_rc" -ne 0 ] && ok "自愈件演练：假端口（没人听）→ 脚本非 0（不谎报好了）" \
    || bad "自愈件演练：假端口（没人听）→ 脚本非 0" "rc=$jw_rc"
check_contains "自愈件演练：探的是那个假端口" "127.0.0.1:19999" "$(cat "$J_LOG")"
check_contains "自愈件演练：探到不在听 → 重启隧道" "--user restart dsh-tunnel.service" "$(cat "$J_LOG")"
check_contains "自愈件演练：写 journal 说清原因" "不在听" "$(cat "$J_LOG")"

# ⑨c 防风暴那几个开关：不带参数是加固值（上面 ② 验过），带了要能覆盖
mkdir -p "$TMP/junits5"
: >"$J_LOG"
DSH_REMOTE_UNIT_DIR="$TMP/junits5" DSH_REMOTE_LIB_DIR="$TMP/jlib5" DSH_REMOTE_CONF="$TMP/j-remote.conf" \
    "$remote" tunnel-install --restart-sec 7 --start-limit-burst 3 --start-limit-interval 60 \
    --watch-sec 90 >"$TMP/j13.out" 2>&1
check "防风暴开关：install 退出 0" "0" "$?"
j13u=$(cat "$TMP/junits5/dsh-tunnel.service" 2>/dev/null)
check_contains "开关生效：--restart-sec 7" "RestartSec=7" "$j13u"
check_contains "开关生效：--start-limit-burst 3" "StartLimitBurst=3" "$j13u"
check_contains "开关生效：--start-limit-interval 60" "StartLimitIntervalSec=60" "$j13u"
check_contains "开关生效：--watch-sec 90（不是整分钟就写 90s）" "OnUnitActiveSec=90s" \
    "$(cat "$TMP/junits5/dsh-tunnel-watch.timer" 2>/dev/null)"
check_contains "自愈脚本跟着新端口重渲染" 'WATCH_PORT:-18099' \
    "$(cat "$TMP/jlib5/tunnel-watch.sh" 2>/dev/null)"
mkdir -p "$TMP/junits6"
DSH_REMOTE_UNIT_DIR="$TMP/junits6" DSH_REMOTE_LIB_DIR="$TMP/jlib6" DSH_REMOTE_CONF="$TMP/j-remote.conf" \
    "$remote" tunnel-install --no-watch --no-enable >/dev/null 2>&1
check "--no-watch：只写隧道单元、不写自愈件" "dsh-tunnel.service" "$(ls -A "$TMP/junits6" 2>/dev/null)"
check "--no-watch：lib 目录下没有脚本" "" "$(ls -A "$TMP/jlib6" 2>/dev/null)"
DSH_REMOTE_UNIT_DIR="$TMP/junits5" DSH_REMOTE_LIB_DIR="$TMP/jlib5" DSH_REMOTE_CONF="$TMP/j-remote.conf" \
    "$remote" tunnel-uninstall >/dev/null 2>&1
# 只看那三个文件在不在（目录里可能留着 .bak-<时间戳>，那是重渲染时的备份，正常）
if [ ! -e "$TMP/junits5/dsh-tunnel-watch.timer" ] && [ ! -e "$TMP/junits5/dsh-tunnel-watch.service" ] \
    && [ ! -e "$TMP/jlib5/tunnel-watch.sh" ]; then
    ok "自愈件卸载：timer + service + 脚本都撤了"
else
    bad "自愈件卸载：timer + service + 脚本都撤了" "$(ls -A "$TMP/junits5" "$TMP/jlib5" 2>/dev/null)"
fi

# ⑨ 卸载：disable --now + 删文件 + daemon-reload
: >"$J_LOG"
DSH_REMOTE_UNIT_DIR="$TMP/junits" "$remote" tunnel-uninstall >"$TMP/j9.out" 2>&1
check "tunnel-uninstall 退出 0" "0" "$?"
if [ ! -e "$TMP/junits/dsh-tunnel.service" ]; then ok "单元文件删掉了"; else bad "单元文件删掉了"; fi
if [ ! -e "$TMP/junits/dsh-tunnel-watch.timer" ] && [ ! -e "$TMP/junits/dsh-tunnel-watch.service" ] \
    && [ ! -e "$TMP/jlib/tunnel-watch.sh" ]; then
    ok "自愈件也一起撤了（timer + service + 脚本）"
else
    bad "自愈件也一起撤了" "$(ls -A "$TMP/junits" "$TMP/jlib" 2>/dev/null)"
fi
jlg=$(cat "$J_LOG")
check_contains "卸载：disable --now dsh-tunnel.service" "--user disable --now dsh-tunnel.service" "$jlg"
check_contains "卸载：先停自愈 timer（不然它过 5 分钟又把隧道拉起来）" \
    "--user disable --now dsh-tunnel-watch.timer" "$jlg"
check_contains "卸载：daemon-reload" "--user daemon-reload" "$jlg"

# ⑩ 旧名字 systemd：等价 --no-enable（以前就是"只生成不 enable"）；旧单元文件要一起撤
mkdir -p "$TMP/junits3"
: >"$J_LOG"
DSH_REMOTE_UNIT_DIR="$TMP/junits3" "$remote" systemd >"$TMP/j10.out" 2>&1
check "旧名字 systemd 退出 0" "0" "$?"
if [ -f "$TMP/junits3/dsh-tunnel.service" ]; then ok "旧名字写到同一个单元名"; else bad "旧名字写到同一个单元名"; fi
check_contains "旧名字只生成不 enable" "只写了单元" "$(cat "$TMP/j10.out")"
check "旧名字没 enable" "0" "$(grep -c 'enable --now' "$J_LOG" || true)"
mkdir -p "$TMP/junits4"
printf '[Unit]\nDescription=old\n' >"$TMP/junits4/dsh-remote-tunnel.service"
: >"$J_LOG"
DSH_REMOTE_UNIT_DIR="$TMP/junits4" "$remote" tunnel-install >"$TMP/j11.out" 2>&1
check "有旧版单元时 install 退出 0" "0" "$?"
check_contains "install 把旧版单元 disable 掉（它会抢同一个端口）" \
    "--user disable --now dsh-remote-tunnel.service" "$(cat "$J_LOG")"

# ---- 真 $HOME 的 systemd 单元没被这一节碰过
check "真 \$HOME 的 systemd 单元指纹没变" "$unit_fp_before" "$(real_unit_fp)"

# ------------------------------------------- K token 重定向（固定地址那半）
printf 'K. token 重定向：harness 捕获 / broker 302 / Caddy 路由\n'

# ① Caddyfile 模板：入口 matcher 的两个 not 缺一不可（少一个就是 302 死循环）
#    —— 真的死循环在本地同构 Caddy 上验过，见 journal（这一节只做静态断言）
for tmpl in Caddyfile.ip Caddyfile.domain; do
    tc=$(cat "$proj/cloud/$tmpl")
    check_contains "$tmpl：入口 matcher 认 path /" "path /" "$tc"
    check_contains "$tmpl：排除带 token 的请求（那种直连 dsh web）" "not query token=*" "$tc"
    # 针要带上缩进：模板注释里**解释**了"为什么不能写 not header Cookie"，
    # 只搜这几个字会把注释也算上（第一次就是这么误报的）。真实指令是两行缩进。
    check_not_contains "$tmpl：**不再**按 cookie 排除（过期 cookie 会永远拿不到跳转，ADR-0018）" \
        "$(printf '\t\tnot header Cookie')" "$tc"
    check_contains "$tmpl：broker 那条走占位符 BROKER_PORT" "{{BROKER_PORT}}" "$tc"
    check_contains "$tmpl：/go 是重进入口" "@go path /go" "$tc"
    check_contains "$tmpl：其余请求仍直连 dsh web" "reverse_proxy 127.0.0.1:{{TUNNEL_PORT}}" "$tc"
done
rl=$(cat "$proj/cloud/relay.sh")
check_contains "relay.sh：渲染时替换 BROKER_PORT" 's|{{BROKER_PORT}}|$BROKER_PORT|g' "$rl"
check_contains "relay.sh：--broker-port 可配" "--broker-port)" "$rl"
check_contains "relay.sh：broker 端口默认 18081" "BROKER_PORT=18081" "$rl"
check_contains "relay.sh：自检也看 broker 那条" "token broker：302" "$rl"

# ② harness 函数（env.zsh / env.bash）：把 dsh web 打印的 token 抓下来、退出时清掉
wait_for_file() {
    _i=0
    while [ "$_i" -lt 50 ]; do
        [ -s "$1" ] && return 0
        sleep 0.1
        _i=$((_i + 1))
    done
    return 1
}
mkdir -p "$TMP/kbin" "$TMP/kstate" "$TMP/kconf" "$TMP/k-nohome"
# ① harness（前台那条路）抓 token：桩 npx 打印那行带 token 的地址，**真绑一下回环端口**
#    （新版 harness 是"端口一出现就开浏览器"；不绑的话它会等到超时才放弃）。
cat >"$TMP/kbin/npx" <<'STUB'
#!/bin/sh
python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',3085)); s.listen(1); time.sleep(2)" &
echo "booting the web profile…"
echo "dsh web: http://127.0.0.1:3085/?token=Tok-123_abc (LAN: http://10.0.0.2:3085/?token=Tok-123_abc)"
wait
STUB
chmod +x "$TMP/kbin/npx"
printf 'public_url=https://entry.example:8443\nlocal_port=3085\n' >"$TMP/kconf/remote.conf"
for shname in bash zsh; do
    if ! command -v "$shname" >/dev/null 2>&1; then
        ok "没有 $shname，跳过它那份 env"
        continue
    fi
    envf="$proj/env.$shname"
    [ -f "$envf" ] || envf="$proj/env.bash"
    rm -f "$TMP/kstate/current-token.txt" "$TMP/kstate/web-url.txt"
    PATH="$TMP/kbin:$PATH" DSH_REMOTE_STATE_DIR="$TMP/kstate" DSH_REMOTE_CONF_DIR="$TMP/kconf" \
        DSH_HARNESS_OPENER=quiet DSH_REMOTE_HARNESS_WAIT=6 DSH_REMOTE_HARNESS_UNIT=none \
        "$shname" -c ". '$envf'; harness --no-open" >"$TMP/k-$shname.out" 2>&1
    check "$shname：前台那条路退出 0" "0" "$?"
    check_contains "$shname：抓到 token（token 文件是在跑的时候写的）" \
        "已捕获 token" "$(cat "$TMP/k-$shname.out")"
    check "$shname：退出后 token 文件清掉了（broker 会回 503，而不是 302 到死 token）" "yes" \
        "$([ -e "$TMP/kstate/current-token.txt" ] && echo no || echo yes)"
    check_contains "$shname：浏览器那半按契约（quiet → 只打印 URL）" \
        "URL: http://127.0.0.1:3085/" "$(cat "$TMP/k-$shname.out")"
    check_contains "$shname：npx 的输出原样转出来了" "booting the web profile…" "$(cat "$TMP/k-$shname.out")"
    check "（$shname）抓到的 token 值正确（不是行尾 LAN 那个）" "1" \
        "$(grep -q 'Tok-123_abc' "$TMP/k-$shname.out" && echo 1 || echo 0)"
done

# ②b 容错：这次**没抓到** token（npx 没打印那行）→ 不许把别人写的 token 文件清掉
cat >"$TMP/kbin/npx" <<'STUB'
#!/bin/sh
echo "dsh web: 端口被占了，起不来"
STUB
chmod +x "$TMP/kbin/npx"
printf 'OLD-TOKEN-from-running-instance\n' >"$TMP/kstate/current-token.txt"
chmod 600 "$TMP/kstate/current-token.txt"
PATH="$TMP/kbin:$PATH" DSH_REMOTE_STATE_DIR="$TMP/kstate" DSH_REMOTE_CONF_DIR="$TMP/kconf" \
    DSH_HARNESS_OPENER=quiet DSH_REMOTE_HARNESS_WAIT=2 DSH_REMOTE_HARNESS_UNIT=none \
    bash -c ". '$proj/env.bash'; harness --no-open" >"$TMP/k-nocap.out" 2>&1
check "没抓到 token 时 harness 退出 0（不炸）" "0" "$?"
check "没抓到 token：**旧 token 文件原样留着**（H22 那条教训）" "OLD-TOKEN-from-running-instance" \
    "$(cat "$TMP/kstate/current-token.txt" 2>/dev/null)"
check_contains "没抓到 token：打一行说明，别装没事" "没抓到 token" "$(cat "$TMP/k-nocap.out")"
rm -f "$TMP/kstate/current-token.txt"

# ③ broker 本体：起真进程（python3 + 假 dsh web 夹具 —— 401/200/303/500 四种响应都造得出来）
#    夹具按 cookie 的值决定行为：good=200 首页 / loop=303 回入口 / boom=500 / slow=拖过超时 / 其它=401
k_wport=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
k_bport=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
k_bport2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
: >"$TMP/k-web.log"
python3 "$proj/tests/fake_dsh_web.py" --port "$k_wport" --token Tok-456 --slow-seconds 1.5 \
    --log "$TMP/k-web.log" >"$TMP/k-web.out" 2>&1 &
k_wpid=$!
python3 "$proj/bin/dsh-token-broker" --port "$k_bport" --web-port "$k_wport" \
    --token-file "$TMP/k-tok.txt" >"$TMP/k-broker.log" 2>&1 &
k_bpid=$!
k_i=0
while [ "$k_i" -lt 30 ]; do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$k_bport/" && break
    sleep 0.1
    k_i=$((k_i + 1))
done
check "broker：没有 token 文件 → 503（不 302 到空 token）" "503" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$k_bport/")"
check "broker：没有 token 文件 + 带 cookie → 也是 503（先看 token，不拿 cookie 去探）" "503" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Cookie: dsh-auth-probe=good' "http://127.0.0.1:$k_bport/")"
check "broker：没有 token 时**一次都没碰** dsh web（夹具日志还是空的）" "0" \
    "$(wc -l <"$TMP/k-web.log" | tr -d ' ')"
printf 'Tok-456\n' >"$TMP/k-tok.txt"
k_hdr=$(curl -s -D - -o /dev/null --max-time 5 "http://127.0.0.1:$k_bport/")
check_contains "broker：有 token → 302" "302" "$k_hdr"
check_contains "broker：Location 指向当前 token" "Location: /?token=Tok-456" "$k_hdr"
check "broker：/go 也 302（cookie 过期后的重进入口）" "302" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$k_bport/go")"
check "broker：别的路径 404（它只做重定向）" "404" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$k_bport/api/x")"
check "broker：POST 405" "405" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 5 "http://127.0.0.1:$k_bport/")"
if command -v ss >/dev/null 2>&1; then
    check_contains "broker：只绑回环（不是 0.0.0.0）" "127.0.0.1:$k_bport" \
        "$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -F ":$k_bport" | head -n 1)"
else
    ok "没有 ss，跳过「只绑回环」那条"
fi

# ③b cookie 那条路（ADR-0018）：过期 → 补 token 并清 cookie；有效 → 代发首页；判断不出来 → 503
k_stale=$(curl -s -D - -o /dev/null --max-time 5 -H 'Cookie: dsh-auth-stale=x' "http://127.0.0.1:$k_bport/")
check_contains "过期 cookie：/ → 302（不再把 dsh web 的 401 甩给手机）" "302" "$k_stale"
check_contains "过期 cookie：Location 还是补 token" "Location: /?token=Tok-456" "$k_stale"
check_contains "过期 cookie：顺手 Set-Cookie 清掉那条失效 cookie" \
    "Set-Cookie: dsh-auth-stale=; Max-Age=0; Path=/" "$k_stale"

k_before=$(wc -l <"$TMP/k-web.log" | tr -d ' ')
curl -s -D "$TMP/k-good.hdr" -o "$TMP/k-good.html" --max-time 5 \
    -w '%{http_code} %{num_redirects}' -H 'Cookie: dsh-auth-probe=good' "http://127.0.0.1:$k_bport/" \
    >"$TMP/k-good.code"
k_after=$(wc -l <"$TMP/k-web.log" | tr -d ' ')
check "有效 cookie：/ → 200（broker 代发首页，不是 302）" "200 0" "$(cat "$TMP/k-good.code")"
check_contains "有效 cookie：拿回来的就是首页（title 在）" "<title>DeepSeek Harness</title>" \
    "$(cat "$TMP/k-good.html")"
check_contains "有效 cookie：上游的 Set-Cookie 原样透传" "dsh-auth-probe=refreshed" \
    "$(cat "$TMP/k-good.hdr")"
check_contains "有效 cookie：上游的其它响应头也透传（Content-Security-Policy）" \
    "Content-Security-Policy: default-src 'self'" "$(cat "$TMP/k-good.hdr")"
check "有效 cookie：先探测、再代发 —— 打到 dsh web 恰好 2 条请求" "2" "$((k_after - k_before))"

k_loop=$(curl -s -D - -o /dev/null --max-time 5 -H 'Cookie: dsh-auth-x=loop' "http://127.0.0.1:$k_bport/")
check_contains "探到 3xx 但 Location 指回入口：换成 token 跳转（不许原样转发转圈）" \
    "Location: /?token=Tok-456" "$k_loop"
check "探到判断不出有效性的状态码（500）→ 503，不乱跳" "503" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Cookie: dsh-auth-x=boom' "http://127.0.0.1:$k_bport/")"
check "不是 dsh-auth-* 的 cookie 当没有 cookie：302（不拿别人家 cookie 去探）" "302" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Cookie: session=abc' "http://127.0.0.1:$k_bport/")"
check "/go 带有效 cookie 也还是 302（重进入口语义不变）" "302" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Cookie: dsh-auth-probe=good' "http://127.0.0.1:$k_bport/go")"

# 探测超时那条单起一个 broker（探测超时调短，别让测试干等 3 秒）
python3 "$proj/bin/dsh-token-broker" --port "$k_bport2" --web-port "$k_wport" \
    --token-file "$TMP/k-tok.txt" --probe-timeout 0.3 >"$TMP/k-broker2.log" 2>&1 &
k_bpid2=$!
k_i=0
while [ "$k_i" -lt 30 ]; do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$k_bport2/" && break
    sleep 0.1
    k_i=$((k_i + 1))
done
check "探测超时（dsh web 拖着不回）→ 503，不跳转" "503" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Cookie: dsh-auth-x=slow' "http://127.0.0.1:$k_bport2/")"
check_contains "探测超时那条在日志里说清了原因" "探测 127.0.0.1:$k_wport/ 失败" "$(cat "$TMP/k-broker2.log")"
kill "$k_bpid2" 2>/dev/null
wait "$k_bpid2" 2>/dev/null

kill "$k_wpid" 2>/dev/null
sleep 0.3
check "broker：dsh web 没在听 → 503（宁可说没跑，也别送去死 token）" "503" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$k_bport/")"
check "broker：dsh web 没在听 + 带 cookie → 也是 503" "503" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Cookie: dsh-auth-probe=good' "http://127.0.0.1:$k_bport/")"
kill "$k_bpid" 2>/dev/null
wait "$k_bpid" 2>/dev/null
check_contains "broker：启动时把监听地址和 token 文件打出来" \
    "dsh-token-broker: http://127.0.0.1:$k_bport/" "$(cat "$TMP/k-broker.log")"

# ------------------------------------------------- L 二维码（手机扫的那个）
printf 'L. 二维码：dsh-qr（矩阵对账 / PNG / SVG / 终端画 / 太长要报错）\n'
# 那些 sha256 是**和一份独立实现对过账**的：npm 自带的 qrcode-terminal 里那份
# Kazuhiko Arase 的 JS 实现（MIT），逐模块比过（见 journal 2026-10-07）。
# 只在"同一版本 + 同一掩码"下比 —— 两边挑掩码的罚分规则不一样（它那份是老式
# 启发式，不是 ISO §8.8.2），所以先定掩码再对矩阵；能对上就说明**编码/纠错/
# 交织/摆位/格式位**全对。
qrbin="$proj/bin/dsh-qr"
qr_hash() { # 文本 纠错 → border=0 矩阵的 sha256
    python3 "$qrbin" --ecc "$2" --border 0 --matrix --no-terminal "$1" 2>/dev/null | sha256sum | cut -d' ' -f1
}
check "dsh-qr：'hi'（v1/M）矩阵与独立实现逐字一致" \
    "b0b09bb15298d7c3e024c7f0193f0c90f8311f7244cc72884d453e04157289e1" "$(qr_hash "hi" M)"
check "dsh-qr：入口 URL（v3/M）矩阵一致" \
    "b5296439fc3fa8fe56843913c64115719a2686dabebc66829a3ede6fdd7c478b" "$(qr_hash "https://123.56.158.212:8443/" M)"
check "dsh-qr：/go 那个 URL（v3/Q）矩阵一致" \
    "e5454b351f541519f1e89f33d65ae67f2bd1d7f0921370743ed8ad0225f4b396" "$(qr_hash "https://123.56.158.212:8443/go" Q)"
check "dsh-qr：短 URL（v2/L）矩阵一致" \
    "66ce90bbf75bfb5a82ecf74a96fc791ab909b2cd33be661312046f1306b29728" "$(qr_hash "https://123.56.158.212:8443" L)"
check "dsh-qr：200 字节（v10/M）矩阵一致" \
    "f83a5f24178f5fe17d23c7d9c8e84a80ad26413329140183816b46da79ca33f9" "$(qr_hash "$(python3 -c 'print("A"*200)')" M)"
check "dsh-qr：500 字节（v15/L）矩阵一致" \
    "f3fa4a69a926b46f5fc7aff557a30362f9da3456213e76674c5acaf2bea9f424" "$(qr_hash "$(python3 -c 'print("B"*500)')" L)"
# 中文/emoji：那份 JS 实现对非 ASCII 是**坏的**（charCodeAt 截成 8 位，不做 UTF-8），
# 所以这里只做"能编出来 + 尺寸对"的自检，不和它比。
zh=$(python3 "$qrbin" --ecc M --border 0 --matrix --no-terminal "中文测试：手机扫码进会话 🎉" 2>/dev/null)
check "dsh-qr：中文/emoji 能编出来（v3 = 29 模块）" "29" "$(printf '%s\n' "$zh" | wc -l | tr -d ' ')"
# 太长要**报错**，不能悄悄截断
python3 "$qrbin" --ecc H --border 0 --matrix --no-terminal "$(python3 -c 'print("Z"*3000)')" >/dev/null 2>"$TMP/l-err.txt"
l_rc=$?
if [ "$l_rc" -ne 0 ] && grep -q '放不下' "$TMP/l-err.txt"; then
    ok "dsh-qr：内容太长时报错（不偷偷截断）"
else
    bad "dsh-qr：内容太长时报错（不偷偷截断）" "rc=$l_rc $(cat "$TMP/l-err.txt")"
fi
# 终端画：半块字符 + 自带颜色（别管终端什么配色）
python3 "$qrbin" --ecc M --border 2 "hi" >"$TMP/l-term.txt" 2>/dev/null
check "dsh-qr：终端画是半块字符（(21+4+1)/2 = 13 行）" "13" "$(wc -l <"$TMP/l-term.txt" | tr -d ' ')"
check_contains "dsh-qr：终端画自带前景/背景色（ESC 序列）" "$(printf '\033')[3" "$(head -1 "$TMP/l-term.txt")"
# PNG / SVG 落盘（PNG 是 1 位灰度、手写的 zlib+struct）
python3 "$qrbin" --ecc M --border 4 --scale 1 --no-terminal --png "$TMP/l.png" --svg "$TMP/l.svg" "hi" >/dev/null 2>&1
l_png=$(python3 -W ignore -c '
import struct, sys
with open(sys.argv[1], "rb") as fh:
    d = fh.read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "PNG 签名不对"
w, h, depth, ctype = struct.unpack(">IIBB", d[16:26])
assert (depth, ctype) == (1, 0), (depth, ctype)
print("%dx%d" % (w, h))
' "$TMP/l.png" 2>&1)
check "dsh-qr：--scale 1 时 PNG 是「模块=像素」（21+8=29）、1 位灰度" "29x29" "$l_png"
check_contains "dsh-qr：SVG 是纯文本、带 viewBox" 'viewBox="0 0 29 29"' "$(cat "$TMP/l.svg")"

# 高分辨率：手机扫得动的那张图（默认把短边做到 ≥1024px、每模块整数倍、静默区默认 4）
l_url="https://123.56.158.212:8443"
l_mod=$(python3 "$qrbin" --ecc M --border 4 --matrix --no-terminal "$l_url" 2>/dev/null | wc -l | tr -d ' ')
python3 "$qrbin" --ecc M --border 4 --no-terminal --png "$TMP/l-big.png" --svg "$TMP/l-big.svg" "$l_url" >/dev/null 2>&1
l_expect=$((l_mod * ((1024 + l_mod - 1) / l_mod)))
l_got=$(python3 -W ignore -c '
import struct, sys
with open(sys.argv[1], "rb") as fh:
    d = fh.read()
w, h, depth, ctype = struct.unpack(">IIBB", d[16:26])
print("%dx%d depth=%d ctype=%d" % (w, h, depth, ctype))
' "$TMP/l-big.png" 2>&1)
check "dsh-qr：大图 PNG = 模块数×整数 scale（$l_mod 模块 → ${l_expect}px）、1 位灰度" \
    "${l_expect}x${l_expect} depth=1 ctype=0" "$l_got"
if [ "$l_expect" -ge 1024 ]; then
    ok "dsh-qr：大图短边 ≥1024px（手机上不用放大也扫得动）"
else
    bad "dsh-qr：大图短边 ≥1024px（手机上不用放大也扫得动）" "$l_expect"
fi
check_contains "dsh-qr：SVG 的 width/height 与 PNG 同步" \
    "width=\"$l_expect\" height=\"$l_expect\"" "$(cat "$TMP/l-big.svg")"
check_contains "dsh-qr：SVG 用模块坐标当 viewBox（矢量、放大不糊）" \
    "viewBox=\"0 0 $l_mod $l_mod\"" "$(cat "$TMP/l-big.svg")"
# 显式 --scale 也要听
python3 "$qrbin" --ecc M --border 1 --scale 3 --no-terminal --png "$TMP/l-s3.png" "$l_url" >/dev/null 2>&1
check "dsh-qr：--scale 3 + border 1 → (29+2)*3 = 93px" "93x93 depth=1 ctype=0" \
    "$(python3 -W ignore -c '
import struct, sys
with open(sys.argv[1], "rb") as fh:
    d = fh.read()
w, h, depth, ctype = struct.unpack(">IIBB", d[16:26])
print("%dx%d depth=%d ctype=%d" % (w, h, depth, ctype))
' "$TMP/l-s3.png" 2>&1)"

# ------------------------------------------------- M server（一条命令装好）
printf 'M. dsh-remote server：自检失败给指引 / --dry-run 不写 / 全参非交互跑通\n'
# 全程用假的 ssh / scp / curl + 临时 unit 目录：不碰真云、不碰真 unit、不碰真 conf
mstub="$TMP/mstub"
mkdir -p "$mstub"
cat >"$mstub/ssh" <<'STUB'
#!/bin/sh
printf 'SSH: %s\n' "$*" >>"$M_LOG"
cmd=
for a in "$@"; do cmd=$a; done
case $cmd in
*"id -un"*) printf '%s\n' "${M_REMOTE_USER:-alice}"; exit 0 ;;
*"sudo -n true"*) [ "${M_SUDO:-1}" = 1 ] && exit 0 || exit 1 ;;
*"sudo -n docker info"*) [ "${M_SUDO_DOCKER:-1}" = 1 ] && exit 0 || exit 1 ;;
*"docker info"*) [ "${M_DOCKER:-1}" = 1 ] && exit 0 || exit 1 ;;
*"command -v docker"*) [ "${M_HAS_DOCKER:-1}" = 1 ] && exit 0 || exit 1 ;;
*"ss -ltn"*) printf '%s\n' "${M_OCC:-0}"; exit 0 ;;
*"ps --filter name=dsh-relay"*) printf '%s\n' "${M_OWN:-}" ; exit 0 ;;
*"relay.sh"*) printf '== 假 relay.sh 输出\n'; exit "${M_DEPLOY_RC:-0}" ;;
esac
exit 0
STUB
cat >"$mstub/scp" <<'STUB'
#!/bin/sh
printf 'SCP: %s\n' "$*" >>"$M_LOG"
STUB
cat >"$mstub/curl" <<'STUB'
#!/bin/sh
printf 'CURL: %s\n' "$*" >>"$M_LOG"
printf '%s' "${M_CURL_CODE:-401}"
STUB
chmod +x "$mstub/ssh" "$mstub/scp" "$mstub/curl"
mconf="$TMP/m-remote.conf"
printf 'cloud_host=203.0.113.7\ncloud_user=alice\ncloud_ssh_port=22\nremote_port=18080\nlocal_port=3080\npublic_url=\n' >"$mconf"
export M_LOG="$TMP/m.log" M_SUDO=1 M_DOCKER=1 M_SUDO_DOCKER=1 M_HAS_DOCKER=1 M_OCC=0 M_OWN= M_REMOTE_USER=alice M_CURL_CODE=401 M_DEPLOY_RC=0
: >"$M_LOG"
# mrun：把假命令 + 临时落点钉住，跑真的 bin/dsh-remote
mrun() {
    PATH="$mstub:$PATH" DSH_REMOTE_CONF="$mconf" DSH_REMOTE_UNIT_DIR="$TMP/munits" \
        DSH_REMOTE_SYSTEMCTL="$jstub/systemctl" DSH_REMOTE_TMUX="$jstub/tmux" \
        DSH_REMOTE_STATE_DIR="$TMP/mstate" "$remote" "$@"
}
mset() { M_SUDO=1 M_DOCKER=1 M_SUDO_DOCKER=1 M_HAS_DOCKER=1 M_OCC=0 M_OWN= M_REMOTE_USER=alice M_CURL_CODE=401 M_DEPLOY_RC=0; }
mbase_args="server --host 203.0.113.7 --ssh-user alice --ssh-port 22 --port 9443 --web-user dsh --dir /home/mindul/dsh-relay"

# ① --dry-run：只打印计划，一个字节都不写
: >"$M_LOG"
rm -rf "$TMP/munits" "$TMP/mstate"
mkdir -p "$TMP/mstate"
mset
mrun $mbase_args --password dryrunpw123 --yes --dry-run >"$TMP/m1.out" 2>&1
check "server --dry-run 退出 0" "0" "$?"
m1=$(cat "$TMP/m1.out")
check_contains "dry-run 里说要 scp cloud/" "cloud/" "$m1"
check_contains "dry-run 里说要 relay.sh --no-compose" "--no-compose" "$m1"
check_contains "dry-run 里带上了 broker 端口" "--broker-port 18081" "$m1"
check_contains "dry-run 里说要装 broker 单元" "dsh-token-broker.service" "$m1"
check_contains "dry-run 里说要打二维码/地址" "二维码" "$m1"
check "dry-run 没 scp（没碰云）" "0" "$(grep -c SCP "$M_LOG" || true)"
check "dry-run 没装单元" "" "$(ls -A "$TMP/munits" 2>/dev/null)"
check "dry-run 没改 remote.conf" "public_url=" "$(grep '^public_url=' "$mconf")"

# ② ssh 自检失败：教怎么配 key
M_SUDO=0 M_DOCKER=0 M_SUDO_DOCKER=0
mrun $mbase_args --password pw --yes --dry-run >"$TMP/m2.out" 2>&1
check "ssh 自检失败 → 非 0" "1" "$?"
check_contains "ssh 失败时给出 ssh-copy-id 的修法" "ssh-copy-id" "$(cat "$TMP/m2.out")"
check_contains "ssh 失败时点明「不问密码」才算数" "不问密码" "$(cat "$TMP/m2.out")"

# ③ 不在 docker 组（docker info 不行）但 `sudo -n docker` 行 → 自动改用 sudo docker
mset
M_DOCKER=0 M_SUDO_DOCKER=1
mrun $mbase_args --password pw --yes --dry-run >"$TMP/m3.out" 2>&1
check "不在 docker 组但 sudo docker 行 → 退出 0" "0" "$?"
check_contains "认出来要用 sudo docker" "用「sudo docker」" "$(cat "$TMP/m3.out")"
check_contains "dry-run 里的 docker 命令也是 sudo docker" "--docker-cmd 'sudo docker'" "$(cat "$TMP/m3.out")"

# ③b 两种 docker 都不行 → 非 0 + 给出配 sudo 的办法
mset
M_DOCKER=0 M_SUDO_DOCKER=0
mrun $mbase_args --password pw --yes --dry-run >"$TMP/m3b.out" 2>&1
check "docker daemon 不可用 → 非 0" "1" "$?"
check_contains "给出只放开 docker 的做法" "NOPASSWD: /usr/bin/docker" "$(cat "$TMP/m3b.out")"

# ④ 云上没有 docker：说清「工具不代劳 + 该装什么」
mset
M_HAS_DOCKER=0

mrun $mbase_args --password pw --yes --dry-run >"$TMP/m4.out" 2>&1
check "没 docker → 非 0" "1" "$?"
check_contains "没 docker 时给出装法（但不代跑）" "apt install -y docker.io" "$(cat "$TMP/m4.out")"

# ⑤ 端口被别人的东西占着
mset
M_OCC=1 M_OWN=
mrun $mbase_args --password pw --yes --dry-run >"$TMP/m5.out" 2>&1
check "端口被别人占 → 非 0" "1" "$?"
check_contains "端口被占时建议换一个" "已经被别的东西占着" "$(cat "$TMP/m5.out")"

# ⑥ 远端用户和配置里写的不是一个人 → 拦下来（身份对不上是 H16 那类坑）
mset
M_REMOTE_USER=bob
mrun $mbase_args --password pw --yes --dry-run >"$TMP/m6.out" 2>&1
check "远端用户和 --ssh-user 不一致 → 非 0" "1" "$?"
check_contains "不一致时点明身份对不上" "身份对不上" "$(cat "$TMP/m6.out")"

# ⑦ 密码里有空格 → 直接拒（要塞进远程命令行）
mset
mrun $mbase_args --password "bad pw" --yes --dry-run >"$TMP/m7.out" 2>&1
check "密码里有空格 → 非 0" "1" "$?"
check_contains "拒绝时说清为什么" "别用引号" "$(cat "$TMP/m7.out")"

# ⑧ 全参非交互（--yes）：部署 + 家里两个单元 + 回写 conf；harness 不让它起
mset
: >"$M_LOG"
rm -rf "$TMP/munits"
mkdir -p "$TMP/munits"
mrun $mbase_args --password GoodPass123 --yes --no-harness >"$TMP/m8.out" 2>&1
check "server --yes --no-harness 退出 0" "0" "$?"
m8=$(cat "$TMP/m8.out")
mlog=$(cat "$M_LOG")
check_contains "部署：scp 了 cloud/ 目录" "SCP: " "$mlog"
check_contains "部署：远程命令用 --no-compose" "--no-compose" "$mlog"
check_contains "部署：远程命令带 broker 端口" "--broker-port 18081" "$mlog"
check_contains "部署：远程命令带对外端口 9443" "--port 9443" "$mlog"
check_contains "部署：远程命令带用户名" "--user dsh" "$mlog"
check_contains "部署：远程命令带密码（哈希由 relay.sh 算）" "--password 'GoodPass123'" "$mlog"
check_contains "部署：docker 命令按自检结果传" "--docker-cmd 'docker'" "$mlog"
check_contains "家里：装了 broker 单元" "dsh-token-broker.service" "$(ls "$TMP/munits")"
check_contains "家里：装了隧道单元" "dsh-tunnel.service" "$(ls "$TMP/munits")"
check_contains "回写了 cloud_host" "cloud_host=203.0.113.7" "$(cat "$mconf")"
check_contains "回写了 public_url" "public_url=https://203.0.113.7:9443" "$(cat "$mconf")"
check_contains "回写了 broker 端口" "broker_remote_port=18081" "$(cat "$mconf")"
check_contains "打印了手机地址" "https://203.0.113.7:9443" "$m8"
check_contains "打印了怎么改密码" "改密码" "$m8"
check_contains "--no-harness 时给出手动起法" "harness --no-open" "$m8"

# ⑧b 云上部署失败（relay.sh 非 0）：必须报错，不能吞 ——
#     `ssh … | tee` 拿到的是 tee 的退出码，真机第一版就是这么"成功"过去的
mset
M_DEPLOY_RC=2
mrun $mbase_args --password pw --yes --no-harness >"$TMP/m8b.out" 2>&1
check "云上部署失败 → 非 0" "1" "$?"
check_contains "部署失败时说清 rc" "云上那步没成功" "$(cat "$TMP/m8b.out")"

# ⑨ 薄封装 dsh-remote-server 走同一条路
mset
PATH="$mstub:$PATH" DSH_REMOTE_CONF="$mconf" DSH_REMOTE_UNIT_DIR="$TMP/munits" \
    DSH_REMOTE_SYSTEMCTL="$jstub/systemctl" DSH_REMOTE_TMUX="$jstub/tmux" \
    DSH_REMOTE_STATE_DIR="$TMP/mstate" "$proj/bin/dsh-remote-server" \
    --host 203.0.113.7 --ssh-user alice --port 9443 --web-user dsh --password pw --yes --dry-run >"$TMP/m9.out" 2>&1
check "dsh-remote-server（薄封装）退出 0" "0" "$?"
check_contains "薄封装走的是同一条路（打印计划）" "--no-compose" "$(cat "$TMP/m9.out")"
check_contains "薄封装也用 cloud_host 作默认" "203.0.113.7" "$(cat "$TMP/m9.out")"

# ------------------------------------------------- N 改密码（dsh-remote passwd）
printf 'N. dsh-remote passwd：只改哈希那一行 / 验旧新 / 密码文件同步（全用桩）\n'
nstub="$TMP/nstub"
mkdir -p "$nstub"
cat >"$nstub/ssh" <<'STUB'
#!/bin/sh
printf 'SSH: %s\n' "$*" >>"$N_LOG"
cmd=
for a in "$@"; do cmd=$a; done
case $* in
*"sh -s"*) cat >>"$N_SCRIPT"; exit 0 ;;
esac
case $cmd in
*"docker info"*) [ "${N_DOCKER:-1}" = 1 ] && exit 0 || exit 1 ;;
*"hash-password"*) [ "${N_HASH_OK:-1}" = 1 ] && printf '%s\n' "${N_HASH:-\$2a\$14\$FAKEHASHFAKEHASHFAKEHASHFAKEHASHFAKEHASHFAKEHASH}" || printf 'boom\n' ; exit 0 ;;
*"PASSWORD="*) printf '%s\n' "${N_OLDPW:-oldpw-from-file}"; exit 0 ;;
esac
exit 0
STUB
cat >"$nstub/curl" <<'STUB'
#!/bin/sh
printf 'CURL: %s\n' "$*" >>"$N_LOG"
cred=
prev=
for a in "$@"; do
    [ "$prev" = "-u" ] && cred=$a
    prev=$a
done
case $cred in
*":${N_NEWPW:-NewPass123}") printf '%s' "${N_NEWCODE:-302}" ;;
*) printf '%s' "${N_OLDCODE:-401}" ;;
esac
STUB
chmod +x "$nstub/ssh" "$nstub/curl"
export N_LOG="$TMP/n.log" N_SCRIPT="$TMP/n-script.txt" N_HASH_OK=1 N_DOCKER=1 N_OLDPW=oldpw-from-file N_NEWPW=NewPass123 N_NEWCODE=302 N_OLDCODE=401
: >"$N_LOG"
: >"$N_SCRIPT"
nconf="$TMP/n-remote.conf"
cat >"$nconf" <<EOF
cloud_host=203.0.113.7
cloud_user=alice
cloud_ssh_port=22
identity=~/.ssh/id_x
public_url=https://203.0.113.7:9443/
EOF
nrun() {
    PATH="$nstub:$PATH" DSH_REMOTE_CONF="$nconf" DSH_REMOTE_HOME="$TMP/nhome" \
        DSH_REMOTE_IFACE= "$remote" "$@"
}

# ① --dry-run：一个字节都不改、不碰云
: >"$N_LOG"
nrun passwd --password NewPass123 --dry-run >"$TMP/n1.out" 2>&1
check "passwd --dry-run 退出 0" "0" "$?"
n1=$(cat "$TMP/n1.out")
check_contains "dry-run 说清会只改哈希那一行" "只把 basic_auth 里 dsh 那行的哈希换掉" "$n1"
check_contains "dry-run 说清会验旧/新" "旧密码应 401" "$n1"
check "dry-run 没连云（没调 ssh）" "0" "$(grep -c SSH "$N_LOG" || true)"

# ② 真跑（桩）：算哈希 → 只改那一行 → restart → 验旧/新
: >"$N_LOG"
: >"$N_SCRIPT"
nrun passwd --password NewPass123 >"$TMP/n2.out" 2>&1
check "passwd 退出 0" "0" "$?"
nlog=$(cat "$N_LOG")
check_contains "在云上用真实镜像算哈希（不是本地）" "run --rm caddy:2.11.4 caddy hash-password --plaintext 'NewPass123'" "$nlog"
check_contains "远端脚本里是 awk 精确换哈希（不是整份重渲染）" "sub(/\\\$2[aby]\\\$" "$(cat "$N_SCRIPT")"
check_contains "远端脚本只重启 dsh-relay" "restart dsh-relay" "$(cat "$N_SCRIPT")"
check_contains "远端脚本同步 relay-password.txt" "relay-password.txt" "$(cat "$N_SCRIPT")"
check_contains "远端脚本把密码文件 chmod 600" "chmod 600 relay-password.txt" "$(cat "$N_SCRIPT")"
n2=$(cat "$TMP/n2.out")
check_contains "验新密码（302 = 过）" "新密码：HTTP 302 ✓" "$n2"
check_contains "验旧密码（401 = 已被换掉）" "旧密码：401 ✓" "$n2"
check_contains "打印手机怎么用新密码" "手机怎么用" "$n2"

# ③ 旧密码 == 新密码时不打"旧密码被换掉"（免得自欺）
: >"$N_LOG"
N_OLDPW=NewPass123 nrun passwd --password NewPass123 >"$TMP/n3.out" 2>&1
check "旧密码和新密码一样时退出 0" "0" "$?"
check_not_contains "旧密码==新密码：不谎报「已经被换掉」" "旧密码：401" "$(cat "$TMP/n3.out")"

# ④ 云上 docker 用不了 → 非 0 + 说清
N_DOCKER=0 nrun passwd --password NewPass123 >"$TMP/n4.out" 2>&1
check "云上 docker 不可用 → 非 0" "1" "$?"
check_contains "说清是 docker 的问题" "docker 用不了" "$(cat "$TMP/n4.out")"

# ⑤ 哈希算不出来（镜像不在/太老）→ 非 0，别把旧哈希改坏
N_DOCKER=1 N_HASH_OK=0 nrun passwd --password NewPass123 >"$TMP/n5.out" 2>&1
check "哈希算不出来 → 非 0" "1" "$?"
check_contains "提示去查 caddy 镜像" "caddy:2.11.4 镜像在吗" "$(cat "$TMP/n5.out")"

# ⑥ 密码里有引号 → 直接拒（要塞进远程命令行）
nrun passwd --password "bad'pw" >"$TMP/n6.out" 2>&1
check "密码里有单引号 → 非 0" "1" "$?"
check_contains "拒绝时说清为什么（单引号）" "别用单引号" "$(cat "$TMP/n6.out")"

# ⑦ help 里有这条命令
check_contains "help 里有 passwd" "dsh-remote passwd" "$("$remote" help)"

# ------------------------------------------------- O dsh web 常驻 + harness 复用
printf 'O. dsh web 常驻：单元渲染 / 端口被占不抢 / harness 四态输出契约 / 代理\n'

# ① serve-install --dry-run 的单元内容（一个字节都不写）
"$remote" serve-install --dry-run >"$TMP/o1.out" 2>&1
check "serve-install --dry-run 退出码 0" "0" "$?"
check_contains "ExecStart 跑 dsh-web-run" "dsh-web-run --port" "$(cat "$TMP/o1.out")"
check_contains "Restart=always" "Restart=always" "$(cat "$TMP/o1.out")"
check_contains "RestartSec=30（端口被占时别每 3 秒敲门）" "RestartSec=30" "$(cat "$TMP/o1.out")"
check_contains "WantedBy=default.target（开机自启）" "WantedBy=default.target" "$(cat "$TMP/o1.out")"
# 回归守卫：ExecStartPost 在"端口被占 → 本服务立刻退出 → 每 30 秒重试"里**也会跑**，
# 于是隧道被反复重启、手机链路每 30 秒断一次（2026-10-07 实测踩到；重连已挪进 dsh-web-run）。
if grep -q '^ExecStartPost=' "$TMP/o1.out"; then
    bad "单元里不该有 ExecStartPost（会把隧道每 30 秒重启一次）" ""
else
    ok "单元里没有 ExecStartPost（重连只在真抓到 token 时做）"
fi

# ② dsh-web-run：假 npx → 抓 token；**退出后不删** token（服务语义）
ostub="$TMP/ostub"
mkdir -p "$ostub"
cat >"$ostub/npx" <<'STUB'
#!/bin/sh
printf 'dsh web: http://127.0.0.1:3999/?token=OTOK (LAN: http://10.0.0.9:3999)\n'
STUB
chmod +x "$ostub/npx"
os="$TMP/ostate"
mkdir -p "$os"
PATH="$ostub:$PATH" XDG_STATE_HOME="$os" DSH_REMOTE_CONF_DIR="$TMP/oconf" DSH_REMOTE_NO_TUNNEL_RESTART=1 \
    sh "$proj/bin/dsh-web-run" --port 3999 >"$TMP/o2.out" 2>&1
check "dsh-web-run 抓到 token 后正常退出" "0" "$?"
check "token 文件内容" "OTOK" "$(cat "$os/dsh-remote/current-token.txt" 2>/dev/null)"
check "web-url 文件内容" "http://127.0.0.1:3999/?token=OTOK" "$(cat "$os/dsh-remote/web-url.txt" 2>/dev/null)"
check "退出后 token 文件还在（服务不删 token）" "yes" \
    "$([ -s "$os/dsh-remote/current-token.txt" ] && echo yes || echo no)"

# ③ dsh-web-run：端口被占 → 退出 1（让 systemd 按 RestartSec 重试）、不抢
python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",3998)); s.listen(1); time.sleep(25)' &
opid=$!
sleep 1
PATH="$ostub:$PATH" XDG_STATE_HOME="$os" DSH_REMOTE_CONF_DIR="$TMP/oconf" \
    sh "$proj/bin/dsh-web-run" --port 3998 >"$TMP/o3.out" 2>&1
check "端口被占 → 退出 1" "1" "$?"
check_contains "提示不去抢端口" "已经有会话在跑" "$(cat "$TMP/o3.out")"
kill "$opid" 2>/dev/null || true
wait "$opid" 2>/dev/null || true

# ④ harness 的语义（2026-10-09 用户重做；ADR-0024）：**有则开、无则起**。
#    不许再有"等 20 秒"，**绝不起第二个实例**，开浏览器失败不算失败（rc 恒 0）。
#    两份 env 用**同一张表**跑（zsh 没装就 skip —— 项目规矩：两份必须逐字等价）。
hstub="$TMP/hstub"
mkdir -p "$hstub" "$hstub/path" "$TMP/o-nohome"
cat >"$hstub/path/systemctl" <<'STUB'
#!/bin/sh
# 桩 systemctl：只认 harness 用得到的那几种调用；H_STUB_LOG 里记一笔调用串
[ -n "${H_STUB_LOG:-}" ] && printf '%s\n' "$*" >>"$H_STUB_LOG"
case "$*" in
*"cat dsh-web.service"*) [ "${H_HAVE_UNIT:-1}" = 1 ] && exit 0 || exit 1 ;;
*is-active*) printf '%s\n' "${H_ACTIVE:-active}"; [ "${H_ACTIVE:-active}" = active ] && exit 0; exit 3 ;;
*"show dsh-web.service -p MainPID"*) printf '%s\n' "${H_MAINPID:-0}" ;;
esac
exit 0
STUB
cat >"$hstub/path/journalctl" <<'STUB'
#!/bin/sh
printf '%s\n' "${H_JOURNAL:-（桩 journal 没有内容）}"
STUB
cat >"$hstub/path/npx" <<'STUB'
#!/bin/sh
[ -n "${NPX_LOG:-}" ] && printf 'npx-args:%s\n' "$*" >>"$NPX_LOG"
# ⚠️ token 那行必须在 bind 之前打：bind 之后用 exec 会把 shell 换掉（后面的 echo 就不执行了）
printf 'dsh web: http://127.0.0.1:${NPX_PORT:-3979}/?token=HTOK (LAN: http://10.0.0.9:${NPX_PORT:-3979})\n'
[ -n "${NPX_BIND_PORT:-}" ] || exit 0
# 绑不上（端口被别人占）就**立刻退**：不然 harness 会在这儿等满它的窗口，测试挂住
python3 -c "import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
try:
    s.bind(('127.0.0.1',$NPX_BIND_PORT)); s.listen(1)
except OSError as e:
    sys.stderr.write('stub-npx: 绑不上 $NPX_BIND_PORT（%s）\n' % e); sys.exit(3)
time.sleep(6)" || exit 0
STUB
cat >"$hstub/opener" <<'STUB'
#!/bin/sh
# 桩 opener：把收到的 argc 和第一个参数**逐字节**记下来（证明 URL 没过 shell）
printf 'argc=%s\n' "$#" >"$OPEN_ARGV"
printf '%s\n' "$1" >>"$OPEN_ARGV"
STUB
chmod +x "$hstub/path/systemctl" "$hstub/path/journalctl" "$hstub/path/npx" "$hstub/opener"

free_port() { # 现挑一个空闲端口（避免写死的端口跟上一轮残留的监听器撞上）
    python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

listen_on() { # 真监听一个端口（拿真 PID 给 ss -ltnp 判）
    python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$1)); s.listen(1); time.sleep(25)" >/dev/null 2>&1 &
    printf '%s' "$!"
}

hs="$TMP/o-hstate"
hc="$TMP/o-hconf"
mkdir -p "$hs" "$hc"
for shname in bash zsh; do
    if ! command -v "$shname" >/dev/null 2>&1; then
        ok "没有 $shname：跳过 harness 语义里它那份（装 zsh 才有完整对账）"
        continue
    fi
    hrun() { # hrun [KEY=VAL…] -- <harness 的原始参数…>；状态/配置目录由外层变量给
        # ⚠️ **不能**用 `env PATH=… cmd`：这台机器的 PATH 里有 `/mnt/c/Program Files/...`
        # （带空格），env 会把它拆成两个参数（2026-10-09 实测："env: 'Files': No such file"）。
        # 所以改成"导出变量 + 在当前 shell 里跑"。
        _ev=
        while [ $# -gt 0 ]; do
            case $1 in
            --) shift; break ;;
            *=*) _ev="$_ev $1"; shift ;;
            *) break ;;
            esac
        done
        # shellcheck disable=SC2086
        export $_ev
        export DSH_REMOTE_STATE_DIR="$hs" DSH_REMOTE_CONF_DIR="$hc"
        # 从 PATH_BASE 重建（不继承上一轮留下的一长串），桩目录**前置**：
        # 前置才盖得住真的 systemctl；而 $PATH_BASE 那些目录还在，python3 照样找得到
        # （2026-10-09 实测两个极端都不行：`env PATH=…` 被空格拆开；把 PATH 清成
        #  只剩桩目录 → P 段的 broker 起不来、日志全空）。
        PATH="$hstub/path:$PATH_BASE"
        export PATH
        # HOME 指到一个**空目录**：这样 `_hr_sctl cat dsh-web.service`（桩）也找不到单元，
        # 态①/③ 才会走"手工实例"那条（真 $HOME 下有用户的真单元，会被误判成托管）
        export HOME="$TMP/o-nohome"
        # 兜底：任何一次卡住都不许把整节吊死（超时留下 124 的退出码，一眼看得到）
        timeout "${HRUN_TIMEOUT:-60}" "$shname" -c ". '$proj/env.$shname'; harness \"\$@\"" sh "$@" \
            >"$TMP/o-hr.out" 2>&1
        _hr_run_rc=$?
        # ⚠️ 这里**不要** unset 任何东西：`OPEN_ARGV=… hrun …` 那种"前缀赋值"
        # 不是通过 $_ev 传的，但一样进了环境；按 $_ev 去 unset 会误伤它
        # （2026-10-09 实测：OPEN_ARGV: parameter not set）。
        return "$_hr_run_rc"
    }

    hr_argv_is() { # hr_argv_is <期望 URL> <标签>
        _got=$(sed -n 2p "$OPEN_ARGV" 2>/dev/null)
        _n=$(sed -n 1p "$OPEN_ARGV" 2>/dev/null)
        if [ "$_got" = "$1" ] && [ "$_n" = argc=1 ]; then
            ok "$2"
        else
            bad "$2" "桩 opener 收到 [$ _n $_got]"
        fi
    }

    # 态① 端口有人听（手工实例）→ 一行状态 + 打开浏览器 + rc 0 + **不起第二个**
    rm -f "$hs/current-token.txt" "$hs/web-url.txt"
    _p1=$(free_port)
    printf 'local_port=%s\npublic_url=https://example.invalid:8443\n' "$_p1" >"$hc/remote.conf"
    _lp=$(listen_on "$_p1")
    sleep 1
    rm -f "$TMP/o-h-argv.txt"
    export OPEN_ARGV="$TMP/o-h-argv.txt"
    hrun H_HAVE_UNIT=0 DSH_HARNESS_OPENER="$hstub/opener" -- "--port" "$_p1"
    _out=$(cat "$TMP/o-hr.out")
    check "$shname 语义①：退出码 0" "0" "$_hr_run_rc"
    check_contains "$shname 语义①：第一行「已在跑 ✓」" "已在跑 ✓" "$_out"
    check_contains "$shname 语义①：说清是**手工起的**" "手工起的" "$_out"
    check_contains "$shname 语义①：打印 URL" "http://127.0.0.1:$_p1/" "$_out"
    hr_argv_is "http://127.0.0.1:$_p1/" "$shname 语义①：桩 opener 收到完整 URL（逐字节、argc=1）"
    check "$shname 语义①：≤3 行" "yes" \
        "$([ "$(wc -l <"$TMP/o-hr.out")" -le 3 ] && echo yes || echo no)"
    check "$shname 语义①：**那个端口上的 PID 没变**（没起第二个）" "$_lp" "$(ss -ltnp 2>/dev/null | grep ":$_p1 " | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
    kill "$_lp" 2>/dev/null || true
    wait "$_lp" 2>/dev/null || true

    # 态② 端口有人听 + 单元也 active 且就是那个 PID → "systemd 托管"
    rm -f "$hs/current-token.txt" "$hs/web-url.txt"
    _p2=$(free_port)
    printf 'local_port=%s\n' "$_p2" >"$hc/remote.conf"
    _lp=$(listen_on "$_p2")
    sleep 1
    rm -f "$TMP/o-h-argv.txt"
    export OPEN_ARGV="$TMP/o-h-argv.txt"
    hrun H_HAVE_UNIT=1 H_ACTIVE=active H_MAINPID="$_lp" \
        DSH_HARNESS_OPENER="$hstub/opener" -- "--port" "$_p2"
    _out=$(cat "$TMP/o-hr.out")
    check_contains "$shname 语义②：说清是 systemd 托管" "systemd 托管" "$_out"
    check_contains "$shname 语义②：还是照开浏览器" "已用" "$_out"
    hr_argv_is "http://127.0.0.1:$_p2/" "$shname 语义②：桩 opener 收到完整 URL"
    check "$shname 语义②：PID 没变" "$_lp" "$(ss -ltnp 2>/dev/null | grep ":$_p2 " | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
    kill "$_lp" 2>/dev/null || true
    wait "$_lp" 2>/dev/null || true

    # 态③ 有人听 + web-url.txt 里有**这个端口**的带 token 地址 → 打开带 token 的那个
    rm -f "$hs/current-token.txt"
    _p3=$(free_port)
    printf 'local_port=%s\n' "$_p3" >"$hc/remote.conf"
    printf 'http://127.0.0.1:%s/?token=FRESHTOK\n' "$_p3" >"$hs/web-url.txt"
    _lp=$(listen_on "$_p3")
    sleep 1
    rm -f "$TMP/o-h-argv.txt"
    export OPEN_ARGV="$TMP/o-h-argv.txt"
    hrun H_HAVE_UNIT=0 DSH_HARNESS_OPENER="$hstub/opener" -- "--port" "$_p3"
    check_contains "$shname 语义③：打印带 token 的地址" "token=FRESHTOK" "$(cat "$TMP/o-hr.out")"
    hr_argv_is "http://127.0.0.1:$_p3/?token=FRESHTOK" "$shname 语义③：开的也是带 token 的地址"
    kill "$_lp" 2>/dev/null || true
    wait "$_lp" 2>/dev/null || true

    # 态④ 没人在听 + 有单元 → start 之后端口出现 → 一行结论 + 开浏览器
    #    端口按 shell 分开：桩监听器活 25 秒，第二个 shell 跑得快会撞上同一个端口。
    _p4=$(free_port)
    rm -f "$hs/current-token.txt" "$hs/web-url.txt" "$TMP/o-h-argv.txt" \
        "$hs/.h-stub-listen.pid" "$TMP/o-h-sctl.log"
    printf 'local_port=%s\n' "$_p4" >"$hc/remote.conf"
    cat >"$hstub/path/systemctl" <<'STUB'
#!/bin/sh
[ -n "${H_STUB_LOG:-}" ] && printf '%s\n' "$*" >>"$H_STUB_LOG"
case "$*" in
*"cat dsh-web.service"*) [ "${H_HAVE_UNIT:-1}" = 1 ] && exit 0 || exit 1 ;;
*is-active*) printf '%s\n' "${H_ACTIVE:-active}"; [ "${H_ACTIVE:-active}" = active ] && exit 0; exit 3 ;;
*"show dsh-web.service -p MainPID"*) printf '%s\n' "${H_MAINPID:-0}" ;;
*"start --no-block dsh-web.service"*)
    if [ -n "${H_START_LISTEN:-}" ]; then
        python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$H_START_LISTEN)); s.listen(1); time.sleep(25)" >/dev/null 2>&1 &
        printf '%s\n' "$!" >"$H_STATE/.h-stub-listen.pid"
    fi
    [ -n "${H_START_URL:-}" ] && printf '%s\n' "$H_START_URL" >"$H_STATE/web-url.txt"
    exit 0 ;;
esac
exit 0
STUB
    chmod +x "$hstub/path/systemctl"
    export OPEN_ARGV="$TMP/o-h-argv.txt" H_STUB_LOG="$TMP/o-h-sctl.log"
    hrun H_HAVE_UNIT=1 H_ACTIVE=active H_MAINPID=4242 H_STATE="$hs" \
        H_START_LISTEN="$_p4" H_START_URL="http://127.0.0.1:$_p4/?token=FRESH-TOK" \
        DSH_HARNESS_WAIT=5 DSH_HARNESS_OPENER="$hstub/opener"
    _out=$(cat "$TMP/o-hr.out")
    check_contains "$shname 语义④：结论行「已由 systemd 拉起 ✓」" "已由 systemd 拉起 ✓" "$_out"
    check_contains "$shname 语义④：给出它写出来的地址" "token=FRESH-TOK" "$_out"
    check "$shname 语义④：真的 start 了那个单元" "1" \
        "$(grep -c 'start --no-block dsh-web.service' "$TMP/o-h-sctl.log" 2>/dev/null | tr -d ' ')"
    hr_argv_is "http://127.0.0.1:$_p4/?token=FRESH-TOK" "$shname 语义④：开的地址就是服务写出来的那个"
    _spid=$(cat "$hs/.h-stub-listen.pid" 2>/dev/null || printf '')
    [ -n "$_spid" ] && kill "$_spid" 2>/dev/null
    rm -f "$hs/.h-stub-listen.pid"

    # 态⑤ 没人听 + 没单元 → 前台起 npx：端口一出现就开浏览器 + 参数原样透传 + token 抓/清
    rm -f "$hs/current-token.txt" "$hs/web-url.txt"
    printf 'local_port=3080\n' >"$hc/remote.conf"
    rm -f "$TMP/o-h-argv.txt" "$TMP/o-h-npx.log"
    # 端口按 shell 分开（桩监听器活 6 秒；同一个端口两个 shell 会互撞 → 桩绑不上就立刻退）
    _p5=$(free_port)
    export OPEN_ARGV="$TMP/o-h-argv.txt" NPX_LOG="$TMP/o-h-npx.log" NPX_BIND_PORT="$_p5" NPX_PORT="$_p5"
    hrun H_HAVE_UNIT=0 DSH_HARNESS_WAIT=6 DSH_HARNESS_OPENER="$hstub/opener" -- --port "$_p5" --no-open
    _out=$(cat "$TMP/o-hr.out")
    check "$shname 语义⑤：退出码 0" "0" "$_hr_run_rc"
    check_contains "$shname 语义⑤：说清没有单元、走前台" "没有 dsh-web.service" "$_out"
    check_contains "$shname 语义⑤：--no-open 原样透传给 npx" "--no-open --port $_p5" "$(cat "$TMP/o-h-npx.log" 2>/dev/null)"
    hr_argv_is "http://127.0.0.1:$_p5/" "$shname 语义⑤：端口一出现就开浏览器（没等 npx 退出）"
    check_contains "$shname 语义⑤：抓到 token" "已捕获 token" "$_out"
    check "$shname 语义⑤：退出后 token 文件清掉（broker 回 503）" "yes" \
        "$([ -s "$hs/current-token.txt" ] && echo no || echo yes)"

    # 态⑥ 有单元但命令行换了端口（≠ remote.conf 的 local_port）→ 不走服务（单元钉着旧端口）
    rm -f "$hs/current-token.txt" "$hs/web-url.txt"
    printf 'local_port=3080\n' >"$hc/remote.conf"
    rm -f "$TMP/o-h-argv.txt" "$TMP/o-h-npx.log"
    _p6=$(free_port)
    export OPEN_ARGV="$TMP/o-h-argv.txt" NPX_LOG="$TMP/o-h-npx.log" NPX_BIND_PORT="$_p6" NPX_PORT="$_p6"
    hrun H_HAVE_UNIT=1 H_ACTIVE=active H_MAINPID=0 DSH_HARNESS_WAIT=6 \
        DSH_HARNESS_OPENER="$hstub/opener" -- --port "$_p6"
    _out=$(cat "$TMP/o-hr.out")
    check_contains "$shname 语义⑥：说清命令行换了端口" "命令行换了端口" "$_out"
    check_contains "$shname 语义⑥：改用前台 npx（不拿服务去顶别的端口）" "dsh-web.service 钉的是 3080" "$_out"
    check_contains "$shname 语义⑥：原样透传（没多加参数）" "--port $_p6" "$(cat "$TMP/o-h-npx.log" 2>/dev/null)"
    hr_argv_is "http://127.0.0.1:$_p6/" "$shname 语义⑥：照开浏览器"
done

# ⑤ opener 一档档退（ADR-0024：打不开浏览器**不算失败**，只多一行提示）
#   ①）DSH_HARNESS_OPENER 指一个不存在的命令 → 只打印 URL，rc 仍 0
#   ②）quiet → 不试任何 opener，也只打印 URL
#   ③）都不在 → 走"没有 opener"那行
mkdir -p "$TMP/oconf4" "$TMP/o-hstate4"
_po=$(free_port)
printf 'local_port=%s\n' "$_po" >"$TMP/oconf4/remote.conf"
_lp=$(listen_on "$_po")
sleep 1
for _case in "missing:$TMP/oconf4/nope" "quiet:quiet"; do
    _tag=${_case%%:*}
    _val=${_case#*:}
    DSH_REMOTE_STATE_DIR="$TMP/o-hstate4" DSH_REMOTE_CONF_DIR="$TMP/oconf4" \
        HOME="$TMP/o-nohome" DSH_HARNESS_OPENER="$_val" PATH="$hstub/path:$PATH" \
        bash -c '. "$1/env.bash"; harness --port "$2"' sh "$proj" "$_po" >"$TMP/o-opener-$_tag.out" 2>&1
    _rc=$?
    _out=$(cat "$TMP/o-opener-$_tag.out")
    check "opener 档「$_tag」：rc 仍是 0（绝不因为开不了浏览器而失败）" "0" "$_rc"
    check_contains "opener 档「$_tag」：URL 照样打出来" "URL: http://127.0.0.1:$_po/" "$_out"
    check_contains "opener 档「$_tag」：会话状态那行也在" "已在跑 ✓" "$_out"
    check "opener 档「$_tag」：≤3 行" "yes" \
        "$([ "$(wc -l <"$TMP/o-opener-$_tag.out")" -le 3 ] && echo yes || echo no)"
done
kill "$_lp" 2>/dev/null || true
wait "$_lp" 2>/dev/null || true

# ⑤b "一个 opener 都没有"那一档：**离线没法真造**（这台机器 ss/grep/xdg-open 都在
#     /usr/bin —— 把 PATH 收窄到"没有 opener"就等于连 ss 都没有）。所以用**空字符串**
#     覆盖走到同一个分支（`_hr_open` 里 `quiet|none|''` 与"自动探测一个都没找到"
#     共用同一段输出），并额外断言"一个都不试也 rc=0"。真·零 opener 的行为在真实环境
#     里人工验过（2026-10-09：只打印 URL、rc=0）。
_pn=$(free_port)
_lp=$(listen_on "$_pn")
sleep 1
DSH_REMOTE_STATE_DIR="$TMP/o-hstate4" DSH_REMOTE_CONF_DIR="$TMP/oconf4" \
    DSH_HARNESS_OPENER= DSH_REMOTE_HARNESS_WAIT=0 DSH_REMOTE_HARNESS_UNIT=none \
    DSH_HARNESS_OPENER_LOG="$TMP/o-noopener.log" \
    bash -c '. "$1/env.bash"; harness --port "$2"' sh "$proj" "$_pn" >"$TMP/o-noopener.out" 2>&1
check "没有 opener：rc=0（不许因为开不了浏览器而失败）" "0" "$?"
check_contains "没有 opener：只打印 URL" "URL: http://127.0.0.1:$_pn/" "$(cat "$TMP/o-noopener.out")"
check_contains "没有 opener：明说没开" "没开浏览器" "$(cat "$TMP/o-noopener.out")"
check "没有 opener：≤3 行" "yes" \
    "$([ "$(wc -l <"$TMP/o-noopener.out")" -le 3 ] && echo yes || echo no)"
check_contains "没有 opener：日志里记的 URL 是**原样**的（未经 shell 转换）" \
    "url=<http://127.0.0.1:$_pn/>" "$(cat "$TMP/o-noopener.log" 2>/dev/null)"
kill "$_lp" 2>/dev/null || true
wait "$_lp" 2>/dev/null || true

# ------------------------------------------------- Q harness-remote（云上那半）
printf 'Q. harness-remote：status / open / reset / passwd / url / qr（全用桩）\n'

# 桩 dsh-remote：只认 harness-remote 会转发的那三个调用，把参数记下来、输出用真格式
qstub="$TMP/qstub"
mkdir -p "$qstub" "$TMP/qconf" "$TMP/qstate"
cat >"$qstub/dsh-remote" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$Q_LOG"
case "$1 $2" in
"tunnel-status --probe")
    cat <<'OUT'
配置      /tmp/qconf/remote.conf
单元      /tmp/qstate/systemd/user/dsh-tunnel.service
  状态    is-active=active  is-enabled=enabled  MainPID=1234  NRestarts=0
映射      云上 127.0.0.1:18080 → 家里 127.0.0.1:3080（root@1.2.3.4:22）
harness   127.0.0.1:3080 在跑 ✓
broker    单元 /tmp/qstate/systemd/user/dsh-token-broker.service
          状态 is-active=active  is-enabled=enabled
          token 文件有（43 字节，10-09 21:00 修改）—— harness 正在跑
          本机 127.0.0.1:3081 在听 ✓
== --probe：上云只读看一眼（ss / curl，不改云上任何东西）
  127.0.0.1:18080
  127.0.0.1:18081
  http_code=401
  broker_http_code=302
  判据    dsh web：云上在听，请求穿到了家里的 dsh web（它自己还要 token，所以回 401 原文）✓
  判据    broker：不带 token 的入口 302 到当前 token ✓（手机收藏的固定地址就是它）
  公网    https://example.invalid:8443/ → HTTP 401(不带密码应 401 = Caddy 在挡)
OUT
    ;;
"force-restart-dsh-remote --json")
    printf '%s\n' '{"kind":"head","tool":"force-restart-dsh-remote","version":1,"mode":"安全档","total":6}'
    printf '%s\n' '{"kind":"step","n":1,"step":"tunnel-broker","state":"ok","title":"隧道+broker","detail":"reset-failed + restart 完成：is-active=active MainPID=1 NRestarts=0","evidence":"x"}'
    printf '%s\n' '{"kind":"step","n":2,"step":"cloud","state":"ok","title":"云上隧道口","detail":"云上 127.0.0.1:18080 和 :18081 都绑上了（2/2，第 1 次探测）","evidence":"x"}'
    printf '%s\n' '{"kind":"step","n":3,"step":"web","state":"warn","title":"本地 dsh web","detail":"127.0.0.1:3080 在听，但 PID 17169 不是 dsh-web.service 的 MainPID —— 是**手工起的**实例","evidence":"x"}'
    printf '%s\n' '{"kind":"step","n":4,"step":"token","state":"fail","title":"token 新鲜度","detail":"token **过期**（HTTP 401，43 字节）","evidence":"x"}'
    printf '%s\n' '{"kind":"step","n":5,"step":"public","state":"fail","title":"公网入口","detail":"不带密码 401；带密码首跳 302；跟随跳转 401","evidence":"x"}'
    printf '%s\n' '{"kind":"summary","state":"fail","detail":"隧道 ✓｜token ✗","next":"要新 token：**在机器上**跑 force-restart-dsh-remote --restart-web --yes"}'
    ;;
"force-restart-dsh-remote "*)
    printf '%s\n' '== 桩安全档：reset-failed + restart 隧道/broker（真命令不在这里跑）'
    ;;
passwd*)
    printf '%s\n' '== 桩 passwd：参数转发到了这里'
    ;;
esac
exit 0
STUB
chmod +x "$qstub/dsh-remote"
cat >"$qstub/opener" <<'STUB'
#!/bin/sh
printf 'argc=%s\n' "$#" >"$OPEN_ARGV"
printf '%s\n' "$1" >>"$OPEN_ARGV"
STUB
chmod +x "$qstub/opener"
cat >"$qstub/curl" <<'STUB'
#!/bin/sh
# 桩 curl：让 status 里"token 实测有效"那档走 ok 分支（-o /dev/null -w %{http_code} …）
printf '303'
STUB
chmod +x "$qstub/curl"
printf 'cloud_host=1.2.3.4\ncloud_user=root\nremote_port=18080\nbroker_remote_port=18081\nlocal_port=3080\npublic_url=https://example.invalid:8443\n' >"$TMP/qconf/remote.conf"

qrt() { # 跑一次真 harness-remote。KEY=VAL 形式的参数当"一次性环境变量"，
    # 其余原样当子命令参数传给它。**不用 env PATH=…**（PATH 里有带空格的目录）。
    _ev=
    while [ $# -gt 0 ]; do
        case $1 in
        *=*) _ev="$_ev $1" ;;
        *) break ;;
        esac
        shift
    done
    # ⚠️ `export` 不带参数会把**全部环境变量**打到 stdout（`$(qrt …)` 就把它当结果收走了）。
    # 只在真有 KEY=VAL 时才 export。
    if [ -n "$_ev" ]; then
        # shellcheck disable=SC2086
        export $_ev
    fi
    export DSH_REMOTE_BIN="$qstub/dsh-remote" DSH_REMOTE_CONF_DIR="$TMP/qconf"
    export DSH_REMOTE_STATE_DIR="$TMP/qstate" Q_LOG="$TMP/q-calls.log"
    export PATH="$qstub:$PATH_BASE"
    sh "$proj/bin/harness-remote" "$@"
}

# ① --help：五条子命令都在，而且说清"本地那半是 harness"
QR_HELP=$("$proj/bin/harness-remote" --help 2>&1)
check "Q①：--help 退出 0" "0" "$?"
for _qsub in status open reset passwd url qr; do
    check_contains "Q①：--help 里写了 $_qsub" "harness-remote $_qsub" "$QR_HELP"
done
check_contains "Q①：说清本地那半是 harness" '本地管理器' "$QR_HELP"
check_contains "Q①：说清云上那半的端口" "8443" "$QR_HELP"
for _qsub in passwd url qr; do
    if sh "$proj/bin/harness-remote" "$_qsub" --help >"$TMP/q-help-$_qsub.out" 2>&1; then
        ok "Q①：$_qsub --help 退出 0"
    else
        bad "Q①：$_qsub --help 退出 0"
    fi
    check_contains "Q①：$_qsub --help 打的是用法" "harness-remote" "$(cat "$TMP/q-help-$_qsub.out")"
done

# ② status：压成 ≤6 行，六个关键面各一行
rm -f "$TMP/q-calls.log"
# ⚠️ **必须 export**：O 段把 DSH_REMOTE_CONF_DIR/STATE_DIR/PATH 都 export 过了，
# 前缀赋值在这里不可靠（2026-10-09 实测：Q② 读到了真 remote.conf / 真 state）
export DSH_REMOTE_BIN="$qstub/dsh-remote" DSH_REMOTE_CONF_DIR="$TMP/qconf" DSH_REMOTE_STATE_DIR="$TMP/qstate"
export Q_LOG="$TMP/q-calls.log"
export PATH="$qstub:$PATH"
sh "$proj/bin/harness-remote" status >"$TMP/q-status.out" 2>&1
_qs=$(cat "$TMP/q-status.out")
check "Q②：status 退出 0" "0" "$?"
check "Q②：≤6 行" "yes" "$([ "$(wc -l <"$TMP/q-status.out")" -le 6 ] && echo yes || echo no)"
check_contains "Q②：隧道行 + is-active" "隧道" "$_qs"
check_contains "Q②：云上两个 -R 口都打勾" "18080✓ 18081✓" "$_qs"
check_contains "Q②：broker 行" "broker" "$_qs"
check_contains "Q②：token 过期那档说得明白" "过期（401）" "$_qs"
check_contains "Q②：web 行（手工实例 = warn，不是坏）" "web       ! 127.0.0.1:3080" "$_qs"
check_contains "Q②：公网入口那行（401 = Caddy 在挡）" "公网 ✓ 不带密码 401" "$_qs"
check_contains "Q②：容器那行（桩 ssh 失败 → 明说探不到 + 判据）" "dsh-relay 探不到" "$_qs"
check_contains "Q②：结论行" "结论" "$_qs"
check_contains "Q②：结论给出下一步（要新 token）" "要新 token" "$_qs"
_q_n=$(grep -cE '^(tunnel-status --probe|force-restart-dsh-remote --json)$' "$TMP/q-calls.log" 2>/dev/null)
check "Q②：复用了现成的两条输出（tunnel-status --probe + force-restart --json）" "2" "${_q_n:-0}"

# ③ open：打印并打开 https://<host>:<port>/（同一个 opener，argv 逐字节）
rm -f "$TMP/q-open-argv.txt"
export OPEN_ARGV="$TMP/q-open-argv.txt"
qrt DSH_HARNESS_OPENER="$qstub/opener" open >"$TMP/q-open.out" 2>&1
check "Q③：open 退出 0" "0" "$?"
check_contains "Q③：打印地址" "URL: https://example.invalid:8443" "$(cat "$TMP/q-open.out")"
check "Q③：桩 opener 收到 argc=1" "argc=1" "$(sed -n 1p "$TMP/q-open-argv.txt")"
check "Q③：桩 opener 第一个参数逐字节等于那个地址" "https://example.invalid:8443" "$(sed -n 2p "$TMP/q-open-argv.txt")"

# ③b 没有 opener：只打印 URL、rc=0
qrt DSH_HARNESS_OPENER=quiet open >"$TMP/q-open-quiet.out" 2>&1
check "Q③b：没有 opener 时 rc 仍 0" "0" "$?"
check_contains "Q③b：只打印 URL" "URL: https://example.invalid:8443" "$(cat "$TMP/q-open-quiet.out")"
check_not_contains "Q③b：不该有"已用"那种假话" "已用" "$(cat "$TMP/q-open-quiet.out")"

# ④ reset = 安全档，而且**拒绝** --restart-web（ADR-0022：云上永不重启 dsh web）
rm -f "$TMP/q-calls.log"
qrt reset >"$TMP/q-reset.out" 2>&1
check "Q④：reset 走安全档、退出 0" "0" "$?"
check_contains "Q④：转发的是 force-restart-dsh-remote（**不带**任何重启参数）" "force-restart-dsh-remote" "$(cat "$TMP/q-calls.log")"
check_not_contains "Q④：传给真命令的参数里没有 --restart-web" "--restart-web" "$(cat "$TMP/q-calls.log")"
_q_calls_before=$(wc -l <"$TMP/q-calls.log" | tr -d " ")
qrt reset --restart-web --yes >"$TMP/q-reset-bad.out" 2>&1
check "Q④：reset --restart-web 被拒（退出 1）" "1" "$?"
check_contains "Q④：拒绝时指向真命令" "dsh-remote force-restart-dsh-remote --restart-web" "$(cat "$TMP/q-reset-bad.out")"
check "Q④：被拒时**没有**真的调它（调用数没涨）" "1" \
    "$([ "$(wc -l <"$TMP/q-calls.log" | tr -d " ")" = "$_q_calls_before" ] && echo 1 || echo 0)"

# ⑤ passwd 转发身份：什么都不加（交给 dsh-remote 自己的默认），不做二次解析
rm -f "$TMP/q-calls.log"
qrt passwd --dry-run >"$TMP/q-passwd.out" 2>&1
check "Q⑤：passwd --dry-run 退出 0" "0" "$?"
check_contains "Q⑤：转发给 dsh-remote passwd" "passwd --dry-run" "$(cat "$TMP/q-calls.log")"
check_not_contains "Q⑤：passwd 不自己解析 --password（透传）" "不认识" "$(cat "$TMP/q-passwd.out")"

# ⑥ url / qr
qrt url >"$TMP/q-url.out" 2>&1
check "Q⑥：url 打印固定地址" "https://example.invalid:8443" "$(cat "$TMP/q-url.out")"
printf 'PNGDATA' >"$TMP/qstate/phone-qr.png"
qrt qr >"$TMP/q-qr.out" 2>&1
check "Q⑥：qr 打印二维码路径" "$TMP/qstate/phone-qr.png" "$(cat "$TMP/q-qr.out")"
rm -f "$TMP/qstate/phone-qr.png"
qrt qr >"$TMP/q-qr-none.out" 2>&1
check "Q⑥：没有二维码时退出 1 并说去哪生成" "1" "$?"
check_contains "Q⑥：说清怎么生成" "dsh-remote server" "$(cat "$TMP/q-qr-none.out")"

# ⑦ 被子命令参数写错时要报错指路（不静默）
sh "$proj/bin/harness-remote" status --bogus >"$TMP/q-bad.out" 2>&1
check "Q⑦：不认识的参数 → 退出 1" "1" "$?"
check_contains "Q⑦：报错里指路 --help" "harness-remote --help" "$(cat "$TMP/q-bad.out")"
sh "$proj/bin/harness-remote" nosuch >"$TMP/q-bad2.out" 2>&1
check "Q⑦：不认识的子命令 → 退出 1" "1" "$?"

# ⑦ dsh-web-run 的代理处理（2026-10-09 实测的"坏代理把服务卡死"；hazards H28 / ADR-0021）
#    判据不是"读代码"，而是**子进程里 `env | grep -i proxy` 的真实内容**：
#    桩 npx 把它整个 dump 到探针文件，再断言 —— 日志说"已清空"但子进程还带着代理，
#    这一条就会红。
pstub="$TMP/pstub"
mkdir -p "$pstub" "$TMP/pstate" "$TMP/pconf"
cat >"$pstub/npx" <<'STUB'
#!/bin/sh
env | grep -i proxy | sort >"$P_PROBE"
printf 'dsh web: http://127.0.0.1:3979/?token=PTOK (LAN: http://10.0.0.9:3979)\n'
STUB
chmod +x "$pstub/npx"
prun() { # prun <remote.conf 内容> <探针文件> [KEY=VAL…]
    printf '%s\n' "$1" >"$TMP/pconf/remote.conf"
    shift
    _probe=$1
    shift
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        "$@" P_PROBE="$_probe" PATH="$pstub:$PATH" \
        DSH_REMOTE_STATE_DIR="$TMP/pstate" DSH_REMOTE_CONF_DIR="$TMP/pconf" \
        DSH_REMOTE_NO_TUNNEL_RESTART=1 sh "$proj/bin/dsh-web-run" --port 3979 >"$TMP/o-p.out" 2>&1
}
# ⑦① 环境里带着坏代理（WSL autoProxy 那个形状）→ 默认必须清空
prun 'local_port=3979' "$TMP/p-a.txt" \
    http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897 \
    HTTP_PROXY=http://127.0.0.1:7897 HTTPS_PROXY=http://127.0.0.1:7897 \
    all_proxy=socks5://127.0.0.1:7897 ALL_PROXY=socks5://127.0.0.1:7897 \
    no_proxy=localhost NO_PROXY=localhost
_pa=$(cat "$TMP/p-a.txt" 2>/dev/null)
check "代理①：dsh-web-run 退出 0" "0" "$?"
check_contains "代理①：日志打「代理: 已清空」" "代理: 已清空" "$(cat "$TMP/o-p.out")"
check_not_contains "代理①：子进程里没有小写 http_proxy" "http_proxy=" "$_pa"
check_not_contains "代理①：子进程里没有大写 HTTP_PROXY" "HTTP_PROXY=" "$_pa"
check_not_contains "代理①：子进程里没有 https_proxy" "https_proxy=" "$_pa"
check_not_contains "代理①：子进程里没有 all_proxy" "all_proxy=" "$_pa"
check_not_contains "代理①：子进程里没有 ALL_PROXY" "ALL_PROXY=" "$_pa"
check_contains "代理①：no_proxy 保留（那是白名单，不是代理）" "no_proxy=localhost" "$_pa"
check_contains "代理①：NO_PROXY 也保留" "NO_PROXY=localhost" "$_pa"

# ⑦② remote.conf 的 web_proxy= → 显式设上（六个变量都设成它）
prun 'local_port=3979
web_proxy=http://127.0.0.1:7897' "$TMP/p-b.txt" no_proxy=localhost
_pb=$(cat "$TMP/p-b.txt" 2>/dev/null)
check_contains "代理②：日志打「代理: =<值>」并说来自哪" "代理: =http://127.0.0.1:7897（来自 remote.conf 的 web_proxy" "$(cat "$TMP/o-p.out")"
check_contains "代理②：子进程里 http_proxy 就是这个值" "http_proxy=http://127.0.0.1:7897" "$_pb"
check_contains "代理②：HTTPS_PROXY 也设了" "HTTPS_PROXY=http://127.0.0.1:7897" "$_pb"
check_contains "代理②：ALL_PROXY 也设了" "ALL_PROXY=http://127.0.0.1:7897" "$_pb"

# ⑦③ DSH_REMOTE_WEB_PROXY 覆盖 remote.conf（临时改一次不用改文件）
prun 'local_port=3979
web_proxy=http://127.0.0.1:7897' "$TMP/p-c.txt" no_proxy=localhost DSH_REMOTE_WEB_PROXY=http://10.0.0.1:8888
_pc=$(cat "$TMP/p-c.txt" 2>/dev/null)
check_contains "代理③：环境变量优先于 remote.conf" "代理: =http://10.0.0.1:8888（来自 DSH_REMOTE_WEB_PROXY" "$(cat "$TMP/o-p.out")"
check_contains "代理③：子进程里 http_proxy 是环境变量那个" "http_proxy=http://10.0.0.1:8888" "$_pc"


# ------------------------------------------------- P 一键强制重置 + 手机 /reset
printf 'P. 一键强制重置（force-restart-dsh-remote）+ 手机 /reset\n'
# O/Q 两段把把这个 shell 的 PATH 换成了 BASE（给子进程重建用的）；C 段之后
# 还有别的脚本要真 python3，所以这里把 PATH 恢复成"环境里完整的那份"。
PATH=$PATH_BASE
export PATH

# 桩：systemctl / ssh / curl / ss —— 全在临时目录，**不碰真 systemd、真状态目录、真 ss**。
# 端口挑一个高位的 3989（真 3080 上跑着用户的会话，测里绝不能碰它）。
pstub="$TMP/pstub"
pconf="$TMP/pconf/remote.conf"
pstate="$TMP/pstate"
punits="$TMP/punits"
mkdir -p "$pstub" "$TMP/pconf" "$pstate" "$punits"
printf 'local_port=3989\ncloud_host=1.2.3.4\ncloud_user=mindul\ncloud_ssh_port=22\nremote_port=18080\nbroker_remote_port=18081\nbroker_local_port=3081\npublic_url=https://1.2.3.4:8443\nweb_user=dsh\n' >"$pconf"
for _pu in dsh-tunnel.service dsh-token-broker.service dsh-web.service; do : >"$punits/$_pu"; done
printf 'PTOKEN123\n' >"$pstate/current-token.txt"

cat >"$pstub/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${P_SCTL_LOG:-/dev/null}"
args=""
for a in "$@"; do [ "$a" = "--user" ] || args="$args $a"; done
set -- $args
case " $* " in
*" show-environment "*) exit 0 ;;
esac
u=""
for a in "$@"; do u=$a; done
case "$u" in
dsh-tunnel.service) P=T ;;
dsh-token-broker.service) P=B ;;
dsh-web.service) P=W ;;
*) P=X ;;
esac
eval "act=\${${P}_ACTIVE:-active} sub=\${${P}_SUBSTATE:-running} main=\${${P}_MAINPID:-0} nr=\${${P}_NRESTARTS:-0}"
case " $* " in
*" is-active "*)
    printf '%s\n' "$act"
    [ "$act" = active ] && exit 0
    exit 3 ;;
*" show "*)
    for a in "$@"; do
        case $a in
        MainPID) printf '%s\n' "$main" ;;
        SubState) printf '%s\n' "$sub" ;;
        NRestarts) printf '%s\n' "$nr" ;;
        esac
    done
    exit 0 ;;
*" start dsh-web.service "* | *" restart dsh-web.service "*)
    # 模拟 dsh-web-run：真起来之后会把新 token 抓进状态文件（web-url.txt 也一起）
    if [ -n "${W_NEW_TOKEN:-}" ]; then
        printf '%s\n' "$W_NEW_TOKEN" >"$DSH_REMOTE_STATE_DIR/current-token.txt"
        printf 'http://127.0.0.1:3989/?token=%s\n' "$W_NEW_TOKEN" >"$DSH_REMOTE_STATE_DIR/web-url.txt"
        : >"$DSH_REMOTE_STATE_DIR/.w-started"
    fi
    exit 0 ;;
esac
exit 0
STUB
cat >"$pstub/ssh" <<'STUB'
#!/bin/sh
case ${P_SSH:-ok} in
ok) printf '2\n' ;;
one) printf '1\n' ;;
fail)
    printf 'ssh: connect to host 1.2.3.4 port 22: Connection refused\n' >&2
    exit 255
    ;;
esac
exit 0
STUB
cat >"$pstub/curl" <<'STUB'
#!/bin/sh
url=""
follow=0
authed=0
for a in "$@"; do
    case $a in
    -*L*) follow=1 ;;
    -u | -u*) authed=1 ;;
    http*) url=$a ;;
    esac
done
case $url in
http://127.0.0.1:*) [ "$follow" = 1 ] && printf 200 || printf '%s' "${P_TOKEN_CODE:-303}" ;;
https://*)
    if [ "$follow" = 1 ]; then printf '%s' "${P_PUB_FOLLOW:-200}"
    elif [ "$authed" = 1 ]; then printf '%s' "${P_PUB_AUTHED:-302}"
    else printf '%s' "${P_PUB_FIRST:-401}"; fi ;;
*) printf 000 ;;
esac
exit 0
STUB
cat >"$pstub/ss" <<'STUB'
#!/bin/sh
p=${P_LISTEN_PORT:-}
[ -n "$p" ] || exit 0
if [ -f "${DSH_REMOTE_STATE_DIR:-/tmp}/.w-started" ]; then
    pid=${W_MAINPID:-777}
else
    pid=${P_LISTEN_PID:-}
    [ -n "$pid" ] || exit 0
    kill -0 "$pid" 2>/dev/null || exit 0
fi
case " $* " in
*-ltnp* | *" -p "*) printf 'LISTEN 0 511 127.0.0.1:%s 0.0.0.0:* users:(("python3",pid=%s,fd=3))\n' "$p" "$pid" ;;
*) printf 'LISTEN 0 511 127.0.0.1:%s 0.0.0.0:*\n' "$p" ;;
esac
exit 0
STUB
chmod +x "$pstub"/*

plisten() { # plisten <端口> [多余的 argv…] → 起一个真回环监听，打印它的 PID
    _plp=$1
    shift
    python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$_plp)); s.listen(1); time.sleep(60)" "$@" >/dev/null 2>&1 &
    printf '%s' "$!"
}

PRUN_EXTRA="" # 额外参数（要分词）；用前设、用后清
prun() { # prun <状态目录> <输出文件> [KEY=VAL…]：跑安全档，rc 由调用方 $? 取
    _prs=$1
    _pro=$2
    shift 2
    # shellcheck disable=SC2086
    # DSH_REMOTE_CONF 要**显式**给：E 节有一句 `export DSH_REMOTE_CONF=…`，
    # 不给的话命令读的是那一份（2026-10-09 实测：P 节全跑时读到 M 节的 conf，
    # 于是 local_port 成了 3099、公网成了"没写 public_url"—— 单跑 P 节看不出来）。
    env "$@" \
        DSH_REMOTE_CONF="$TMP/pconf/remote.conf" \
        DSH_REMOTE_CONF_DIR="$TMP/pconf" DSH_REMOTE_STATE_DIR="$_prs" \
        DSH_REMOTE_UNIT_DIR="$punits" DSH_REMOTE_SYSTEMCTL="$pstub/systemctl" \
        PATH="$pstub:$PATH" sh "$proj/bin/dsh-remote" force-restart-dsh-remote $PRUN_EXTRA >"$_pro" 2>&1
    _prc=$?
    PRUN_EXTRA=""
    return "$_prc"
}

# ① help / 参数 / 薄封装等价
"$proj/bin/dsh-force-restart-dsh-remote" --help >"$TMP/p-help.out" 2>&1
check "force-restart-dsh-remote --help 退出 0" "0" "$?"
check_contains "help 里有这条命令" "force-restart-dsh-remote" "$(cat "$TMP/p-help.out")"
check_contains "help 里写明安全档不碰 dsh web" "绝不碰 dsh web" "$(cat "$TMP/p-help.out")"
check_contains "help 里有 --restart-web 例外" "restart-web" "$(cat "$TMP/p-help.out")"
sh "$proj/bin/dsh-remote" force-restart-dsh-remote --help >"$TMP/p-help2.out" 2>&1
check "薄封装和 dsh-remote 子命令的 help 逐字相同" "0" \
    "$(cmp -s "$TMP/p-help.out" "$TMP/p-help2.out" && printf 0 || printf 1)"
sh "$proj/bin/dsh-remote" force-restart-dsh-remote --bogus >"$TMP/p-bad.out" 2>&1
check "不认识的参数 → 非 0" "1" "$?"
check_contains "不认识的参数会说清收哪些" "--restart-web / --yes / --json" "$(cat "$TMP/p-bad.out")"

# ② 安全档：隧道健康 + 服务托管 + token 有效 + 公网通 → rc=0，关键行都在
P_LISTEN_PORT=3989 P_LISTEN_PID=$$ W_MAINPID=$$ W_ACTIVE=active T_ACTIVE=active T_MAINPID=555 T_NRESTARTS=0 B_ACTIVE=active \
    P_SSH=ok P_TOKEN_CODE=303 P_PUB_FIRST=401 P_PUB_AUTHED=302 P_PUB_FOLLOW=200 \
    prun "$pstate" "$TMP/p-ok.out"
check "安全档全绿时退出 0" "0" "$?"
check_contains "①隧道+broker 打 ✓" "[1/6] 隧道+broker ✓" "$(cat "$TMP/p-ok.out")"
check_contains "①带判据命令" "判据 systemctl --user show -p NRestarts -p MainPID dsh-tunnel.service" "$(cat "$TMP/p-ok.out")"
check_contains "②云上两个口都在听（2/2）" "都绑上了（2/2" "$(cat "$TMP/p-ok.out")"
check_contains "②判据就是那条 ssh 计数命令" "grep -cE \"127.0.0.1:(18080|18081)\"" "$(cat "$TMP/p-ok.out")"
check_contains "③认得出服务托管" "是 dsh-web.service 托管的" "$(cat "$TMP/p-ok.out")"
check_contains "④token 有效（首跳 303 → 跟随 200）" "token 有效（首跳 303 → 跟随跳转 200" "$(cat "$TMP/p-ok.out")"
check_contains "⑤公网 401 的含义写清了" "不带密码 401（Caddy 的 basic auth 在挡" "$(cat "$TMP/p-ok.out")"
check_contains "⑤公网 302 的含义写清了" "broker 在把 / 补成 /?token=" "$(cat "$TMP/p-ok.out")"
check_contains "⑥结论是 ✓" "结论 ✓" "$(cat "$TMP/p-ok.out")"
check_contains "⑥结论里有下一步" "下一步 都通了" "$(cat "$TMP/p-ok.out")"
check_not_contains "安全档没有去动 dsh web（不出现 SIGTERM）" "SIGTERM" "$(cat "$TMP/p-ok.out")"
check_not_contains "输出里不打印 token 值" "PTOKEN123" "$(cat "$TMP/p-ok.out")"

# ③ 安全档：隧道 failed（没活进程）→ ✗；broker 单元没装 → ✗；rc=1
mv "$punits/dsh-token-broker.service" "$TMP/p-broker-unit.bak"
P_LISTEN_PORT=3989 P_LISTEN_PID=$$ W_MAINPID=$$ T_ACTIVE=failed T_MAINPID=0 T_NRESTARTS=10 B_ACTIVE=active \
    P_SSH=ok P_TOKEN_CODE=303 \
    prun "$pstate" "$TMP/p-tun.out"
check "隧道 failed 时退出非 0" "1" "$?"
check_contains "①隧道 ✗ 且把实测状态打出来" "restart 之后没有活着的进程" "$(cat "$TMP/p-tun.out")"
check_contains "①broker 单元没装会说清" "dsh-token-broker.service 不在" "$(cat "$TMP/p-tun.out")"
mv "$TMP/p-broker-unit.bak" "$punits/dsh-token-broker.service"

# ④ 安全档：token 过期（401）→ 明说"要 --restart-web"；手工实例要认出来
P_LISTEN_PORT=3989 P_LISTEN_PID=$$ W_MAINPID=0 W_ACTIVE=activating W_SUBSTATE=auto-restart W_NRESTARTS=108 \
    T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active P_SSH=ok P_TOKEN_CODE=401 \
    prun "$pstate" "$TMP/p-exp.out"
check "token 过期时退出非 0" "1" "$?"
check_contains "④明说 token 过期" "token **过期**（HTTP 401" "$(cat "$TMP/p-exp.out")"
check_contains "④指向 --restart-web 才能拿新 token" "不重启 dsh web 拿不到新的" "$(cat "$TMP/p-exp.out")"
check_contains "③认出是手工起的实例（cgroup 里没有它）" "是**手工起的**实例" "$(cat "$TMP/p-exp.out")"
check_contains "③把服务状态一起打出来（activating + 重试次数）" "activating/auto-restart（已重试 108 次）" "$(cat "$TMP/p-exp.out")"
check_contains "下一步就一条：在机器上跑 --restart-web" "下一步 要新 token：**在机器上**跑 force-restart-dsh-remote --restart-web --yes" "$(cat "$TMP/p-exp.out")"

# ⑤ 安全档：端口没人听 / 云上只绑上一个 / ssh 上不去
P_LISTEN_PORT= P_TOKEN_CODE=000 T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active W_ACTIVE=failed P_SSH=ok \
    prun "$pstate" "$TMP/p-noweb.out"
check_contains "③没人听就说没人听" "没人听" "$(cat "$TMP/p-noweb.out")"
check_contains "④dsh web 没跑 → curl 000" "连不上（curl 000）" "$(cat "$TMP/p-noweb.out")"
P_LISTEN_PORT=3989 P_LISTEN_PID=$$ T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active P_SSH=one P_TOKEN_CODE=303 \
    prun "$pstate" "$TMP/p-one.out"
check_contains "②只绑上 1/2 会点出来" "只绑上 1/2" "$(cat "$TMP/p-one.out")"
check_contains "②并且点名僵尸会话要用户同意" "要用户同意才能杀" "$(cat "$TMP/p-one.out")"
P_LISTEN_PORT=3989 P_LISTEN_PID=$$ T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active P_SSH=fail P_TOKEN_CODE=303 \
    prun "$pstate" "$TMP/p-sshfail.out"
check_contains "②ssh 上不去也说得清" "ssh 上不去" "$(cat "$TMP/p-sshfail.out")"

# ⑥ --restart-web 非 tty 且没 --yes → 拒绝，且**一个进程都不许动**
p_lp=$(plisten 3989 dsh web --port 3989)
sleep 0.5
printf 'OLD-TOKEN\n' >"$pstate/current-token.txt"
rm -f "$pstate/.w-started"
PRUN_EXTRA="--restart-web"
P_LISTEN_PORT=3989 P_LISTEN_PID="$p_lp" T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active W_ACTIVE=activating W_SUBSTATE=auto-restart \
    P_SSH=ok P_TOKEN_CODE=303 \
    prun "$pstate" "$TMP/p-noyes.out"
check "--restart-web 非交互且没有 --yes → 非 0" "1" "$?"
check_contains "拒绝时说清要 --yes" "必须显式加 --yes" "$(cat "$TMP/p-noyes.out")"
check_contains "拒绝时也把大字警告打出来了" "会**打断正在跑的会话**" "$(cat "$TMP/p-noyes.out")"
check "拒绝时那个监听进程还在（没乱杀）" "0" "$(kill -0 "$p_lp" 2>/dev/null && printf 0 || printf 1)"

# ⑦ --restart-web --yes：真 SIGTERM 那一个 PID（服务那半走桩）→ 新 token 落地
PRUN_EXTRA="--restart-web --yes"
P_LISTEN_PORT=3989 P_LISTEN_PID="$p_lp" T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active W_ACTIVE=activating W_SUBSTATE=auto-restart \
    W_MAINPID=778 W_NEW_TOKEN=NEW-TOKEN-456 P_SSH=ok P_TOKEN_CODE=303 \
    prun "$pstate" "$TMP/p-rw.out"
check "--restart-web --yes 退出 0" "0" "$?"
check_contains "⑦只 SIGTERM 占着端口的那个 PID" "只 SIGTERM 了占着 127.0.0.1:3989 的那一个 PID $p_lp" "$(cat "$TMP/p-rw.out")"
check_contains "⑦用服务起回来（activating 时说明改用 restart）" "服务原本停在 activating/auto-restart" "$(cat "$TMP/p-rw.out")"
check_contains "⑦新 token 落地只报存在性" "新 token 已落地" "$(cat "$TMP/p-rw.out")"
check_contains "⑦明说不打印 token 值" "**值不打印**" "$(cat "$TMP/p-rw.out")"
check_not_contains "⑦输出里没有新 token 的值" "NEW-TOKEN-456" "$(cat "$TMP/p-rw.out")"
check "⑦旧 PID 真的被 SIGTERM 了" "1" "$(kill -0 "$p_lp" 2>/dev/null && printf 0 || printf 1)"
check_contains "⑦复验本地 200（跟随跳转）" "跟随跳转 200" "$(cat "$TMP/p-rw.out")"
check_contains "⑦复验公网 200" "Caddy→隧道→broker→dsh web 全通" "$(cat "$TMP/p-rw.out")"
kill "$p_lp" 2>/dev/null || true

# ⑧ 占着端口的是别的进程（cmdline 里没有 dsh）→ 不杀
p_decoy=$(plisten 3989)
sleep 0.5
printf 'STILL-OLD\n' >"$pstate/current-token.txt"
PRUN_EXTRA="--restart-web --yes"
P_LISTEN_PORT=3989 P_LISTEN_PID="$p_decoy" T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active W_ACTIVE=active W_SUBSTATE=running \
    W_NEW_TOKEN=SHOULD-NOT-HAPPEN P_SSH=ok P_TOKEN_CODE=303 \
    prun "$pstate" "$TMP/p-decoy.out"
check "⑧cmdline 里没有 dsh → 非 0" "1" "$?"
check_contains "⑧不杀，并说清为什么" "**不杀**，那可能不是 dsh web" "$(cat "$TMP/p-decoy.out")"
check "⑧那个进程还活着" "0" "$(kill -0 "$p_decoy" 2>/dev/null && printf 0 || printf 1)"
check "⑧也没给它换 token（token 文件还是旧的）" "STILL-OLD" "$(cat "$pstate/current-token.txt")"
kill "$p_decoy" 2>/dev/null || true

# ⑨ 从 broker 触发：不重启 broker 自己；也不许带 --restart-web
P_LISTEN_PORT=3989 P_LISTEN_PID=$$ T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active P_SSH=ok P_TOKEN_CODE=303 \
    prun "$pstate" "$TMP/p-fb.out" DSH_REMOTE_FROM_BROKER=1
check_contains "⑨从 /reset 触发时 broker 不重启自己" "broker 跳过重启（这次运行就是它发起的" "$(cat "$TMP/p-fb.out")"
PRUN_EXTRA="--restart-web --yes"
P_LISTEN_PORT=3989 P_LISTEN_PID=$$ T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active P_SSH=ok \
    prun "$pstate" "$TMP/p-fb2.out" DSH_REMOTE_FROM_BROKER=1
check "⑨云上带 --restart-web → 非 0" "1" "$?"
check_contains "⑨云上 /reset 永远不许重启 dsh web" "云上的 /reset 不允许重启 dsh web" "$(cat "$TMP/p-fb2.out")"

# ⑩ --json：一行一条合法 JSON（broker 的页面靠它，别在 python 里重写第二套）
PRUN_EXTRA="--json"
P_LISTEN_PORT=3989 P_LISTEN_PID=$$ T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active P_SSH=one P_TOKEN_CODE=401 \
    prun "$pstate" "$TMP/p-json.out"
check "⑩--json 时退出码照样反映失败" "1" "$?"
check "⑩每行都是合法 JSON，head 开头 summary 结尾 5 个 step" "ok" \
    "$(python3 - "$TMP/p-json.out" <<'PY'
import json, sys
kinds = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line:
        kinds.append(json.loads(line)["kind"])
print("ok" if kinds and kinds[0] == "head" and kinds[-1] == "summary" and kinds.count("step") == 5 else "bad")
PY
)"
check_not_contains "⑩JSON 里也没有 token 值" "PTOKEN123" "$(cat "$TMP/p-json.out")"

# ⑪ 手机按钮：broker 真进程 + GET /reset 确认页（no-store / nonce / 没有 token 和密码）
pbstate="$TMP/pbstate"
p_bport=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
mkdir -p "$pbstate"
printf 'SECRET-BROKER-TOKEN\n' >"$pbstate/current-token.txt"
env DSH_REMOTE_STATE_DIR="$pbstate" DSH_REMOTE_CONF="$TMP/pconf/remote.conf" \
    DSH_REMOTE_CONF_DIR="$TMP/pconf" DSH_REMOTE_UNIT_DIR="$punits" \
    DSH_REMOTE_SYSTEMCTL="$pstub/systemctl" DSH_REMOTE_RESET_DELAY=0 \
    PATH="$pstub:$PATH" P_LISTEN_PORT= T_ACTIVE=active T_MAINPID=555 B_ACTIVE=active \
    W_ACTIVE=active W_SUBSTATE=running P_SSH=ok P_TOKEN_CODE=303 P_PUB_FIRST=401 P_PUB_AUTHED=302 P_PUB_FOLLOW=200 \
    python3 "$proj/bin/dsh-token-broker" --port "$p_bport" --web-port 3989 \
    --token-file "$pbstate/current-token.txt" >"$TMP/p-broker.log" 2>&1 &
p_bpid=$!
p_i=0
while [ "$p_i" -lt 40 ]; do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$p_bport/reset" && break
    sleep 0.1
    p_i=$((p_i + 1))
done
p_hdr=$(curl -s -D - -o "$TMP/p-reset.html" --max-time 5 "http://127.0.0.1:$p_bport/reset")
check_contains "⑪GET /reset → 200" "200" "$p_hdr"
check_contains "⑪响应 no-store" "Cache-Control: no-store" "$p_hdr"
check_contains "⑪页面是确认页（确认按钮）" "确认重置" "$(cat "$TMP/p-reset.html")"
check_contains "⑪说清不打断当前会话" "打断当前会话" "$(cat "$TMP/p-reset.html")"
check_contains "⑪表单带一次性 nonce" 'name="nonce"' "$(cat "$TMP/p-reset.html")"
check_contains "⑪写明要重启 dsh web 得在机器上跑" "force-restart-dsh-remote --restart-web --yes" "$(cat "$TMP/p-reset.html")"
check_not_contains "⑪页面里没有 token" "SECRET-BROKER-TOKEN" "$(cat "$TMP/p-reset.html")"
check_not_contains "⑪页面里没有密码" "doublemindul" "$(cat "$TMP/p-reset.html")"

# ⑫ POST 的两道闸：没 nonce / nonce 重放 → 403；带 nonce → 202（先回响应再动隧道）
check "⑫POST 不带 nonce → 403" "403" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 5 "http://127.0.0.1:$p_bport/reset")"
p_nonce=$(sed -n 's/.*name="nonce" value="\([^"]*\)".*/\1/p' "$TMP/p-reset.html" | head -n 1)
p_post=$(curl -s -o "$TMP/p-post.html" -w '%{http_code}' -X POST -d "nonce=$p_nonce" --max-time 8 "http://127.0.0.1:$p_bport/reset")
check "⑫POST 带 nonce → 202" "202" "$p_post"
check_contains "⑫提示隧道会断几秒" "隧道会断几秒" "$(cat "$TMP/p-post.html")"
check "⑫同一个 nonce 重放 → 403" "403" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "nonce=$p_nonce" --max-time 5 "http://127.0.0.1:$p_bport/reset")"

# ⑬ POST 真的跑了安全档那套（桩 systemctl）：结果文件 + 页面每步 ✓/✗ + 判据
p_i=0
while [ "$p_i" -lt 60 ]; do
    grep -q '"kind":"summary"' "$pbstate/reset-last.jsonl" 2>/dev/null && break
    sleep 0.5
    p_i=$((p_i + 1))
done
check "⑬结果文件是 head + 5 步 + summary 共 7 行" "7" "$(wc -l <"$pbstate/reset-last.jsonl" | tr -d ' ')"
check_contains "⑬那次里 broker 没重启自己" "broker 跳过重启" "$(cat "$pbstate/reset-last.jsonl")"
check "⑬stdout 是纯 JSON、stderr 是空的" "0" \
    "$([ -s "$pbstate/reset-last.err" ] && printf 1 || printf 0)"
curl -s -o "$TMP/p-result.html" --max-time 5 "http://127.0.0.1:$p_bport/reset"
check_contains "⑬GET /reset 渲染出每步的 ✓" "✓" "$(cat "$TMP/p-result.html")"
check_contains "⑬也渲染出判据命令" "判据 <code>" "$(cat "$TMP/p-result.html")"
check_contains "⑬渲染出结论" "结论" "$(cat "$TMP/p-result.html")"
check_not_contains "⑬结果页里也没有 token" "SECRET-BROKER-TOKEN" "$(cat "$TMP/p-result.html")"
check_not_contains "⑬结果页里也没有密码" "doublemindul" "$(cat "$TMP/p-result.html")"
kill "$p_bpid" 2>/dev/null || true

# ⑭ Caddyfile 两份模板都要有 /reset，而且必须排在兜底 reverse_proxy **之前**（basic_auth 之后）
for _pcf in Caddyfile.ip Caddyfile.domain; do
    check_contains "⑭$_pcf 有 @reset path /reset" "@reset path /reset" "$(cat "$proj/cloud/$_pcf")"
    check_contains "⑭$_pcf 的 /reset 走 broker 那条隧道" "reverse_proxy @reset 127.0.0.1:{{BROKER_PORT}}" "$(cat "$proj/cloud/$_pcf")"
    _pline_reset=$(grep -n '@reset path /reset' "$proj/cloud/$_pcf" | head -n 1 | cut -d: -f1)
    _pline_ba=$(grep -n 'basic_auth {' "$proj/cloud/$_pcf" | head -n 1 | cut -d: -f1)
    _pline_catch=$(grep -n '^	reverse_proxy 127.0.0.1:{{TUNNEL_PORT}}' "$proj/cloud/$_pcf" | head -n 1 | cut -d: -f1)
    check "⑭$_pcf：basic_auth 在前、兜底在后（$_pline_ba < $_pline_reset < $_pline_catch）" "1" \
        "$([ -n "$_pline_ba" ] && [ -n "$_pline_reset" ] && [ -n "$_pline_catch" ] && [ "$_pline_ba" -lt "$_pline_reset" ] && [ "$_pline_reset" -lt "$_pline_catch" ] && printf 1 || printf 0)"
    _pindent=$(sed -n 's/^\([[:space:]]*\)@reset path \/reset$/\1/p' "$proj/cloud/$_pcf" | head -n 1)
    check "⑭$_pcf：@reset 那行有缩进（说明在站点块里，basic_auth 才管得到）" "1" \
        "$([ -n "$_pindent" ] && printf 1 || printf 0)"
done

# ---------------------------------------------------------------- 汇总
printf '\n%s\n' "----------------"
printf '通过 %s 条，失败 %s 条\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
