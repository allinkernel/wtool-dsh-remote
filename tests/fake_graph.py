#!/usr/bin/env python3
"""fake_graph.py —— 测试用的假 Microsoft 登录端点 + 假 Graph sendMail。

    python3 fake_graph.py <port> <requests.jsonl>

**只绑 127.0.0.1，绝不联网**。URL 的第一段是场景，最后一段是动作：

    POST /<场景>/devicecode   模拟 device code 申请
    POST /<场景>/token        模拟 token 端点（grant_type=device_code / refresh_token）
    POST /<场景>/sendmail     模拟 POST /v1.0/me/sendMail

场景：

    ok          device 流程先回一次 authorization_pending 再成功；
                refresh_token 换 token 成功；sendMail 回 202
    rotated     同上，但 token 响应带一个新的 refresh_token（测轮换回写）
    tokenfail   refresh_token 换 token 回 400 invalid_grant（AADSTS70008）
    senderr     token 成功，sendMail 回 403 ErrorSendAsDenied
    send200     token 成功，sendMail 回 200（按 Graph 契约**不算成功**）
    slow        device 流程：pending → slow_down → 成功（测 interval 加 5）
    denied      device 流程回 authorization_declined
    expired     device code 的 expires_in 很短，token 端点一直回 pending

每收到一个请求就往 <requests.jsonl> 追加一行（JSON），测试靠它断言
"到底发了什么、发了几次、Authorization 带没带"。它是 tests/ 的零件，
不是运行期组件。
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

REQUESTS = None
LOCK = threading.Lock()
DEVICE_POLLS = {}

VERIFICATION_URI = "https://example.test/devicelogin"


def record(entry):
    with LOCK:
        with open(REQUESTS, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _reply(self, code, obj=None, raw=None):
        if obj is not None:
            raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            ctype = "application/json; charset=utf-8"
        else:
            raw = raw if raw is not None else b""
            ctype = "text/plain; charset=utf-8"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        if raw:
            self.wfile.write(raw)

    def do_POST(self):  # noqa: N802
        path = urlparse(self.path).path
        parts = [p for p in path.split("/") if p]
        scenario = parts[0] if parts else ""
        action = parts[-1] if len(parts) > 1 else ""
        raw = self._body()
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        form = {}
        payload = None
        if ctype == "application/x-www-form-urlencoded":
            form = {k: v[0] for k, v in parse_qs(raw.decode("utf-8", "replace")).items()}
        elif raw:
            try:
                payload = json.loads(raw.decode("utf-8"))
            except Exception:
                payload = None
        record({
            "scenario": scenario,
            "action": action,
            "form": form,
            "json": payload,
            "authorization": self.headers.get("Authorization") or "",
        })

        if action == "devicecode":
            return self._devicecode(scenario)
        if action == "token":
            return self._token(scenario, form)
        if action == "sendmail":
            return self._sendmail(scenario)
        return self._reply(404, {"error": {"code": "NotFound", "message": path}})

    def _devicecode(self, scenario):
        if scenario not in ("ok", "rotated", "slow", "denied", "expired", "tokenfail"):
            return self._reply(404, {"error": {"code": "NotFound"}})
        interval = 1 if scenario == "slow" else 0
        expires = 2 if scenario == "expired" else 900
        return self._reply(200, {
            "device_code": "DEVICE-CODE-FOR-%s" % scenario,
            "user_code": "CODE-%s" % scenario.upper(),
            "verification_uri": VERIFICATION_URI,
            "verification_uri_complete": VERIFICATION_URI + "?code=CODE-%s" % scenario.upper(),
            "expires_in": expires,
            "interval": interval,
            "message": "To sign in, use a web browser to open %s and enter the code %s."
                       % (VERIFICATION_URI, "CODE-%s" % scenario.upper()),
        })

    def _device_success(self, scenario):
        body = {
            "token_type": "Bearer",
            "access_token": "FAKE-ACCESS-%s" % scenario,
            "expires_in": 3600,
            "scope": "Mail.Send offline_access openid profile",
            "refresh_token": "FAKE-REFRESH-TOKEN",
        }
        if scenario == "rotated":
            body["refresh_token"] = "ROTATED-REFRESH-TOKEN"
        return self._reply(200, body)

    def _token(self, scenario, form):
        grant = form.get("grant_type") or ""
        if grant == "urn:ietf:params:oauth:grant-type:device_code":
            device_code = form.get("device_code") or "DEVICE"
            key = (scenario, device_code)
            with LOCK:
                DEVICE_POLLS[key] = DEVICE_POLLS.get(key, 0) + 1
                count = DEVICE_POLLS[key]
            if scenario == "expired":
                return self._reply(400, {
                    "error": "authorization_pending",
                    "error_description": "AADSTS70016: OAuth 2.0 device flow error. "
                                         "Authorization is pending.",
                })
            if scenario == "denied":
                return self._reply(400, {
                    "error": "authorization_declined",
                    "error_description": "AADSTS70000: The user declined the authorization.",
                    "error_codes": [70000],
                })
            if scenario == "slow":
                if count == 1:
                    return self._reply(400, {
                        "error": "authorization_pending",
                        "error_description": "AADSTS70016: Authorization is pending.",
                    })
                if count == 2:
                    return self._reply(400, {
                        "error": "slow_down",
                        "error_description": "AADSTS70016: Slow down your polling.",
                    })
                return self._device_success(scenario)
            if count == 1:
                return self._reply(400, {
                    "error": "authorization_pending",
                    "error_description": "AADSTS70016: Authorization is pending.",
                })
            return self._device_success(scenario)

        if grant == "refresh_token":
            if scenario == "tokenfail":
                return self._reply(400, {
                    "error": "invalid_grant",
                    "error_description": "AADSTS70008: The provided authorization "
                                         "grant is expired, revoked, or invalid.",
                    "error_codes": [70008],
                })
            body = {
                "token_type": "Bearer",
                "access_token": "FAKE-ACCESS-%s" % scenario,
                "expires_in": 3600,
                "scope": "Mail.Send offline_access",
            }
            if scenario == "rotated":
                body["refresh_token"] = "ROTATED-REFRESH-TOKEN"
            return self._reply(200, body)

        return self._reply(400, {
            "error": "unsupported_grant_type",
            "error_description": "grant_type=%s" % grant,
        })

    def _sendmail(self, scenario):
        if scenario in ("ok", "rotated", "slow", "expired", "denied", "tokenfail"):
            return self._reply(202, raw=b"")
        if scenario == "senderr":
            return self._reply(403, {
                "error": {
                    "code": "ErrorSendAsDenied",
                    "message": "The user account which was used to submit this request "
                               "does not have the right to send mail on behalf of the "
                               "specified mailbox.",
                }
            })
        if scenario == "send200":
            return self._reply(200, {"ok": True})
        return self._reply(404, {"error": {"code": "NotFound"}})


def main():
    global REQUESTS
    port = int(sys.argv[1])
    REQUESTS = os.path.abspath(sys.argv[2])
    ThreadingHTTPServer.allow_reuse_address = True
    with ThreadingHTTPServer(("127.0.0.1", port), Handler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
