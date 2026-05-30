#!/usr/bin/env python3
"""claude-island: Claude Code hook -> ~/.claude/island/state.json

Reads one hook-event JSON object on stdin and merges it into a shared
state file that the ClaudeIsland menu-bar app watches via FSEvents.

Design rules (do not break Claude Code):
  * never write to stdout (UserPromptSubmit/SessionStart stdout is injected
    into the model context) -- we only touch files.
  * always exit 0 (a non-zero PreToolUse hook can BLOCK the tool call).
  * be fast: tiny stdlib imports, single flock, atomic replace.
"""
import json
import os
import sys
import time
import fcntl

HOME = os.path.expanduser("~")
ISLAND_DIR = os.path.join(HOME, ".claude", "island")
STATE_PATH = os.path.join(ISLAND_DIR, "state.json")
LOCK_PATH = os.path.join(ISLAND_DIR, "state.lock")

STALE_TTL = 3600  # drop sessions not updated within an hour


def pid_alive(pid):
    """True if the owning Claude process is still around (EPERM counts as alive)."""
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return True


# USD per 1M tokens: (input, output, cache_write, cache_read). Update if pricing
# shifts — cost is an estimate (the transcript has no per-message cost field).
PRICES = {
    "opus": (15.0, 75.0, 18.75, 1.50),
    "sonnet": (3.0, 15.0, 3.75, 0.30),
    "haiku": (1.0, 5.0, 1.25, 0.10),
}


def _price(model):
    m = (model or "").lower()
    if "opus" in m:
        return PRICES["opus"]
    if "haiku" in m:
        return PRICES["haiku"]
    return PRICES["sonnet"]


EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}


def tally_transcript(path):
    """Scan the session transcript for cumulative cost, current context size, and
    the number of distinct files this session edited. Returns a dict or None."""
    try:
        if not path or os.path.getsize(path) > 50 * 1024 * 1024:
            return None  # skip pathologically large files rather than block
    except OSError:
        return None
    ctx = out_total = 0
    cost = 0.0
    edited = set()
    try:
        with open(path) as f:
            for line in f:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") != "assistant":
                    continue
                m = o.get("message") or {}
                u = m.get("usage") or {}
                inp = u.get("input_tokens", 0) or 0
                out = u.get("output_tokens", 0) or 0
                cw = u.get("cache_creation_input_tokens", 0) or 0
                cr = u.get("cache_read_input_tokens", 0) or 0
                pi, po, pcw, pcr = _price(m.get("model"))
                cost += (inp * pi + out * po + cw * pcw + cr * pcr) / 1e6
                out_total += out
                ctx = inp + cw + cr  # last message wins -> current context size
                content = m.get("content")
                if isinstance(content, list):
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "tool_use" \
                                and b.get("name") in EDIT_TOOLS:
                            inp2 = b.get("input") or {}
                            fp = inp2.get("file_path") or inp2.get("notebook_path")
                            if fp:
                                edited.add(fp)
    except Exception:
        return None
    return {"ctx_tokens": ctx, "out_tokens": out_total,
            "cost_usd": round(cost, 4), "files_changed": len(edited)}


def humanize(tool, ti):
    """Turn a tool name + input into a short, human line for the notch."""
    ti = ti or {}

    def base(p):
        return os.path.basename(str(p)) if p else ""

    if tool == "Bash":
        cmd = (ti.get("command") or "").strip().replace("\n", " ")
        if not cmd:
            return "$ shell"
        return "$ " + (cmd[:48] + "…" if len(cmd) > 48 else cmd)
    if tool in ("Edit", "MultiEdit", "Write", "NotebookEdit"):
        return "✎ " + base(ti.get("file_path") or ti.get("notebook_path"))
    if tool == "Read":
        return "\U0001F4D6 " + base(ti.get("file_path"))
    if tool in ("Grep", "Glob"):
        return "\U0001F50E " + str(ti.get("pattern") or "")
    if tool == "WebFetch":
        url = str(ti.get("url") or "")
        host = url.split("/")[2] if "://" in url else url
        return "\U0001F310 " + host
    if tool == "WebSearch":
        return "\U0001F50E " + str(ti.get("query") or "")
    if tool in ("Task", "Agent"):
        return "\U0001F916 " + str(ti.get("description") or ti.get("subagent_type") or "subagent")
    if tool == "TodoWrite":
        return "✓ 待办更新"
    return tool or "working"


def main():
    try:
        evt = json.load(sys.stdin)
    except Exception:
        return 0

    sid = evt.get("session_id") or "unknown"
    name = evt.get("hook_event_name") or (sys.argv[1] if len(sys.argv) > 1 else "")
    now = time.time()
    cwd = evt.get("cwd") or ""
    project = os.path.basename(cwd.rstrip("/")) if cwd else "Claude"

    os.makedirs(ISLAND_DIR, exist_ok=True)
    lock = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)

        state = {"sessions": {}}
        try:
            with open(STATE_PATH) as f:
                loaded = json.load(f)
                if isinstance(loaded, dict) and isinstance(loaded.get("sessions"), dict):
                    state = loaded
        except FileNotFoundError:
            pass
        except Exception:
            pass

        sessions = state["sessions"]
        s = sessions.get(sid) or {"session_id": sid}
        s["cwd"] = cwd or s.get("cwd", "")
        s["project"] = project
        s["updated_at"] = now
        # Owning Claude process: our parent (hook is spawned directly by claude).
        # Lets the consumer reap zombie sessions whose process is gone.
        s["pid"] = os.getppid()
        s["term"] = os.environ.get("TERM_PROGRAM", "") or s.get("term", "")
        s["transcript_path"] = evt.get("transcript_path") or s.get("transcript_path", "")
        # tty of the owning terminal tab -> lets the app raise the exact window
        # on click. Cheap-ish (one ps), so only capture once per session.
        if name == "SessionStart" or not s.get("tty"):
            try:
                import subprocess
                s["tty"] = subprocess.check_output(
                    ["ps", "-o", "tty=", "-p", str(os.getppid())], text=True
                ).strip()
            except Exception:
                s["tty"] = s.get("tty", "")

        if name == "SessionStart":
            s.setdefault("started_at", now)
            s["state"] = "idle"
            s["activity"] = "就绪"
            s["tools_run"] = 0
            s["message"] = ""
            s["finished_at"] = None
        elif name == "UserPromptSubmit":
            s["state"] = "working"
            s["activity"] = "思考中…"
            s["started_at"] = now
            s["tools_run"] = 0
            s["message"] = ""
            s["finished_at"] = None
        elif name == "PreToolUse":
            s["state"] = "working"
            s["tool"] = evt.get("tool_name") or ""
            s["activity"] = humanize(evt.get("tool_name"), evt.get("tool_input"))
            s.setdefault("started_at", now)
        elif name == "PostToolUse":
            s["state"] = "working"
            s["tools_run"] = int(s.get("tools_run", 0) or 0) + 1
        elif name == "Notification":
            s["state"] = "attention"
            s["message"] = evt.get("message") or "需要你的输入"
            s["activity"] = s["message"]
        elif name == "Stop":
            s["state"] = "done"
            s["finished_at"] = now
            s["activity"] = "完成"
            tally = tally_transcript(s.get("transcript_path"))
            if tally:
                s.update(tally)
        elif name == "SessionEnd":
            sessions.pop(sid, None)
            s = None

        if s is not None:
            sessions[sid] = s

        # Self-heal: drop sessions whose process is dead, or that went silent
        # for over an hour (legacy records with no pid).
        for k in list(sessions.keys()):
            sk = sessions[k]
            pid = sk.get("pid")
            dead = pid is not None and not pid_alive(pid)
            stale = now - float(sk.get("updated_at", 0) or 0) > STALE_TTL
            if dead or stale:
                sessions.pop(k, None)

        state["updated_at"] = now
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f, ensure_ascii=False)
        os.replace(tmp, STATE_PATH)
    except Exception:
        pass
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_UN)
        except Exception:
            pass
        lock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
