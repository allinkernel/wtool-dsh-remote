#!/bin/sh
# relay-e2e.sh —— **真起一个 caddy 容器**，把云上那条链路验一遍：
#
#   手机 --https--> caddy 容器（basic auth）--reverse_proxy--> 宿主 127.0.0.1:<隧道口>
#
# 不用真阿里云：在本机用高端口跑，隧道口那端用一个假的 HTTP 服务顶着。
# 验的是"这份 docker-compose.yml + relay.sh 渲染出来的 Caddyfile"真的能：
#   * 起得来（host 网络、绑端口）
#   * 没密码 → 401（basic auth 在挡）
#   * 有密码 → 200，而且**真的代理到了隧道口**（body 来自假后端）
#   * host 头被改写成回环（后端看到的就是 127.0.0.1:<local-port>）
#
#   sh tests/relay-e2e.sh
#
# 要 docker（会用 caddy:2 镜像）。跑不了 docker 时会打印跳过。

set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
proj=$(CDPATH= cd -- "$here/.." && pwd)
IMG=${CADDY_IMAGE:-caddy:2}
pass=0
fail=0
ok() {
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
}
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    shift
    [ $# -gt 0 ] && printf '       %s\n' "$*"
    return 0
}

command -v docker >/dev/null 2>&1 || {
    echo "没有 docker，跳过（这条是人工跑的 e2e）"
    exit 0
}

pick_port() {
    python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}
http_port=$(pick_port)
tunnel_port=$(pick_port)
pw="e2e-$(date +%s)"
work=$(mktemp -d)
backend_pid=
compose() { docker compose "$@"; }
cleanup() {
    [ -n "$backend_pid" ] && kill "$backend_pid" 2>/dev/null
    (cd "$work" 2>/dev/null && compose down -v >/dev/null 2>&1) || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

echo "== 顶一个假后端（假装是家里的 harness，躲在隧道口后面）"
cat >"$work/backend.py" <<'PY'
import http.server, sys
PORT = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("DSH-STUB-OK host=%s" % self.headers.get("Host", "")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
python3 "$work/backend.py" "$tunnel_port" &
backend_pid=$!
sleep 0.5

echo "== 用 relay.sh 渲染 Caddyfile（dry-run 顺便让容器验一遍配置）"
if ! sh "$proj/cloud/relay.sh" --ip 127.0.0.1 --port "$http_port" \
    --tunnel-port "$tunnel_port" --local-port 3080 --password "$pw" --dry-run \
    >"$work/Caddyfile" 2>"$work/render.err"; then
    bad "relay.sh --dry-run 渲染失败" "$(cat "$work/render.err")"
    echo ""
    printf '通过 %s 条，失败 %s 条\n' "$pass" "$fail"
    exit 1
fi
ok "渲染成功"

cp "$proj/cloud/docker-compose.yml" "$work/"
mkdir -p "$work/logs"

echo "== 起容器（host 网络 + 命名卷）"
if ! (cd "$work" && compose up -d >"$work/up.log" 2>&1); then
    bad "docker compose up 失败" "$(tail -5 "$work/up.log")"
    echo ""
    printf '通过 %s 条，失败 %s 条\n' "$pass" "$fail"
    exit 1
fi
ok "compose up -d 成功"

i=0
while [ "$i" -lt 40 ]; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:$http_port/" 2>/dev/null || printf '000')
    [ "$code" = "401" ] && break
    sleep 0.5
    i=$((i + 1))
done
check_code() { # <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望 $2 实际 $3"; fi
}
check_code "没带密码 → 401（basic auth 在挡）" "401" "$code"

code_ok=$(curl -sk -o "$work/body" -w '%{http_code}' --max-time 5 -u "dsh:$pw" "https://127.0.0.1:$http_port/" 2>/dev/null || printf '000')
check_code "带对密码 → 200" "200" "$code_ok"
body=$(cat "$work/body" 2>/dev/null || printf '')
case $body in
*DSH-STUB-OK*) ok "真的代理到了隧道口（body 来自假后端）" ;;
*) bad "真的代理到了隧道口（body 来自假后端）" "body=[$body]" ;;
esac
case $body in
*"host=127.0.0.1:3080"*) ok "Host 被改写成回环（绕过 dsh web 的信任围栏）" ;;
*) bad "Host 被改写成回环（绕过 dsh web 的信任围栏）" "body=[$body]" ;;
esac

code_bad=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -u "dsh:wrong-password" "https://127.0.0.1:$http_port/" 2>/dev/null || printf '000')
check_code "密码错 → 401" "401" "$code_bad"

echo "== 收摊（compose down -v，容器和卷都撤掉）"
(cd "$work" && compose down -v >/dev/null 2>&1) && ok "compose down 干净退出" || bad "compose down 干净退出"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^dsh-relay$'; then
    bad "容器已经撤掉"
else
    ok "容器已经撤掉"
fi

echo ""
echo "----------------"
printf '通过 %s 条，失败 %s 条\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
