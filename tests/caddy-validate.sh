#!/bin/sh
# caddy-validate.sh —— 用**真的 Caddy** 校验渲染出来的 Caddyfile（要 docker）
#
#   sh tests/caddy-validate.sh
#
# run_tests.sh 只能证明"占位符替换干净、该有的行都在"，证明不了
# "这份 Caddyfile 是合法配置"。这条用官方 caddy 镜像里的 `caddy validate`
# 真验一遍 —— 两个模板（域名 / IP）都验。
#
# 顺带做一次"反向自检"：故意塞一条坏配置，确认这个测试**能失败**
# （一个永远绿的测试等于没测）。
#
# 镜像：caddy:2（约 20MB）。拉不动时先 docker pull caddy:2。

set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
proj=$(CDPATH= cd -- "$here/.." && pwd)
IMG=${CADDY_IMAGE:-caddy:2}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
pass=0
fail=0
ok() {
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
}
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
}

command -v docker >/dev/null 2>&1 || {
    echo "没有 docker，跳过"
    exit 0
}

echo "== 渲染两份 Caddyfile"
sh "$proj/cloud/relay.sh" --domain dsh.example.com --email me@example.com --dry-run >"$work/domain.Caddyfile" 2>"$work/err1" ||
    bad "domain 渲染失败：$(cat "$work/err1")"
sh "$proj/cloud/relay.sh" --ip 47.98.1.2 --allow-ip 1.2.3.4/32 --dry-run >"$work/ip.Caddyfile" 2>"$work/err2" ||
    bad "ip 渲染失败：$(cat "$work/err2")"

echo "== 用 $IMG 里的 caddy validate 验"
for f in domain ip; do
    if docker run --rm -v "$work:/c:ro" "$IMG" caddy validate --config "/c/$f.Caddyfile" --adapter caddyfile >"$work/$f.out" 2>&1; then
        ok "$f 模式：Caddyfile 合法"
    else
        bad "$f 模式：Caddyfile 不合法"
        sed 's/^/       /' "$work/$f.out"
    fi
done

echo "== 反向自检：坏配置必须被验出来"
{
    echo "dsh.example.com {"
    echo "	basic_auth {"
    echo "		bob"
    echo "	}"
} >"$work/broken.Caddyfile"
if docker run --rm -v "$work:/c:ro" "$IMG" caddy validate --config /c/broken.Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    bad "坏配置居然通过了 —— 这个测试没在测东西"
else
    ok "坏配置被拒（测试本身有效）"
fi

echo ""
echo "----------------"
printf '通过 %s 条，失败 %s 条\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
