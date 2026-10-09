#!/usr/bin/env python3
"""tests/fake_dsh_web.py —— 离线夹具：假装自己是家里的 `dsh web`（只给 K 节用）。

真 `dsh web` 在三种情况下分别回什么（2026-10-09 在本机真实例上量过，见 journal）：

    GET /?token=<对>            → 303 `Location: ./` + `Set-Cookie: dsh-auth-<authority>=<签名>`
    GET /  带**有效** cookie     → 200 + 首页 HTML（含 `<title>DeepSeek Harness</title>`，约 34 KB）
    GET /  带**过期/乱写** cookie → 401 + "dsh web authentication required; reopen the URL printed by dsh web."

这个夹具把这三条做小做全，并额外给出「cookie 名字/值决定行为」的开关，好让 broker
那几个分支**离线**测得出来（不用真 token、不用真会话、不连网、不碰真 `$HOME`）：

    带 `dsh-auth-*` cookie，值 =
        good  → 200 + 首页（并回一条刷新过的 Set-Cookie，验 broker 有没有原样透传）
        loop  → 303 `Location: /`（**转圈陷阱**：broker 必须换成 token 跳转，不许原样发出）
        boom  → 500（broker 判断不出 cookie 有效性 → 503，不许乱跳）
        slow  → 先 sleep（默认 1.5s，故意超过 broker 的探测超时）再回 200
        其它  → 401（过期/乱写）
    不带 cookie / 名字不以 `dsh-auth-` 开头 → 401（broker 那两条路都不该拿它去探测）
    `?token=<--token>`（默认 `Tok-456`）→ 303 + Set-Cookie；token 不对 → 401

用法：

    python3 tests/fake_dsh_web.py --port 3080 [--token Tok-456] [--slow-seconds 1.5]
                                  [--log /tmp/fake-web.log]

`--log` 每收一条请求追加一行（`GET / cookie=dsh-auth-x value=good -> 200`），
K 节用它证"broker 真的探了一次、又代发了一次"（两条请求，不是零条也不是一条）。
只绑 `127.0.0.1`。
"""

from __future__ import annotations

import argparse
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_HOST = "127.0.0.1"
DEFAULT_TOKEN = "Tok-456"
COOKIE_PREFIX = "dsh-auth-"

# 首页长这样（真实例 34782 字节，这里只要标题 + 一点体积，够验"响应被原样带回来了"）
HOME_HTML = (
    "<!doctype html>\n<html><head><title>DeepSeek Harness</title></head>\n"
    "<body><div id=app>fake dsh web（tests/fake_dsh_web.py）</div></body></html>\n"
).encode("utf-8")

UNAUTHORIZED_BODY = b"dsh web authentication required; reopen the URL printed by dsh web.\n"


def cookie_value(header_value: str) -> "tuple[str, str]":
    """从 Cookie 头里挑出第一条 `dsh-auth-*`，返回 (名字, 值)。"""
    for segment in header_value.split(";"):
        at = segment.find("=")
        if at == -1:
            continue
        name = segment[:at].strip()
        if name.startswith(COOKIE_PREFIX):
            return name, segment[at + 1:].strip()
    return "", ""


class Handler(BaseHTTPRequestHandler):
    server_version = "fake-dsh-web"
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        pass  # 安静点；要证什么用 --log

    def _note(self, status: int, name: str, value: str) -> None:
        path = self.server.log_path  # type: ignore[attr-defined]
        if not path:
            return
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(
                    "%s %s cookie=%s value=%s -> %d\n"
                    % (self.command, self.path, name or "-", value or "-", status)
                )
        except OSError:
            pass

    def _send(self, status: int, body: bytes, ctype: str, extra=()) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _handle(self) -> None:
        path = self.path.split("?", 1)[0] or "/"
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        name, value = cookie_value(self.headers.get("Cookie", ""))
        token = self.server.token  # type: ignore[attr-defined]

        if path != "/":
            self._note(404, name, value)
            self._send(404, "fake dsh web: 只有 /\n".encode("utf-8"), "text/plain; charset=utf-8")
            return

        # ① 带对的 token → 换 cookie（照抄真实例的 303 + Set-Cookie 形状）
        if "token=" in query:
            got = query.split("token=", 1)[1].split("&", 1)[0]
            if got != token:
                self._note(401, name, value)
                self._send(401, UNAUTHORIZED_BODY, "text/plain; charset=utf-8")
                return
            self._note(303, name, value)
            self._send(
                303,
                b"",
                "text/plain; charset=utf-8",
                (
                    ("Location", "./"),
                    (
                        "Set-Cookie",
                        "dsh-auth-FAKEAUTHORITY=good; Max-Age=2592000; Path=/; "
                        "Expires=Sun, 08 Nov 2026 05:37:03 GMT; HttpOnly; SameSite=Strict",
                    ),
                ),
            )
            return

        # ② 没有 dsh-auth-* cookie：真实例回 401（broker 那条路不该走到这儿）
        if not name:
            self._note(401, name, value)
            self._send(401, UNAUTHORIZED_BODY, "text/plain; charset=utf-8")
            return

        # ③ 有 cookie：值决定"还有效没"（见文件头）
        if value == "slow":
            time.sleep(self.server.slow_seconds)  # type: ignore[attr-defined]
        if value == "loop":
            self._note(303, name, value)
            self._send(303, b"", "text/plain; charset=utf-8", (("Location", "/"),))
            return
        if value == "boom":
            self._note(500, name, value)
            self._send(500, b"fake dsh web: boom\n", "text/plain; charset=utf-8")
            return
        if value == "good":
            self._note(200, name, value)
            self._send(
                200,
                HOME_HTML,
                "text/html; charset=utf-8",
                (
                    # 真实例在 / 上不一定再发 cookie；这条专门验"上游的 Set-Cookie 有没有被透传"
                    ("Set-Cookie", "%s=refreshed; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict" % name),
                    ("Content-Security-Policy", "default-src 'self'"),
                ),
            )
            return
        self._note(401, name, value)
        self._send(401, UNAUTHORIZED_BODY, "text/plain; charset=utf-8")

    def do_GET(self) -> None:  # noqa: N802
        self._handle()

    def do_HEAD(self) -> None:  # noqa: N802
        self._handle()


def main(argv) -> int:
    ap = argparse.ArgumentParser(prog="fake_dsh_web", description="假装家里的 dsh web（离线夹具）")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--token", default=DEFAULT_TOKEN)
    ap.add_argument("--slow-seconds", type=float, default=1.5)
    ap.add_argument("--log", default="")
    args = ap.parse_args(argv)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.token = args.token                     # type: ignore[attr-defined]
    server.slow_seconds = args.slow_seconds       # type: ignore[attr-defined]
    server.log_path = args.log                    # type: ignore[attr-defined]
    server.daemon_threads = True
    sys.stdout.write("fake-dsh-web: http://%s:%d/（token=%s）\n" % (args.host, args.port, args.token))
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
