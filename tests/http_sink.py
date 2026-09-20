#!/usr/bin/env python3
"""http_sink.py —— 测试用的小 HTTP 接收端：把每次 POST 的 body 追加写进一个文件。

    python3 http_sink.py <port> <outfile>

只绑 127.0.0.1。收完一条就往 outfile 里写一行（body 里的换行转义成 \\n），
测试脚本靠它断言"消息真的发出去了"。它是 tests/ 的零件，不是运行期组件。
"""
import http.server
import socketserver
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    out = None

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        with open(self.out, "a", encoding="utf-8") as fh:
            fh.write(body.replace("\\", "\\\\").replace("\n", "\\n") + "\n")
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):  # 静音
        pass


def main():
    port = int(sys.argv[1])
    Handler.out = sys.argv[2]
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
