#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
agent-cli.py - client for server-agent.ps1

Config is read from agent-config.json next to this file, or from env vars:
    AGENT_HOST / AGENT_PORT / AGENT_TOKEN

Usage:
    python agent-cli.py health
    python agent-cli.py info
    python agent-cli.py exec "ipconfig /all"
    python agent-cli.py exec "Get-Process" --shell powershell
    python agent-cli.py script mysql-diag.ps1
    python agent-cli.py script fix.cmd --shell cmd
    python agent-cli.py tail "C:\\ProgramData\\MySQL\\...\\xxx.err" --lines 300
    python agent-cli.py ls "C:\\Program Files\\MySQL"
    python agent-cli.py get  "C:\\remote\\file.txt" -o local.txt
    python agent-cli.py put  local.txt "C:\\remote\\file.txt"
    python agent-cli.py stop
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(HERE, "agent-config.json")


def load_config():
    cfg = {}
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception as e:
            print(f"[warn] bad config file: {e}", file=sys.stderr)
    cfg.setdefault("host", os.environ.get("AGENT_HOST", "127.0.0.1"))
    cfg.setdefault("port", int(os.environ.get("AGENT_PORT", "8765")))
    cfg.setdefault("token", os.environ.get("AGENT_TOKEN", ""))
    return cfg


class Agent:
    def __init__(self, host, port, token, timeout=900):
        self.base = f"http://{host}:{port}"
        self.token = token
        self.timeout = timeout

    def _req(self, method, path, body=None, raw=False, query=None):
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = None
        headers = {}
        if self.token:
            headers["X-Agent-Token"] = self.token
        if body is not None:
            if isinstance(body, str):
                data = body.encode("utf-8")
            else:
                data = body
            headers["Content-Type"] = "application/json; charset=utf-8"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            # Bypass any http_proxy/https_proxy in the environment: the agent is
            # reached directly, never through a corporate/local proxy.
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=self.timeout) as resp:
                payload = resp.read()
        except urllib.error.HTTPError as e:
            payload = e.read()
            try:
                return json.loads(payload.decode("utf-8", "replace"))
            except Exception:
                return {"ok": False, "error": f"HTTP {e.code}", "raw": payload[:2000].decode("utf-8", "replace")}
        except Exception as e:
            return {"ok": False, "error": f"{type(e).__name__}: {e}"}
        if raw:
            return payload
        try:
            return json.loads(payload.decode("utf-8", "replace"))
        except Exception:
            return {"raw": payload.decode("utf-8", "replace")}

    def probe(self):
        """Raw TCP reachability test - distinguishes 'no route' from 'blocked'."""
        import socket
        host = self.base.split("//")[1].split(":")[0]
        port = int(self.base.split(":")[-1])
        s = socket.socket()
        s.settimeout(6)
        try:
            s.connect((host, port))
            s.close()
            return f"TCP {host}:{port} -> OPEN"
        except Exception as e:
            return f"TCP {host}:{port} -> FAIL ({type(e).__name__}: {e})"
        finally:
            try:
                s.close()
            except Exception:
                pass

    def exec(self, cmd, shell="cmd", timeout=120, cwd=""):
        body = {"cmd": cmd, "shell": shell, "timeout": timeout}
        if cwd:
            body["cwd"] = cwd
        return self._req("POST", "/exec", json.dumps(body, ensure_ascii=False))

    def script(self, text, shell="powershell", timeout=300):
        return self._req("POST", "/script", text, query={"shell": shell, "timeout": timeout})

    def tail(self, path, lines=200):
        return self._req("GET", "/tail", query={"path": path, "lines": lines})

    def ls(self, path):
        return self._req("GET", "/ls", query={"path": path})

    def info(self):
        return self._req("GET", "/info")

    def health(self):
        return self._req("GET", "/health")

    def get_file(self, path):
        return self._req("GET", "/file", raw=True, query={"path": path})

    def put_file(self, local, remote):
        with open(local, "rb") as f:
            data = f.read()
        body = {"path": remote, "encoding": "base64", "content": base64.b64encode(data).decode()}
        return self._req("POST", "/file", json.dumps(body))


def show_result(r, as_json=False):
    if as_json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return
    if r.get("stdout"):
        sys.stdout.write(r["stdout"])
        if not r["stdout"].endswith("\n"):
            sys.stdout.write("\n")
    if r.get("stderr"):
        sys.stdout.write("--- stderr ---\n")
        sys.stdout.write(r["stderr"])
        if not r["stderr"].endswith("\n"):
            sys.stdout.write("\n")
    meta = {k: v for k, v in r.items() if k not in ("stdout", "stderr", "content", "items")}
    sys.stdout.write(f"--- meta --- {json.dumps(meta, ensure_ascii=False)}\n")


def main():
    cfg = load_config()
    ap = argparse.ArgumentParser(description="RemoteOps agent client")
    ap.add_argument("--host", default=cfg["host"])
    ap.add_argument("--port", type=int, default=cfg["port"])
    ap.add_argument("--token", default=cfg["token"])
    ap.add_argument("--json", action="store_true", help="dump raw JSON response")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("health")
    sub.add_parser("probe")
    sub.add_parser("info")
    p = sub.add_parser("exec")
    p.add_argument("command")
    p.add_argument("--shell", default="cmd", choices=["cmd", "powershell"])
    p.add_argument("--timeout", type=int, default=120)
    p.add_argument("--cwd", default="")

    p = sub.add_parser("script")
    p.add_argument("file")
    p.add_argument("--shell", default="powershell", choices=["cmd", "powershell"])
    p.add_argument("--timeout", type=int, default=300)

    p = sub.add_parser("tail")
    p.add_argument("path")
    p.add_argument("--lines", type=int, default=200)

    p = sub.add_parser("ls")
    p.add_argument("path")

    p = sub.add_parser("get")
    p.add_argument("path")
    p.add_argument("-o", "--out", required=True)

    p = sub.add_parser("put")
    p.add_argument("local")
    p.add_argument("remote")

    sub.add_parser("stop")

    args = ap.parse_args()
    agent = Agent(args.host, args.port, args.token)

    if args.cmd == "probe":
        print(agent.probe())
        print(json.dumps(agent.health(), ensure_ascii=False))
    elif args.cmd == "health":
        print(json.dumps(agent.health(), ensure_ascii=False, indent=2))
    elif args.cmd == "info":
        print(json.dumps(agent.info(), ensure_ascii=False, indent=2))
    elif args.cmd == "exec":
        show_result(agent.exec(args.command, args.shell, args.timeout, args.cwd), args.json)
    elif args.cmd == "script":
        with open(args.file, "r", encoding="utf-8") as f:
            text = f.read()
        show_result(agent.script(text, args.shell, args.timeout), args.json)
    elif args.cmd == "tail":
        r = agent.tail(args.path, args.lines)
        if r.get("ok"):
            print(r["content"])
        else:
            print(json.dumps(r, ensure_ascii=False))
    elif args.cmd == "ls":
        r = agent.ls(args.path)
        if r.get("ok"):
            print(r["path"])
            for it in r.get("items", []):
                flag = "d" if it["dir"] else "-"
                print(f"  {flag} {it['size']:>12}  {it['mtime']}  {it['name']}")
        else:
            print(json.dumps(r, ensure_ascii=False))
    elif args.cmd == "get":
        data = agent.get_file(args.path)
        if isinstance(data, dict):
            print(json.dumps(data, ensure_ascii=False))
            sys.exit(1)
        with open(args.out, "wb") as f:
            f.write(data)
        print(f"saved {len(data)} bytes -> {args.out}")
    elif args.cmd == "put":
        print(json.dumps(agent.put_file(args.local, args.remote), ensure_ascii=False))
    elif args.cmd == "stop":
        print(json.dumps(agent._req("POST", "/stop", ""), ensure_ascii=False))


if __name__ == "__main__":
    main()
