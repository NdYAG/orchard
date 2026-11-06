#!/usr/bin/env python3
"""End-to-end test of the pi extension, driving `pi --mode rpc` (no model calls).

Run tests/smoke.sh first: it leaves a configured throwaway repo (/tmp/orchard-test/repo) and an
unconfigured clone (/tmp/orchard-test/other). Skips when pi is not installed.
"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXTENSION = ROOT / "extensions" / "pi" / "index.ts"
CLI = ROOT / "bin" / "orchard"
T = Path("/tmp/orchard-test")
REPO, OTHER = T / "repo", T / "other"
SESSIONS = Path("/tmp/orchard-test/pi-sessions")
ENV = {**os.environ, "ORCHARD_CONFIG": str(T / "config/orchard/repos.json"), "ORCHARD_CACHE_DIR": str(T / "cache/orchard")}

failures = 0


def check(description, condition, detail=""):
    global failures
    print(f"  {'ok' if condition else 'FAIL'} {description}" + ("" if condition else f"  [{detail}]"))
    failures += 0 if condition else 1


class Pi:
    """One `pi --mode rpc` process. Dialogs are answered automatically with `confirm`."""

    def __init__(self, cwd, session=None, confirm=True):
        args = ["pi", "--mode", "rpc", "--session-dir", str(SESSIONS), "-e", str(EXTENSION)]
        if session:
            args += ["--session", str(session)]
        self.confirm, self.notes, self.dialogs, self.bash_results, self.lock = confirm, [], [], [], threading.Lock()
        self.proc = subprocess.Popen(args, cwd=cwd, env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self._read, daemon=True).start()
        time.sleep(3)

    def _send(self, obj):
        self.proc.stdin.write(json.dumps(obj).encode() + b"\n")
        self.proc.stdin.flush()

    def _read(self):
        for raw in iter(self.proc.stdout.readline, b""):
            r = json.loads(raw)
            with self.lock:
                if r.get("type") == "extension_ui_request" and r.get("method") == "notify":
                    self.notes.append(r["message"])
                elif r.get("type") == "extension_ui_request" and r.get("method") == "confirm":
                    self.dialogs.append(r.get("title"))
                    self._send({"type": "extension_ui_response", "id": r["id"], "confirmed": self.confirm})
                elif r.get("type") == "response" and r.get("command") == "bash":
                    self.bash_results.append(r.get("data", {}).get("output", "").strip())

    def say(self, text, expect, timeout=60):
        """Send a slash command; return the first notification containing `expect`, or None."""
        with self.lock:
            self.notes.clear()
        self._send({"type": "prompt", "message": text})
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for note in self.notes:
                    if expect in note:
                        return note
            time.sleep(0.2)
        return None

    def bash(self, command, timeout=15):
        with self.lock:
            self.bash_results.clear()
        self._send({"type": "bash", "command": command})
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if self.bash_results:
                    return self.bash_results[0]
            time.sleep(0.2)
        return None

    def stop(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def cli(*args):
    return subprocess.run([sys.executable, str(CLI), *args], capture_output=True, text=True, env=ENV).stdout


def set_worktrees_dir(value):
    """Point the throwaway repo's config at another worktrees directory (None: back to the default)."""
    path = Path(ENV["ORCHARD_CONFIG"])
    config = json.loads(path.read_text())
    entry = config[str(REPO.resolve())]
    entry.pop("worktrees_dir", None)
    if value:
        entry["worktrees_dir"] = value
    path.write_text(json.dumps(config))


def release_leftovers(real_repo):
    """Park worktrees an earlier (possibly aborted) run left behind, so names can be reused."""
    for leftover in (Path(real_repo) / ".pi/worktrees").glob("pi-*"):
        cli("release", str(leftover))


def main():
    if not shutil.which("pi"):
        print("pi is not installed: skipping")
        return 0
    if not REPO.exists():
        print("run tests/smoke.sh first", file=sys.stderr)
        return 2
    shutil.rmtree(SESSIONS, ignore_errors=True)
    real_repo = str(REPO.resolve())
    release_leftovers(real_repo)

    print("1. new: claim a plot and move the session into it")
    pi = Pi(REPO)
    note = pi.say("/orchard new pi-a", "Now in")
    plot_a = f"{real_repo}/.pi/worktrees/pi-a"
    check("reports the new worktree", bool(note) and plot_a in note and "branch pi-a" in note, note)
    check("pi's own tools now run inside it", pi.bash("pwd") == plot_a)
    check("branch is checked out", pi.bash("git branch --show-current") == "pi-a")
    table = pi.say("/orchard status", "pi-a") or ""
    check("status, run from inside, lists it as occupied", "occupied" in table and "pi-a" in table, table)

    print("2. new again: the plot left behind is let go")
    check("second worktree", bool(pi.say("/orchard new pi-b", "Now in")))
    status = json.loads(cli("status", "--repo", str(REPO), "--json"))
    rows = {p["name"]: p for p in status["plots"] if p["name"]}
    check("pi-a is no longer held by this process", rows["pi-a"]["session_ended"] is True, rows.get("pi-a"))
    check("pi-b is held", rows["pi-b"]["session_ended"] is False and rows["pi-b"]["agent"] == "pi", rows.get("pi-b"))

    print("3. done: dirty work is backed up and the plot returns to the pool")
    pi.bash("echo scratch > scratch.txt")
    note = pi.say("/orchard done", "Back in")
    check("moves back to the main checkout", bool(note) and real_repo in note and "returned to the pool" in note, note)
    check("tells where the uncommitted work went", bool(note) and "refs/orchard/backup/pi-b-" in note, note)
    check("tools run in the main checkout again", pi.bash("pwd") == real_repo)
    check("not inside a worktree any more", bool(pi.say("/orchard done", "Not inside")))
    pi.stop()

    print("4. the conversation travels with the session")
    source = SESSIONS / "source.jsonl"
    SESSIONS.mkdir(parents=True, exist_ok=True)
    header = {"type": "session", "version": 3, "id": "0f0f0f0f-0000-7000-8000-0000000000aa", "timestamp": "2026-01-01T00:00:00.000Z", "cwd": real_repo}
    message = {"type": "message", "id": "a0b1c2d3", "parentId": None, "timestamp": "2026-01-01T00:00:01.000Z",
               "message": {"role": "user", "content": [{"type": "text", "text": "carry me along"}], "timestamp": 1767225601000}}
    source.write_text(json.dumps(header) + "\n" + json.dumps(message) + "\n")
    pi = Pi(REPO, session=source)
    check("worktree for the resumed session", bool(pi.say("/orchard new pi-c", "Now in")))
    sessions_dir = Path.home() / ".pi/agent/sessions" / ("--" + f"{real_repo}/.pi/worktrees/pi-c".strip("/").replace("/", "-") + "--")
    moved = sorted(sessions_dir.glob("*.jsonl")) if sessions_dir.exists() else []
    check("a session file exists for the plot", bool(moved), str(sessions_dir))
    check("it holds the original message", bool(moved) and "carry me along" in moved[-1].read_text())
    pi.say("/orchard done", "Back in")
    pi.stop()

    print("5. a worktree outside the pool asks before it is removed")
    pi = Pi(OTHER, confirm=False)
    note = pi.say("/orchard new pi-u", "Now in")
    plain = f"{OTHER.resolve()}/.pi/worktrees/pi-u"
    check("created but not pooled", bool(note) and "not pooled" in note, note)
    pi.say("/orchard done", "\0", timeout=6)  # declined: no notification follows, so just wait
    check("done asked for confirmation", pi.dialogs == ["Remove worktree?"], pi.dialogs)
    check("declining keeps the session and the worktree", pi.bash("pwd") == plain and Path(plain).exists())
    pi.stop()
    pi = Pi(plain, confirm=True)
    note = pi.say("/orchard done", "Back in")
    check("confirming removes the worktree", bool(note) and "removed" in note and not Path(plain).exists(), note)
    pi.stop()

    print("6. worktrees_dir keeps worktrees outside the repository")
    outside = f"{(T / 'outside-pi').resolve()}/repo"
    set_worktrees_dir(f"{T}/outside-pi/{{repo}}")
    try:
        pi = Pi(REPO)
        note = pi.say("/orchard new pi-d", "Now in")
        check("created in the configured directory", bool(note) and f"{outside}/pi-d" in note, note)
        check("pi's tools run there", pi.bash("pwd") == f"{outside}/pi-d")
        table = pi.say("/orchard status", "pi-d") or ""
        check("status from there still finds the repository", "occupied" in table and outside in table, table)
        note = pi.say("/orchard done", "Back in")
        check("done returns to the main checkout", bool(note) and real_repo in note and "returned to the pool" in note, note)
        check("the plot is parked under <dir>/.fallow", (Path(outside) / ".fallow").exists() and not Path(f"{outside}/pi-d").exists())
        pi.stop()
    finally:
        set_worktrees_dir(None)

    release_leftovers(real_repo)  # pi-a stays occupied by design: it was left without `done`
    for stale in (Path.home() / ".pi/agent/sessions").glob("--private-tmp-orchard-test-*"):
        shutil.rmtree(stale, ignore_errors=True)
    shutil.rmtree(SESSIONS, ignore_errors=True)
    print("\nall pi checks passed" if failures == 0 else f"\n{failures} pi check(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
