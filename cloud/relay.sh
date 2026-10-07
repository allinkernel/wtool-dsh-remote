#!/bin/sh
# relay.sh —— **在阿里云那台机器上跑**：把"中继器"起成一个 Caddy 容器
# （HTTPS + basic auth），反代到 SSH 反向隧道的出口。
#
# 它只做云上这一半；家那一半（隧道 + 推送）在 bin/dsh-remote。
#
# 宿主上唯一需要的是 **docker**。Caddy 自己不装、不落盘：
#   * 密码哈希    docker run --rm caddy:2.11.4 caddy hash-password
#   * 反代服务    docker compose up -d（network_mode: host）
#   * 证书/状态   data/ 与 config/ 两个目录（命名卷或宿主目录，取决于哪种模式）
#
# 两种跑法：
#   ① compose 模式（默认）：要 root + docker compose 插件，落盘在本目录，
#      卷用 docker 命名卷。命令见下面几行。
#   ② **用户空间模式**（`--no-compose`）：不用 compose、不用 root，
#      直接用 `docker run` 起容器、用 `--dir` 指定的宿主目录装数据。
#      宿主上 docker 要 sudo 时再加 `--docker-cmd 'sudo docker'`
#      （2026-10-07 真阿里云那台就是这样：没 compose 插件、也不在 docker 组）。
#
# 用法（在云上；relay.sh 和 Caddyfile.* / docker-compose.yml 放同一个目录）：
#   sh relay.sh --domain dsh.example.com --email me@example.com
#   sh relay.sh --ip 47.98.1.2                       # 没域名/没备案：8443 + 自签
#   sh relay.sh --ip 47.98.1.2 --port 8443 --allow-ip 1.2.3.4/32
#   sh relay.sh --domain dsh.example.com --dry-run    # 只渲染 + 校验，不起服务
#   sh relay.sh --domain dsh.example.com --install-docker   # 顺手把 docker 装上
#   # 用户空间模式（没有 root / 没有 compose 插件）：
#   sh relay.sh --ip 47.98.1.2 --no-compose --dir ~/dsh-relay --docker-cmd 'sudo docker'
#     可选：--tunnel-port 18080（dsh web 那条）、--broker-port 18081（token broker 那条）、
#           --local-port 3080（家里 dsh web 的端口，只用来改写 Host/Origin）
#
# 可重复跑：每次重新渲染 Caddyfile（旧的备份）、recreate 容器、再自检。
# 密码不给 --password 就每次重新随机。
#
# 安全边界（README §5 有完整版）：
#   * 这个入口 = 整台家里机器的完全控制权。密码必须长且随机。
#   * 对外只开这一个端口；隧道端口（默认 18080）在安全组里**不要**开。
#   * --allow-ip 能再收紧一层。

set -eu

TUNNEL_PORT=18080
LOCAL_PORT=3080
# token broker 那条反向隧道（云上 18081 → 家里 3081）：Caddy 只把「不带 token 的 /」
# 转给它，由它 302 到 /?token=<当前值>（ADR-0014）。
BROKER_PORT=18081
CADDY_USER=dsh
CADDY_PASSWORD=
DOMAIN=
EMAIL=
IP=
PORT=
ALLOW_IPS=
DRY_RUN=0
INSTALL_DOCKER=0
NO_COMPOSE=0
RELAY_DIR=
DOCKER_CMD=
# **钉住的 tag**，不是浮动的 caddy:2：2026-10-07 实测阿里云的 mirror 会把 `caddy:2`
# 兑成 4 年前的 v2.4.6，而 v2.4.6 没有 `basic_auth` 指令 → 容器起来就崩
# （`unrecognized directive: basic_auth`）。钉住才能保证"本机 validate 过的那份
# 配置 = 云上真跑的那份"。要换版本用 CADDY_IMAGE=... 覆盖。
CADDY_IMAGE=${CADDY_IMAGE:-caddy:2.11.4}
CONTAINER_NAME=dsh-relay

# 所有进度/报告都走 stderr：**stdout 只留给机器能用的东西**
# （--dry-run 时就是渲染好的 Caddyfile，可以直接重定向成文件）。
say() { printf '%s\n' "$*" >&2; }
warn() { printf '警告：%s\n' "$*" >&2; }
die() {
    printf '%s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
    --domain)
        DOMAIN=${2:-}
        shift 2 || die "--domain 后面要跟域名"
        ;;
    --email)
        EMAIL=${2:-}
        shift 2
        ;;
    --ip)
        IP=${2:-}
        shift 2
        ;;
    --port)
        PORT=${2:-}
        shift 2
        ;;
    --tunnel-port)
        TUNNEL_PORT=${2:-}
        shift 2
        ;;
    --broker-port)
        BROKER_PORT=${2:-}
        shift 2 || die "--broker-port 后面要跟端口"
        ;;
    --local-port)
        LOCAL_PORT=${2:-}
        shift 2
        ;;
    --user)
        CADDY_USER=${2:-}
        shift 2
        ;;
    --password)
        CADDY_PASSWORD=${2:-}
        shift 2
        ;;
    --allow-ip)
        ALLOW_IPS="${ALLOW_IPS:+$ALLOW_IPS }${2:-}"
        shift 2
        ;;
    --install-docker)
        INSTALL_DOCKER=1
        shift
        ;;
    --no-compose)
        NO_COMPOSE=1
        shift
        ;;
    --dir)
        RELAY_DIR=${2:-}
        shift 2 || die "--dir 后面要跟目录"
        ;;
    --docker-cmd)
        # 本机 docker 要 sudo 就传 'sudo docker'（按空格拆开用）
        DOCKER_CMD=${2:-}
        shift 2 || die "--docker-cmd 后面要跟命令"
        ;;
    --dry-run)
        DRY_RUN=1
        shift
        ;;
    -h | --help)
        # 打到头部注释块结束为止（同 dsh-remote 的 usage：**别写死行号**，
        # 头部一改就会多打/少打 —— hazards H10 那个坑）
        awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) die "不认识的参数：$1（--help）" ;;
    esac
done

[ -n "$DOMAIN" ] || [ -n "$IP" ] || die "要么 --domain，要么 --ip（--help 看用法）"
[ -n "$DOMAIN" ] && [ -n "$IP" ] && die "--domain 和 --ip 只能给一个"

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPOSE_FILE="$SELF_DIR/docker-compose.yml"
# 落盘目录：compose 模式固定在本目录（compose 文件在这儿）；
# 用户空间模式可以用 --dir 指到别处（比如 ~/dsh-relay）
DIR=${RELAY_DIR:-$SELF_DIR}
case $DIR in
'~/'*) DIR="$HOME/${DIR#\~/}" ;;
esac
[ "$NO_COMPOSE" = 1 ] || [ -f "$COMPOSE_FILE" ] || die "找不到 $COMPOSE_FILE（cloud/ 目录要整个传上来）"

# 用哪条 docker：默认 `docker`，`--docker-cmd 'sudo docker'` 给"不在 docker 组"的机器用。
# 下面 $DOCKER 故意不加引号按空格拆开（SC2086）。
DOCKER=${DOCKER_CMD:-docker}
DOCKER_BIN=${DOCKER%% *}

dk() { # 所有 docker 调用都走这里
    # shellcheck disable=SC2086
    $DOCKER "$@"
}

if [ -n "$DOMAIN" ]; then
    MODE=domain
    PORT=${PORT:-443}
    [ -n "$EMAIL" ] || EMAIL="admin@${DOMAIN}"
    TMPL="$SELF_DIR/Caddyfile.domain"
else
    MODE=ip
    PORT=${PORT:-8443}
    TMPL="$SELF_DIR/Caddyfile.ip"
fi
[ -f "$TMPL" ] || die "找不到模板 $TMPL"

if [ "$DRY_RUN" != 1 ] && [ "$NO_COMPOSE" != 1 ] && [ "$(id -u)" != 0 ]; then
    die "要用 root 跑（装 docker、写 $SELF_DIR、起容器）；加 sudo，
   或者用用户空间模式：--no-compose --dir <目录> [--docker-cmd 'sudo docker']"
fi

# ---------------------------------------------------------------- docker
compose() { # 兼容 docker compose（插件）和 docker-compose（老包）
    if dk compose version >/dev/null 2>&1; then
        dk compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        die "没有 docker compose（插件或独立包都行）。两条路：装上它，
   或者用用户空间模式（不用 compose）：--no-compose --dir <目录> --docker-cmd 'sudo docker'"
    fi
}

install_docker() {
    command -v apt-get >/dev/null 2>&1 || die "不会自动装 docker（不是 apt 系统）；自己装好再加 --dry-run 跑"
    say "== 装 docker（apt）"
    apt-get update -qq >/dev/null 2>&1 || true
    # docker.io + compose 插件：Ubuntu 24.04 叫 docker-compose-v2，老一点的是 docker-compose
    apt-get install -y --no-install-recommends docker.io >/dev/null 2>&1 ||
        die "docker.io 装不上（换国内源试试，或者自己装 docker）"
    apt-get install -y --no-install-recommends docker-compose-v2 >/dev/null 2>&1 ||
        apt-get install -y --no-install-recommends docker-compose >/dev/null 2>&1 ||
        warn "compose 没装上，docker compose 可能要自己补"
    systemctl enable --now docker >/dev/null 2>&1 || true
}

if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
    if [ "$INSTALL_DOCKER" = 1 ] && [ "$DRY_RUN" != 1 ]; then
        install_docker
    elif [ "$DRY_RUN" = 1 ]; then
        say "（dry-run：本机没有 $DOCKER_BIN，密码哈希用占位符）"
    else
        die "没有 $DOCKER_BIN（--docker-cmd 给的是「$DOCKER」）。两条路：sh $0 ... --install-docker
   或者自己装好 docker；要 sudo 就用 --docker-cmd 'sudo docker'"
    fi
fi
HAS_DOCKER=0
command -v "$DOCKER_BIN" >/dev/null 2>&1 && HAS_DOCKER=1
if [ "$NO_COMPOSE" = 1 ]; then
    say "== 用户空间模式（--no-compose）：落盘目录 $DIR，容器名 $CONTAINER_NAME，docker 命令「$DOCKER」"
fi

# ---------------------------------------------------------------- 密码
gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -d '/+=' | cut -c1-20
    else
        head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20
    fi
}
[ -n "$CADDY_PASSWORD" ] || CADDY_PASSWORD=$(gen_password)

if [ "$HAS_DOCKER" = 1 ]; then
    # 哈希在容器里算 —— 宿主上不装 caddy 也能算，顺便保证版本一致
    if ! HASH=$(dk run --rm "$CADDY_IMAGE" caddy hash-password --plaintext "$CADDY_PASSWORD" 2>/dev/null); then
        [ "$DRY_RUN" = 1 ] || die "算密码哈希失败（镜像 $CADDY_IMAGE 拉得下来吗？docker pull $CADDY_IMAGE）"
        HASH='$2a$14$DRYRUNPLACEHOLDERDRYRUNPLACEHOLDERDRYRUNPLACEHOLDER'
    fi
    # 镜像版本自检：浮动 tag 在国内 mirror 上可能是几年前的旧镜像（hazards H13）。
    # basic_auth 指令要 Caddy ≥ 2.8，太老的话容器会起来就崩、无限重启 —— 这里先拦下来。
    ver=$(dk run --rm "$CADDY_IMAGE" caddy version 2>/dev/null | awk '{print $1}')
    case $ver in
    v2.[89]* | v2.1[0-9]* | v3.* | v[4-9].*) : ;; # 够新
    '') warn "认不出 $CADDY_IMAGE 里 caddy 的版本，自己确认一下：docker run --rm $CADDY_IMAGE caddy version" ;;
    *)
        if [ "$DRY_RUN" = 1 ]; then
            warn "$CADDY_IMAGE 里的 caddy 是 $ver（basic_auth 要 ≥ 2.8，真跑会被拦下）"
        else
            die "$CADDY_IMAGE 里的 caddy 是 $ver，太老：basic_auth 指令要 ≥ 2.8。
   换个镜像：CADDY_IMAGE=caddy:2.11.4 sh $0 ...
   （国内 mirror 会把浮动的 caddy:2 兑成很老的镜像，见 docs/hazards.md H13）"
        fi
        ;;
    esac
else
    HASH='$2a$14$DRYRUNPLACEHOLDERDRYRUNPLACEHOLDERDRYRUNPLACEHOLDER'
fi

# ---------------------------------------------------------------- 渲染
allow_file=$(mktemp)
trap 'rm -f "$allow_file"' EXIT INT TERM
if [ -n "$ALLOW_IPS" ]; then
    {
        printf '\t@notme not remote_ip %s\n' "$ALLOW_IPS"
        printf '\trespond @notme "forbidden" 403\n'
    } >"$allow_file"
else
    : >"$allow_file"
fi

render() {
    sed -e "s|{{DOMAIN}}|$DOMAIN|g" \
        -e "s|{{EMAIL}}|$EMAIL|g" \
        -e "s|{{IP}}|$IP|g" \
        -e "s|{{PORT}}|$PORT|g" \
        -e "s|{{USER}}|$CADDY_USER|g" \
        -e "s|{{HASH}}|$HASH|g" \
        -e "s|{{TUNNEL_PORT}}|$TUNNEL_PORT|g" \
        -e "s|{{LOCAL_PORT}}|$LOCAL_PORT|g" \
        -e "s|{{BROKER_PORT}}|$BROKER_PORT|g" \
        "$TMPL" |
        sed -e "/{{ALLOW_BLOCK}}/r $allow_file" -e "/{{ALLOW_BLOCK}}/d"
}

say "== 渲染 Caddyfile（$MODE 模式，对外端口 $PORT，容器 $CADDY_IMAGE）"
rendered=$(render)
# 模板注释里也写着 {{...}}（给人看的说明），所以只认真正的占位符形状
if printf '%s\n' "$rendered" | grep -qE '\{\{[A-Z_]+\}\}'; then
    printf '%s\n' "$rendered" | grep -nE '\{\{[A-Z_]+\}\}' >&2
    die "还有占位符没替换掉，模板/脚本对不上了（上面列了行号）"
fi

if [ "$DRY_RUN" = 1 ]; then
    printf '%s\n' "$rendered"
    say ""
    say "== 校验（dry-run）"
    if [ "$HAS_DOCKER" = 1 ]; then
        mkdir -p -- "$DIR"
        printf '%s\n' "$rendered" >"$DIR/Caddyfile.dryrun"
        dk run --rm -v "$DIR:/c:ro" "$CADDY_IMAGE" \
            caddy validate --config /c/Caddyfile.dryrun --adapter caddyfile >&2 &&
            say "Caddyfile 校验通过（在 $CADDY_IMAGE 里验的）"
        rm -f -- "$DIR/Caddyfile.dryrun"
    else
        say "本机没有 docker，跳过校验"
    fi
    if [ "$NO_COMPOSE" = 1 ]; then
        say ""
        say "== 真跑（--no-compose）时会执行："
        say "  $DOCKER rm -f $CONTAINER_NAME        # 已存在就先撤（可重复跑）"
        say "  $DOCKER run -d --name $CONTAINER_NAME --restart unless-stopped --network=host \\"
        say "    -v $DIR/Caddyfile:/etc/caddy/Caddyfile:ro -v $DIR/logs:/var/log/caddy \\"
        say "    -v $DIR/data:/data -v $DIR/config:/config $CADDY_IMAGE"
    fi
    say ""
    say "（dry-run 只打印 Caddyfile 到 stdout；真跑就去掉 --dry-run）"
    exit 0
fi

say "== 落盘 $DIR/Caddyfile"
# `--dir` 给的目录可能还不存在（用户空间模式第一次跑、或者换了新目录）：
# 不先建就是 `set -eu` 下一行 "cannot create …/Caddyfile: Directory nonexistent"
# 直接退出（2026-10-07 实测踩到；云上那次是目录早被手工建好了才没暴露）。
mkdir -p -- "$DIR" || die "建不了目录 $DIR（--dir 给对了吗？）"
if [ -f "$DIR/Caddyfile" ]; then
    cp -f -- "$DIR/Caddyfile" "$DIR/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)"
fi
printf '%s\n' "$rendered" >"$DIR/Caddyfile"
mkdir -p -- "$DIR/logs" "$DIR/data" "$DIR/config"

if [ "$NO_COMPOSE" = 1 ]; then
    # 用户空间模式：不用 compose，直接 docker run（宿主目录当数据卷）。
    # 先 rm -f 再 run —— 可重复跑，且不用管上一次是不是同一份配置。
    say "== 起容器（$DOCKER run -d --name $CONTAINER_NAME；host 网络）"
    dk rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    $DOCKER run -d --name "$CONTAINER_NAME" --restart unless-stopped --network=host \
        -v "$DIR/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "$DIR/logs:/var/log/caddy" \
        -v "$DIR/data:/data" \
        -v "$DIR/config:/config" \
        "$CADDY_IMAGE" >/dev/null ||
        die "$DOCKER run 失败：$DOCKER logs --tail 50 $CONTAINER_NAME"
else
    say "== 起容器（docker compose up -d）"
    cd -- "$SELF_DIR"
    compose up -d || die "compose up 失败：docker compose logs --tail 50"
fi

i=0
while [ "$i" -lt 20 ]; do
    # 注意：这里必须写成 if/then（`… && break` 在 set -e 下 grep 没命中就直接退出脚本）
    if [ "$NO_COMPOSE" = 1 ]; then
        if dk ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then break; fi
    else
        if compose ps 2>/dev/null | grep -q "$CONTAINER_NAME"; then break; fi
    fi
    sleep 1
    i=$((i + 1))
done
sleep 2
if [ "$NO_COMPOSE" = 1 ]; then
    dk ps --filter "name=$CONTAINER_NAME" >&2 || true
else
    compose ps >&2 || true
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
    say "ufw：已放行 $PORT/tcp"
fi

# ---------------------------------------------------------------- 自检
say ""
say "== 自检"
if [ "$MODE" = domain ]; then
    url="https://$DOMAIN"
    probe=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$DOMAIN:$PORT:127.0.0.1" "https://$DOMAIN:$PORT/" 2>/dev/null || printf '000')
else
    url="https://$IP:$PORT"
    probe=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $IP:$PORT" "https://127.0.0.1:$PORT/" 2>/dev/null || printf '000')
fi
case $probe in
401) say "  https 入口：401（basic auth 在挡着）✓" ;;
000) warn "  https 入口连不上（$DOCKER logs 看看；端口 $PORT 起来了吗）" ;;
*) warn "  https 入口返回 $probe，预期 401 —— 看看 basic_auth 有没有生效" ;;
esac
if command -v curl >/dev/null 2>&1; then
    back=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$TUNNEL_PORT/" 2>/dev/null || printf '000')
    case $back in
    000) warn "  隧道出口连不上（家里 dsh-remote tunnel-install 装了吗？）—— 还没装就是正常的" ;;
    *) say "  隧道出口：$back ✓（家里的 dsh web 已经在后面了）" ;;
    esac
    # token broker 那条（手机固定地址靠它 302 到当前 token）：302 = 好、503 = 家里还没
    # 用 harness 函数起过（没 token）、000 = 那条反向隧道没通。都只是提示，不算失败。
    brok=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$BROKER_PORT/" 2>/dev/null || printf '000')
    case $brok in
    302) say "  token broker：302 ✓（不带 token 的 / 会被送到当前 token）" ;;
    503) warn "  token broker：503 —— 家里 harness 还没用 env 里的 harness 函数起过（没有 token）" ;;
    000) warn "  token broker：那条反向隧道没通（家里 dsh-remote broker-install 装了吗）" ;;
    *) warn "  token broker：返回 $brok，预期 302（有 token）或 503（没 token）" ;;
    esac
fi

# 把"地址 + 用户名 + 密码"**落一份到 $DIR/relay-password.txt（600）**：
# 以前这文件是人手写的、脚本不更新，于是不给 --password 重跑一次就两边漂移
# （Caddyfile 是新密码、文件还是旧的 → 文件里的值过不了 basic auth，hazards H17）。
# 现在脚本自己写，谁重渲染谁负责，漂移从源头没了。
pw_file="$DIR/relay-password.txt"
# 给"改密码"那三行提示用的模式参数（domain 模式和 ip 模式的命令行不一样）
if [ "$MODE" = domain ]; then
    pw_mode="--domain $DOMAIN --email $EMAIL"
else
    pw_mode="--ip $IP"
fi
umask 077
cat >"$pw_file" <<PWEOF
# dsh-remote 中继入口（由 relay.sh 每次渲染时重写；别手改，改密码就带 --password 重跑）
URL=$url
USER=$CADDY_USER
PASSWORD=$CADDY_PASSWORD

# 改密码三步：
#   1) 云上：cd $DIR && sh cloud/relay.sh $pw_mode --port $PORT --password '<新密码>' \
#            --no-compose --dir $DIR --docker-cmd '$DOCKER'
#   2) 家里：dsh-remote tunnel-status --probe    # 看 broker / 隧道还正常
#   3) 手机：浏览器里清掉这个站点的 basic auth（或换无痕窗口），用新密码登一次
PWEOF
chmod 600 -- "$pw_file" 2>/dev/null || true

say ""
say "================================================================"
say "手机收藏这个地址：$url"
say "用户名：$CADDY_USER"
say "密码：  $CADDY_PASSWORD"
say "（这三样也写在 $pw_file，600）"
say ""
say "中继器 = 一个 caddy 容器（host 网络）"
if [ "$NO_COMPOSE" = 1 ]; then
    say "  数据在宿主目录 $DIR/{data,config,logs}（--no-compose 模式，没有命名卷）"
    say "  $DOCKER ps --filter name=$CONTAINER_NAME              看状态"
    say "  $DOCKER logs -f $CONTAINER_NAME                       看日志"
    say "  $DOCKER rm -f $CONTAINER_NAME                         撤掉（数据目录留着）"
else
    say "  docker compose -f $SELF_DIR/docker-compose.yml ps      看状态"
    say "  docker compose -f $SELF_DIR/docker-compose.yml logs -f 看日志"
    say "  docker compose -f $SELF_DIR/docker-compose.yml down    撤掉（卷留着）"
fi
say ""
say "把 $url/ 写进家里 ~/.config/dsh-remote/remote.conf 的 public_url（cloud-install 会自动写）。"
say ""
say "还要做的两件事（脚本做不了）："
say "  1. 阿里云控制台安全组：只放行 $PORT/tcp 和 22/tcp（22 只放你家出口 IP）"
say "     —— 隧道端口 $TUNNEL_PORT 和 harness 端口 $LOCAL_PORT 绝对不要开"
say "  2. 手机第一次打开会：basic auth 一次 → 再贴一次 dsh web 打印的带 token 地址"
say "     （dsh-remote serve 会把那个地址存到 ~/.local/state/dsh-remote/web-url.txt）"
say "================================================================"
