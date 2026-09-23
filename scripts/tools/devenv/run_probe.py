#!/usr/bin/env python3
"""Run devenv_probe.py on one or more machines, bracketed by devenv_snapshot.py.

    run_probe.py [--out DIR] TARGET [TARGET ...]

    TARGET  local            this machine, with the Python running this script
            ssh:<alias>      a host from your ssh config; needs python3 there
            wsl:<distro>     a WSL distribution (Windows only)

Both scripts travel on stdin (`python3 -`), so nothing is copied to a remote host. For
each target the snapshot runs before and after the probe; any shell-init, history or
environment file whose fingerprint changed is reported as CHANGED. Before any target
runs, the fingerprint is shown to detect a change on a scratch file, so an UNCHANGED
verdict means something.

Output: <out>/<label>.json and <label>.stderr.txt. The default is a per-user cache
directory, and an output directory inside a git checkout is refused: the documents
describe a real machine (paths, tool locations, repository names) and must not be
committed.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

sys.dont_write_bytecode = True   # importing a sibling must not leave __pycache__/ in the checkout
HERE = Path(__file__).resolve().parent
PROBE, SNAP = HERE / "devenv_probe.py", HERE / "devenv_snapshot.py"


def default_out() -> Path:
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "devenv-probe"


@dataclass
class Target:
    label: str
    argv: list[str]


def parse_target(spec: str) -> Target:
    if spec == "local":
        return Target("local", [sys.executable, "-"])
    kind, _, name = spec.partition(":")
    if kind == "ssh" and name:
        return Target(name, ["ssh", "-o", "BatchMode=yes", name, "python3", "-"])
    if kind == "wsl" and name:
        return Target(f"wsl-{name}", ["wsl.exe", "-d", name, "--", "python3", "-"])
    raise SystemExit(f"unknown target {spec!r}: use local, ssh:<alias> or wsl:<distro>")


def inside_git_checkout(p: Path) -> Path | None:
    for d in [p, *p.parents]:
        if (d / ".git").exists():
            return d
    return None


def via(target: Target, script: Path, timeout: int = 900) -> tuple[int, str, str]:
    p = subprocess.run(target.argv, input=script.read_bytes(), capture_output=True, timeout=timeout,
                       cwd=tempfile.gettempdir())
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def self_test() -> None:
    sys.path.insert(0, str(HERE))
    from devenv_snapshot import fingerprint
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "rc"
        f.write_text("export A=1\n")
        before = fingerprint(f)
        time.sleep(1.1)
        f.write_text("export A=2\n")
        after = fingerprint(f)
    if before == after:
        raise SystemExit("self-test failed: the snapshot fingerprint did not change when the file did")
    print(f"self-test: fingerprint detects a change ({before.split()[0]} -> {after.split()[0]})")


def verdict(before: str, after: str, rc0: int, rc1: int, err: str) -> str:
    if rc0 != 0 or rc1 != 0:
        return f"SNAPSHOT FAILED: {err[-300:]}"
    b, a = json.loads(before), json.loads(after)
    changed = [k for k in sorted(set(b) | set(a)) if b.get(k) != a.get(k)]
    return "UNCHANGED" if not changed else "CHANGED: " + ", ".join(changed)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("targets", nargs="+", metavar="TARGET")
    ap.add_argument("--out", type=Path, default=default_out())
    args = ap.parse_args()
    out = args.out.expanduser().resolve()
    repo = inside_git_checkout(out)
    if repo:
        raise SystemExit(f"refusing --out {out}: it is inside the git checkout {repo}")
    targets = [parse_target(t) for t in args.targets]

    self_test()
    out.mkdir(parents=True, exist_ok=True)
    for t in targets:
        t0 = time.time()
        rc0, before, err0 = via(t, SNAP)
        rc, probe, err = via(t, PROBE)
        rc1, after, err1 = via(t, SNAP)
        (out / f"{t.label}.json").write_text(probe, encoding="utf-8")
        (out / f"{t.label}.stderr.txt").write_text(err, encoding="utf-8")
        try:
            envs = len(json.loads(probe).get("environments", {}))
            status = f"ok ({len(probe) // 1024} KiB, {envs} environments)"
        except ValueError:
            status = f"PROBE OUTPUT NOT JSON (rc={rc}); stderr tail: {err[-300:]}"
        print(f"{t.label:16} {status} in {time.time() - t0:.0f}s | snapshot: "
              f"{verdict(before, after, rc0, rc1, err0 + err1)}")
    print(f"output: {out}")


if __name__ == "__main__":
    main()
