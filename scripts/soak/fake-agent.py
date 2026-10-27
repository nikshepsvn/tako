#!/usr/bin/python3 -I
"""Stands in for Claude Code inside a Tako terminal, so a soak costs nothing.

Installed by scripts/soak.sh over $HT_HOME/bin/claude in a dev instance only. It reads the
environment Tako gives an agent (HT_SESSION_ID, HT_HOOK_TOKEN) and replays what a busy agent
does, in a loop: a prompt, a run of tool calls with 1-20 KB payloads (Bash output, file reads,
edits in a git repo), terminal output, statusline reports, subagents, tasks, and a Stop with a
long final message. SOAK_RATE scales the pace (1 = a turn every ~4 s).
"""
import json, os, random, string, subprocess, sys, time, urllib.request, uuid

home = os.environ.get("HT_HOME") or os.path.expanduser("~/.tako")
session = os.environ["HT_SESSION_ID"]
token = os.environ["HT_HOOK_TOKEN"]
ht = os.path.join(home, "bin", "ht")
rate = float(os.environ.get("SOAK_RATE", "1"))
cwd = os.getcwd()
conversation = str(uuid.uuid4())
for i, arg in enumerate(sys.argv):
    if arg == "--session-id" and i + 1 < len(sys.argv):
        conversation = sys.argv[i + 1]

def hook_url():
    with open(os.path.join(home, "claude-settings.json")) as f:
        settings = json.load(f)
    return settings["hooks"]["PreToolUse"][0]["hooks"][0]["url"]

URL = hook_url()

def words(n):
    return " ".join("".join(random.choices(string.ascii_lowercase, k=random.randint(2, 9))) for _ in range(n))

def blob(kb):
    lines = []
    while sum(len(l) for l in lines) < kb * 1024:
        lines.append(f"{random.randint(1, 9999):>5}  {words(random.randint(4, 14))}")
    return "\n".join(lines)

def post(event, **fields):
    body = {"session_id": conversation, "transcript_path": "/dev/null", "cwd": cwd,
            "hook_event_name": event, "permission_mode": "default", **fields}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST", headers={
        "Content-Type": "application/json", "X-HT-Session": session, "Authorization": f"Bearer {token}"})
    try:
        urllib.request.urlopen(req, timeout=5).read()
    except Exception as error:  # a dropped hook must not stop the soak
        print(f"hook {event} failed: {error}", file=sys.stderr)

def statusline(turn):
    payload = {"session_id": conversation, "cwd": cwd, "model": {"display_name": "Opus"},
               "cost": {"total_cost_usd": turn * 0.13},
               "context_window": {"used_percentage": (turn * 3) % 100},
               "rate_limits": {"five_hour": {"used_percentage": turn % 100, "resets_at": time.time() + 3600},
                               "seven_day": {"used_percentage": 40, "resets_at": time.time() + 86400}}}
    subprocess.run([ht, "statusline"], input=json.dumps(payload).encode(), stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=5)

def tool(name, tool_input, response, fail=False):
    use_id = "toolu_" + uuid.uuid4().hex[:20]
    post("PreToolUse", tool_name=name, tool_input=tool_input, tool_use_id=use_id)
    time.sleep(0.05 / rate)
    if fail:
        post("PostToolUseFailure", tool_name=name, tool_input=tool_input, tool_use_id=use_id, error=blob(2))
    else:
        post("PostToolUse", tool_name=name, tool_input=tool_input, tool_use_id=use_id, tool_response=response)

def edit_repo(turn):
    path = os.path.join(cwd, f"src/file{turn % 7}.txt")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        f.write(blob(1) + "\n")
    return path

def turn(n):
    post("UserPromptSubmit", prompt=f"Turn {n}: " + words(random.randint(20, 400)))
    statusline(n)
    for _ in range(random.randint(4, 12)):
        kind = random.random()
        if kind < 0.35:
            out = blob(random.randint(1, 20))
            print(out[: random.randint(2000, 20000)])  # what Claude's TUI would paint
            command = random.choice(["npm test", "swift test", "ls -la", "rg TODO", "git status", "pytest -q"])
            tool("Bash", {"command": command, "description": words(5)},
                 {"stdout": out, "stderr": blob(1) if random.random() < 0.2 else "", "interrupted": False},
                 fail=random.random() < 0.05)
        elif kind < 0.6:
            path = os.path.join(cwd, f"src/file{random.randint(0, 6)}.txt")
            tool("Read", {"file_path": path}, {"type": "text", "file": {"filePath": path, "content": blob(random.randint(2, 20))}})
        elif kind < 0.85:
            path = edit_repo(n)
            tool("Edit", {"file_path": path, "old_string": words(30), "new_string": blob(1)},
                 {"filePath": path, "oldString": words(30), "newString": blob(1), "structuredPatch": [{"lines": blob(3).splitlines()}]})
        elif kind < 0.92:
            tool("Grep", {"pattern": words(1), "path": cwd}, {"filenames": [f"src/{words(1)}.swift" for _ in range(200)]})
        else:
            agent = uuid.uuid4().hex[:12]
            post("SubagentStart", agent_id=agent, agent_type="Explore")
            tool("Task", {"description": words(4), "prompt": words(200)}, {"content": [{"type": "text", "text": blob(8)}]})
            post("SubagentStop", agent_id=agent, agent_type="Explore", last_assistant_message=blob(3))
        if random.random() < 0.1:
            task = uuid.uuid4().hex[:8]
            post("TaskCreated", task_id=task, task_subject=words(6))
            post("TaskCompleted", task_id=task, task_subject=words(6))
        time.sleep(random.uniform(0.05, 0.3) / rate)
    if random.random() < 0.05:
        post("Notification", notification_type="idle_prompt", message="Claude is waiting for your input")
    post("Stop", stop_hook_active=False, last_assistant_message="Done. " + blob(random.randint(1, 6)))
    statusline(n)

post("SessionStart", source="startup")
n = 0
while True:
    n += 1
    turn(n)
    time.sleep(random.uniform(1, 4) / rate)
