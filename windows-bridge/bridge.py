#!/usr/bin/env python3
"""TONY TRAN EA CONTROL local bridge. Use LAN/Tailscale only; never port-forward publicly."""
import argparse
import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "ea_connected": False, "ea_status": "WAITING_FOR_EA", "symbol": None,
    "balance": None, "equity": None, "open_positions": None,
    "floating_profit": None, "last_heartbeat": None, "trading_enabled": None,
}
COMMANDS = []
SETTINGS = {}
LOCK = threading.Lock()
TOKEN = ""
MAX_QUEUE = 100


class Handler(BaseHTTPRequestHandler):
    def auth(self):
        return secrets.compare_digest(self.headers.get("Authorization", ""), "Bearer " + TOKEN)

    def send_json(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def read_json(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size < 0 or size > 16384:
            raise ValueError("invalid body size")
        return json.loads(self.rfile.read(size) or b"{}")

    def do_GET(self):
        if not self.auth():
            return self.send_json(401, {"ok": False, "error": "unauthorized"})
        if self.path == "/api/status":
            with LOCK:
                return self.send_json(200, dict(STATE))
        if self.path == "/api/commands/next":
            with LOCK:
                for item in COMMANDS:
                    if item["status"] == "QUEUED":
                        item["status"] = "DELIVERED"
                        # Flatten the payload because the MQL5 EA consumes command fields.
                        return self.send_json(200, {"id": item["id"], **item["payload"]})
            return self.send_json(200, {"id": None, "empty": True})
        if self.path == "/api/settings":
            with LOCK:
                return self.send_json(200, {"settings": SETTINGS, "status": "STAGED_ONLY"})
        return self.send_json(404, {"ok": False})

    def do_POST(self):
        if not self.auth():
            return self.send_json(401, {"ok": False, "error": "unauthorized"})
        try:
            data = self.read_json()
        except Exception:
            return self.send_json(400, {"ok": False, "error": "invalid_json"})
        if not isinstance(data, dict):
            return self.send_json(400, {"ok": False, "error": "object_required"})

        if self.path == "/api/command":
            command_type = data.get("type")
            if command_type not in {"BUY", "SELL", "CLOSE_ALL", "MOVE_STOP", "PING", "EA_ENABLE", "EA_DISABLE"}:
                return self.send_json(400, {"ok": False, "error": "unsupported_command"})
            if command_type == "MOVE_STOP":
                try:
                    step = float(data.get("step_pips", 0))
                except (TypeError, ValueError):
                    step = 0
                if not 0 < step <= 1000:
                    return self.send_json(400, {"ok": False, "error": "step_pips_out_of_range"})
            with LOCK:
                if len(COMMANDS) >= MAX_QUEUE:
                    return self.send_json(429, {"ok": False, "error": "queue_full"})
                item = {"id": secrets.token_hex(16), "payload": data, "status": "QUEUED"}
                COMMANDS.append(item)
            return self.send_json(202, {"ok": True, "queued": {"id": item["id"], "status": item["status"]}})

        if self.path == "/api/settings":
            allowed = {"lots", "initial_stop_units", "max_positions", "cycle_target_usd"}
            if set(data) - allowed:
                return self.send_json(400, {"ok": False, "error": "unknown_setting"})
            # Deliberately staged only. EA runtime setting application is not enabled in this build.
            with LOCK:
                SETTINGS.update(data)
            return self.send_json(202, {"ok": True, "status": "STAGED_ONLY", "message": "Not applied to EA."})

        if self.path == "/api/ea/heartbeat":
            with LOCK:
                STATE.update(data)
                STATE["ea_connected"] = True
                STATE["ea_status"] = "CONNECTED"
                import time
                STATE["last_heartbeat"] = int(time.time())
            return self.send_json(200, {"ok": True})

        if self.path.startswith("/api/commands/ack/"):
            cid = self.path.rsplit("/", 1)[-1]
            with LOCK:
                for item in COMMANDS:
                    if item["id"] == cid:
                        item["status"] = str(data.get("status", "ACK"))[:20]
                        item["result"] = data
                        return self.send_json(200, {"ok": True})
            return self.send_json(404, {"ok": False, "error": "command_not_found"})

        return self.send_json(404, {"ok": False})

    def log_message(self, fmt, *args):
        print("[bridge]", fmt % args)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", required=True)
    args = parser.parse_args()
    if len(args.token) < 32:
        raise SystemExit("Token must contain at least 32 characters")
    TOKEN = args.token
    print("TONY TRAN EA CONTROL Bridge listening on %s:%s" % (args.host, args.port))
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
