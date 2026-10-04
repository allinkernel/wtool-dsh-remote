#!/bin/sh
# run_tests.sh —— tools/dsh-remote 的用例（**不联网、不碰 docker、不碰真 $HOME**）
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
#   F cloud-install（假 ssh/scp）
#   G 目录边界：自己的东西不放 ~/.dsh
#   H check-hooks
#   I 安装脚本：源问 WTOOL_PROJECT_DIR 要（手跑按 $0 自推）、落点从
#     WTOOL_HOME/WTOOL_PREFIX 推、换 WTOOL_HOME 装到别处、源找不到不建悬空链、
#     --uninstall 撤干净 —— 全程临时 HOME（跑完比真 $HOME 的指纹）
#
# 真起 Caddy 校验 Caddyfile 的那条在 tests/caddy-validate.sh（要 docker）。

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
trap 'rm -rf "$TMP"; [ -n "${sink_pid:-}" ] && kill "$sink_pid" 2>/dev/null' EXIT INT TERM

# ---------------------------------------------------------------- A 语法
printf 'A. 语法（dash + bash）\n'
for f in bin/dsh-remote bin/dsh-notify cloud/relay.sh scripts/install.sh tests/run_tests.sh; do
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

out=$("$setup" --ip 47.98.1.2 --dry-run 2>&1)
check "ip dry-run 退出 0" "0" "$?"
check "ip：占位符都替换了" "" "$(leaked_placeholders "$out")"
check_contains "ip：自签证书" "tls internal" "$out"
check_contains "ip：站点地址带端口" "47.98.1.2:8443" "$out"
check_contains "ip：Host 也改写" "header_up Host 127.0.0.1:3080" "$out"

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

# ---------------------------------------------------------------- E dsh-remote
printf 'E. dsh-remote 子命令\n'
remote=$proj/bin/dsh-remote
export DSH_REMOTE_CONF="$TMP/remote.conf"
export DSH_NOTIFY_BIN="$NOTIFY"

"$remote" help >"$TMP/help2" 2>&1
check "help 退出 0" "0" "$?"
check_contains "help 里有 status" "status" "$(cat "$TMP/help2")"

"$remote" 不存在 >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "未知子命令非 0" || bad "未知子命令非 0"

# status 在没有配置时也要能跑（这是最常见的第一次调用）
DSH_REMOTE_HOME="$TMP/home" "$remote" status >"$TMP/st" 2>&1
check "status（无配置）退出 0" "0" "$?"
check_contains "status 会提示还没配置" "还没有" "$(cat "$TMP/st")"
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
rl=$(cat "$setup")
check_contains "relay.sh：哈希在容器里算" "docker run --rm" "$rl"
check_contains "relay.sh：用 compose 起服务" "compose up -d" "$rl"
check_not_contains "relay.sh：不再 apt 装 caddy" "apt-get install -y --no-install-recommends caddy" "$rl"
check_contains "relay.sh：宿主只要求 docker" "docker" "$rl"

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
check_contains "末尾交代跳过了几条" "有 4 条源没找到" "$d_out"
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
check_contains "末尾交代跳过了 3 条" "有 3 条源没找到" "$d2_out"

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

# ---------------------------------------------------------------- 汇总
printf '\n%s\n' "----------------"
printf '通过 %s 条，失败 %s 条\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
