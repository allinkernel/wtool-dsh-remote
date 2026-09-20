#!/bin/sh
# relay.sh —— **在阿里云那台机器上跑**：把"中继器"起成一个 Caddy 容器
# （HTTPS + basic auth），反代到 SSH 反向隧道的出口。
#
# 它只做云上这一半；家那一半（隧道 + 推送）在 bin/dsh-remote。
#
# 宿主上唯一需要的是 **docker**（+ compose 插件）。Caddy 自己不装、不落盘：
#   * 密码哈希    docker run --rm caddy:2 caddy hash-password
#   * 反代服务    docker compose up -d（network_mode: host）
#   * 证书/状态   两个命名卷 caddy-data / caddy-config
#
# 用法（在云上，root；relay.sh 和 Caddyfile.* / docker-compose.yml 放同一个目录）：
#   sh relay.sh --domain dsh.example.com --email me@example.com
#   sh relay.sh --ip 47.98.1.2                       # 没域名/没备案：8443 + 自签
#   sh relay.sh --ip 47.98.1.2 --port 8443 --allow-ip 1.2.3.4/32
#   sh relay.sh --domain dsh.example.com --dry-run    # 只渲染 + 校验，不起服务
#   sh relay.sh --domain dsh.example.com --install-docker   # 顺手把 docker 装上
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
CADDY_USER=dsh
CADDY_PASSWORD=
DOMAIN=
EMAIL=
IP=
PORT=
ALLOW_IPS=
DRY_RUN=0
INSTALL_DOCKER=0
CADDY_IMAGE=${CADDY_IMAGE:-caddy:2}

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
    --dry-run)
        DRY_RUN=1
        shift
        ;;
    -h | --help)
        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) die "不认识的参数：$1（--help）" ;;
    esac
done

[ -n "$DOMAIN" ] || [ -n "$IP" ] || die "要么 --domain，要么 --ip（--help 看用法）"
[ -n "$DOMAIN" ] && [ -n "$IP" ] && die "--domain 和 --ip 只能给一个"

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPOSE_FILE="$SELF_DIR/docker-compose.yml"
[ -f "$COMPOSE_FILE" ] || die "找不到 $COMPOSE_FILE（cloud/ 目录要整个传上来）"

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

if [ "$DRY_RUN" != 1 ] && [ "$(id -u)" != 0 ]; then
    die "要用 root 跑（装 docker、写 /opt/dsh-relay、起容器）；加 sudo"
fi

# ---------------------------------------------------------------- docker
compose() { # 兼容 docker compose（插件）和 docker-compose（老包）
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        die "没有 docker compose（插件或独立包都行），装上再来：apt install docker-compose-v2"
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

if ! command -v docker >/dev/null 2>&1; then
    if [ "$INSTALL_DOCKER" = 1 ] && [ "$DRY_RUN" != 1 ]; then
        install_docker
    elif [ "$DRY_RUN" = 1 ]; then
        say "（dry-run：本机没有 docker，密码哈希用占位符）"
    else
        die "没有 docker。两条路：sh $0 ... --install-docker  或者自己 apt install docker.io docker-compose-v2"
    fi
fi
HAS_DOCKER=0
command -v docker >/dev/null 2>&1 && HAS_DOCKER=1

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
    if ! HASH=$(docker run --rm "$CADDY_IMAGE" caddy hash-password --plaintext "$CADDY_PASSWORD" 2>/dev/null); then
        [ "$DRY_RUN" = 1 ] || die "算密码哈希失败（镜像 $CADDY_IMAGE 拉得下来吗？docker pull $CADDY_IMAGE）"
        HASH='$2a$14$DRYRUNPLACEHOLDERDRYRUNPLACEHOLDERDRYRUNPLACEHOLDER'
    fi
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
        printf '%s\n' "$rendered" >"$SELF_DIR/Caddyfile.dryrun"
        docker run --rm -v "$SELF_DIR:/c:ro" "$CADDY_IMAGE" \
            caddy validate --config /c/Caddyfile.dryrun --adapter caddyfile >&2 &&
            say "Caddyfile 校验通过（在 $CADDY_IMAGE 里验的）"
        rm -f -- "$SELF_DIR/Caddyfile.dryrun"
    else
        say "本机没有 docker，跳过校验"
    fi
    say ""
    say "（dry-run 只打印 Caddyfile 到 stdout；真跑就去掉 --dry-run）"
    exit 0
fi

say "== 落盘 $SELF_DIR/Caddyfile"
if [ -f "$SELF_DIR/Caddyfile" ]; then
    cp -f -- "$SELF_DIR/Caddyfile" "$SELF_DIR/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)"
fi
printf '%s\n' "$rendered" >"$SELF_DIR/Caddyfile"
mkdir -p -- "$SELF_DIR/logs"

say "== 起容器（docker compose up -d）"
cd -- "$SELF_DIR"
compose up -d || die "compose up 失败：docker compose logs --tail 50"

i=0
while [ "$i" -lt 20 ]; do
    if compose ps 2>/dev/null | grep -q "dsh-relay"; then break; fi
    sleep 1
    i=$((i + 1))
done
sleep 2
compose ps >&2 || true

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
000) warn "  https 入口连不上（docker compose logs 看看；端口 $PORT 起来了吗）" ;;
*) warn "  https 入口返回 $probe，预期 401 —— 看看 basic_auth 有没有生效" ;;
esac
if command -v curl >/dev/null 2>&1; then
    back=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$TUNNEL_PORT/" 2>/dev/null || printf '000')
    case $back in
    000) warn "  隧道那头还没连上（家里 dsh-remote tunnel 起了吗？）—— 还没起就是正常的" ;;
    *) say "  隧道出口：$back ✓（家里的 harness 已经在后面了）" ;;
    esac
fi

say ""
say "================================================================"
say "手机收藏这个地址：$url"
say "用户名：$CADDY_USER"
say "密码：  $CADDY_PASSWORD"
say ""
say "中继器 = 一个 caddy 容器（host 网络）+ 两个命名卷："
say "  docker compose -f $SELF_DIR/docker-compose.yml ps      看状态"
say "  docker compose -f $SELF_DIR/docker-compose.yml logs -f 看日志"
say "  docker compose -f $SELF_DIR/docker-compose.yml down    撤掉（卷留着）"
say ""
say "把 $url/ 写进家里 ~/.config/dsh-remote/remote.conf 的 public_url（cloud-install 会自动写）。"
say ""
say "还要做的两件事（脚本做不了）："
say "  1. 阿里云控制台安全组：只放行 $PORT/tcp 和 22/tcp（22 只放你家出口 IP）"
say "     —— 隧道端口 $TUNNEL_PORT 和 harness 端口 $LOCAL_PORT 绝对不要开"
say "  2. 手机第一次打开会：basic auth 一次 → 再贴一次 dsh web 打印的带 token 地址"
say "     （dsh-remote serve 会把那个地址存到 ~/.local/state/dsh-remote/web-url.txt）"
say "================================================================"
