#!/usr/bin/env python3
"""collab-bus: the herdr CLI subset collab-bus uses, served by Herdr App's herdr-core (hc).

Called only through scripts/herdr.sh. Output mirrors herdr 0.9's JSON shapes so every
caller keeps one parser:

  pane current [--current]              {"result":{"pane":{...},"type":"pane_current"}}
  agent list                            {"result":{"agents":[...],"type":"agent_list"}}
  agent get <t>                         {"result":{"agent":{...},"type":"agent_info"}}
  agent wait <t> [--until S] [--timeout ms]
  agent prompt <t> <text> [--wait] [--timeout ms]
  agent read <t> [--lines N]            plain text, as herdr
  status [server]  /  --version

Mapping decisions (each one is a place the two products differ):
  pane_id        the hc address (t7). `--current` is $HC_TERMINAL_ID — the calling
                 terminal, never a focused one, so there is no focused-pane fallback.
  tab_id         the Herdr App tab label `herdr.tab`. A terminal started with `hc run`
                 carries no tab label; it takes its parent's, walking up — a peer the
                 caller launched belongs to the caller's tab, which is what pairing means.
  agent_session  hc exposes no agent session id; `hc-<address>-<created_ms>` is unique per
                 terminal and stable for its lifetime, which is what binding ownership needs.
  agent          hc reports `claude-code`; herdr calls it `claude`.
  timeouts       herdr takes ms, hc seconds. hc's `wait` also ends early on a message to the
                 CALLER (reason `message`); that is not the peer settling, so we wait again
                 until the deadline.
  blocked peer   herdr rejects a prompt to a blocked agent (agent_blocked); hc refuses it
                 too unless --force. We check first and answer with herdr's error code.
Exit codes follow herdr: 0 ok, 1 runtime/server error, 2 usage.
"""
import json
import math
import os
import subprocess
import sys
import time

HC = os.environ.get("COLLAB_HC_BIN") or "herdr-core"
KIND_ALIASES = {"claude-code": "claude"}
SHELLS = {"zsh", "bash", "sh", "fish", "nu", "tcsh", "csh", "dash", "pwsh", None, ""}


def die(code, message, rc=1, cid="hc"):
    sys.stderr.write(json.dumps({"error": {"code": code, "message": message}, "id": cid}) + "\n")
    sys.exit(rc)


def usage(message):
    sys.stderr.write("herdr.sh (Herdr App backend): " + message + "\n")
    sys.exit(2)


def hc(*args, check=True):
    p = subprocess.run([HC, *args, "--json"], capture_output=True, text=True)
    out = p.stdout.strip() or (p.stderr.strip() if p.returncode != 0 else "")
    try:
        data = json.loads(out) if out else {}
    except ValueError:
        data = {}
    if p.returncode != 0 or "error" in data:
        if not check:
            return None
        err = data.get("error") or {}
        kind = err.get("kind") or "hc_error"
        code = {"not_found": "agent_not_found"}.get(kind, kind)
        die(code, err.get("message") or (p.stderr.strip() or out or "hc failed"))
    return data


def term_status(t):
    st = t.get("status")
    if isinstance(st, dict):
        return st.get("state") or "unknown"
    return st or "unknown"


def term_kind(t, ls_agent=None):
    st = t.get("status") if isinstance(t.get("status"), dict) else {}
    app = st.get("app") or ls_agent
    if not app:
        fg = (t.get("foreground") or {}).get("argv") or t.get("argv") or [None]
        app = os.path.basename(fg[0]) if fg[0] else None
    return KIND_ALIASES.get(app, app)


_cache = {}


def get(addr):
    if addr not in _cache:
        _cache[addr] = hc("get", addr)
    return _cache[addr]


def placement(t):
    """(tab, space) of a terminal: its own Herdr App labels, else its nearest ancestor's."""
    seen = set()
    cur = t
    while cur is not None and cur.get("address") not in seen:
        seen.add(cur.get("address"))
        labels = cur.get("labels") or {}
        if labels.get("herdr.tab"):
            return labels["herdr.tab"], labels.get("herdr.space", "")
        parent = cur.get("parent")
        cur = hc("get", parent, check=False) if parent else None
    return "hc-" + t["address"], ""


def agent_obj(t, ls_agent=None):
    addr = t["address"]
    kind = term_kind(t, ls_agent)
    labels = t.get("labels") or {}
    tab, space = placement(t)
    title = t.get("title") or ""
    return {
        "agent": kind,
        "name": t.get("name"),
        "agent_session": {"agent": kind, "kind": "id", "source": "herdr-core",
                          "value": "hc-%s-%s" % (addr, t.get("created_ms"))},
        "agent_status": term_status(t),
        "cwd": t.get("cwd"),
        "foreground_cwd": (t.get("foreground") or {}).get("cwd") or t.get("cwd"),
        "pane_id": addr,
        "tab_id": tab,
        "workspace_id": space,
        "terminal_title": title,
        "terminal_title_stripped": title,
        "where": labels.get("where"),
        "turn": t.get("turn"),
    }


def emit(cid, typ, key, value):
    print(json.dumps({"id": cid, "result": {key: value, "type": typ}}, ensure_ascii=False))


def opt(args, name, default=None, flag=False):
    """Pop --name [value] from args (in place)."""
    if name not in args:
        return default
    i = args.index(name)
    if flag:
        del args[i]
        return True
    if i + 1 >= len(args):
        usage("%s needs a value" % name)
    v = args[i + 1]
    del args[i:i + 2]
    return v


def secs(ms):
    return max(1, int(math.ceil(int(ms) / 1000.0)))


# --- commands ---------------------------------------------------------------

def cmd_pane_current(args):
    opt(args, "--current", flag=True)
    me = os.environ.get("HC_TERMINAL_ID")
    if not me:
        die("not_in_terminal", "HC_TERMINAL_ID is not set — not running inside a Herdr App terminal")
    emit("cli:pane:current", "pane_current", "pane", agent_obj(get(me)))


def cmd_agent_list(args):
    ls = hc("ls")
    agents = []
    for e in ls.get("terminals") or []:
        if e.get("state") != "live" or e.get("agent") in SHELLS:
            continue
        t = hc("get", e["address"], check=False)
        if t:
            agents.append(agent_obj(t, e.get("agent")))
    emit("cli:agent:list", "agent_list", "agents", agents)


def cmd_agent_get(args):
    if not args:
        usage("agent get <target>")
    emit("cli:agent:get", "agent_info", "agent", agent_obj(get(args[0])))


def settle(addr, timeout_ms):
    """Wait until <addr> stops working; returns the hc wait result (status set)."""
    deadline = time.monotonic() + int(timeout_ms) / 1000.0
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            die("timeout", "agent %s did not settle within %sms" % (addr, timeout_ms))
        w = hc("wait", addr, "--timeout", str(max(1, int(math.ceil(left)))))
        reason = w.get("reason")
        if reason in ("message", "timeout") and time.monotonic() < deadline - 0.5:
            continue  # a note to the caller, or an hc check-in — not the peer settling
        if reason == "timeout":
            die("timeout", "agent %s did not settle within %sms" % (addr, timeout_ms))
        if w.get("exit_code") is not None or w.get("signal") is not None:
            die("agent_not_found", "agent %s exited" % addr)
        return w


def until(addr, states, timeout_ms):
    deadline = time.monotonic() + int(timeout_ms) / 1000.0
    while True:
        _cache.pop(addr, None)
        t = get(addr)
        if term_status(t) in states:
            return t
        if time.monotonic() >= deadline:
            die("timeout", "agent %s did not reach %s within %sms" % (addr, "/".join(states), timeout_ms))
        time.sleep(0.25)


def cmd_agent_wait(args):
    timeout_ms = opt(args, "--timeout", "600000")
    want = opt(args, "--until")
    if not args:
        usage("agent wait <target> [--until STATE] [--timeout MS]")
    addr = args[0]
    if want:
        t = until(addr, set(want.split(",")), timeout_ms)
    else:
        w = settle(addr, timeout_ms)
        t = dict(get(addr))
        if w.get("status"):
            t = dict(t, status={"state": w["status"]})
    emit("cli:agent:wait", "agent_info", "agent", agent_obj(t))


def cmd_agent_prompt(args):
    do_wait = opt(args, "--wait", False, flag=True)
    timeout_ms = opt(args, "--timeout", "600000")
    if len(args) < 2:
        usage("agent prompt <target> <text> [--wait] [--timeout MS]")
    addr, text = args[0], " ".join(args[1:])
    t = get(addr)
    if term_status(t) == "blocked":
        die("agent_blocked", "agent %s is blocked on an approval UI; not prompting" % addr)
    if not do_wait:
        r = hc("send", addr, text)
        if not r.get("started", True):
            die("agent_prompt_stalled", "hc accepted the text but %s did not start a turn; read it before resending" % addr)
        emit("cli:agent:prompt", "agent_prompted", "agent", agent_obj(dict(t, status={"state": r.get("status") or "working"})))
        return
    # `hc send --wait` waits for the turn THIS send started (hc numbers turns), so it
    # cannot match an earlier turn's end. It can still end early — a message to the
    # caller, or hc's check-in timeout — and then we keep waiting on the same turn.
    start = time.monotonic()
    r = hc("send", addr, text, "--wait", "--timeout", str(secs(timeout_ms)))
    if not r.get("started", True):
        die("agent_prompt_stalled", "hc accepted the text but %s did not start a turn; read it before resending" % addr)
    w = r.get("wait") or {}
    left_ms = int(timeout_ms) - int((time.monotonic() - start) * 1000)
    if w.get("reason") in ("message", "timeout") or not w.get("status"):
        if left_ms <= 0:
            die("timeout", "agent %s did not settle within %sms" % (addr, timeout_ms))
        w = settle(addr, left_ms)
    _cache.pop(addr, None)
    emit("cli:agent:prompt", "agent_prompted", "agent", agent_obj(dict(get(addr), status={"state": w.get("status") or "unknown"})))


def cmd_agent_read(args):
    lines = opt(args, "--lines", "0")
    opt(args, "--source", None)
    if not args:
        usage("agent read <target> [--lines N]")
    p = subprocess.run([HC, "read", args[0], "--lines", str(lines)], capture_output=True, text=True)
    if p.returncode != 0:
        die("agent_not_found", p.stderr.strip() or p.stdout.strip())
    sys.stdout.write(p.stdout)


def cmd_status(args):
    s = hc("server", "status", check=False)
    if not s:
        print("server:\n  status: not running\n  backend: herdr-core")
        sys.exit(1)
    print("client:\n  backend: herdr-core (Herdr App)\n\nserver:\n  status: running\n  version: hc %s" % s.get("version", "?"))


def cmd_version(args):
    p = subprocess.run([HC, "--version"], capture_output=True, text=True)
    # Reported as herdr 0.9 so version gates (>= 0.8) pass: every command collab-bus
    # needs from 0.8/0.9 is provided here.
    print("herdr 0.9.0 (collab-bus Herdr App backend; %s)" % (p.stdout.strip() or "hc"))


UNSUPPORTED_HINT = ("not available on Herdr App. Start a peer in this tab with "
                    "`herdr-core run --bg --name <NAME> --cwd \"$PWD\" <kind>` "
                    "(it inherits this tab), then use its address (t7) as the pane_id.")


def main(argv):
    if not argv:
        usage("no command")
    a = list(argv)
    head = a[0]
    if head in ("--version", "-V", "version"):
        return cmd_version(a[1:])
    if head == "status":
        return cmd_status(a[1:])
    if len(a) < 2:
        usage("unknown command: %s" % head)
    sub = (head, a[1])
    rest = a[2:]
    table = {
        ("pane", "current"): cmd_pane_current,
        ("agent", "list"): cmd_agent_list,
        ("agent", "get"): cmd_agent_get,
        ("agent", "wait"): cmd_agent_wait,
        ("agent", "prompt"): cmd_agent_prompt,
        ("agent", "read"): cmd_agent_read,
        ("pane", "read"): cmd_agent_read,
    }
    if sub in table:
        return table[sub](rest)
    if sub in (("agent", "start"), ("pane", "split"), ("agent", "rename")):
        die("unsupported", "`herdr %s %s` is %s" % (sub[0], sub[1], UNSUPPORTED_HINT))
    usage("`herdr %s %s` is not part of the collab-bus subset" % sub)


if __name__ == "__main__":
    main(sys.argv[1:])
