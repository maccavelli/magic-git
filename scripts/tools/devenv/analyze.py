#!/usr/bin/env python3
"""Compare devenv_probe.py outputs side by side.

    analyze.py [--out DIR] [--reference LABEL]

Reads every <label>.json in DIR (run_probe.py's output directory) and writes
DIR/report.txt, with the reference machine as the first column. Sections:

   1  PATH a new terminal gets, with missing and duplicate entries
   2  PATH-shaping lines in each machine's shell init (file:line)
   3  tools: resolved version, and every shadowed copy later on PATH
   4  Go: settings, installs, cached toolchains, installed Go tools
   5  mise
   6  runtimes: JDKs, Flutter and its settings, Android SDK packages
   7  package managers
   8  git global config and global hooks
   9  agent configuration files
  10  repositories
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True   # importing run_probe must not leave __pycache__/ in the checkout
from run_probe import default_out  # noqa: E402

PATHY = re.compile(r"PATH|path_helper|mise|devenv|GOROOT|GOPATH|GOBIN|GOTOOLCHAIN|JAVA_HOME|ANDROID|flutter|"
                   r"brew shellenv|cargo/env|starship|source|\. ", re.I)
GO_KEYS = ["GOVERSION", "GOROOT", "GOPATH", "GOBIN", "GOMODCACHE", "GOCACHE", "GOENV", "GOTOOLCHAIN", "GOPROXY",
           "GOSUMDB", "GOPRIVATE", "GONOSUMDB", "GOFLAGS", "CGO_ENABLED", "GOTMPDIR", "GOEXPERIMENT", "GOAMD64",
           "GOARM64", "GOTELEMETRY", "GODEBUG", "GOWORK", "GOINSECURE", "GONOPROXY"]


class Report:
    def __init__(self, hosts: list[str]) -> None:
        self.hosts = hosts
        self.lines: list[str] = []

    def h(self, title: str) -> None:
        self.lines += ["", "=" * 100, title, "=" * 100]

    def p(self, *parts: object) -> None:
        self.lines.append(" ".join(str(x) for x in parts))

    def table(self, rows: list[list[str]], first: int, col: int = 32, extra: int = 0) -> None:
        widths = [first] + [col] * len(self.hosts) + ([extra] if extra else [])
        for r in rows:
            self.lines.append("".join(str(c)[:w - 1].ljust(w) for c, w in zip(r, widths)))


def primary(d: dict) -> dict:
    return d["environments"][d["primary_env"]]


def s1_path(r: Report, docs: dict) -> None:
    r.h("1. PATH in each machine's primary environment (what a new terminal gets)")
    for h, d in docs.items():
        e = primary(d)
        r.p(f"\n-- {h} ({d['primary_env']}): {len(e['path_entries'])} entries")
        for x in e["path_entries"]:
            flag = ("" if x["exists"] else "  <-- MISSING") + \
                (f"  <-- dup of #{x['dup_of']}" if x["dup_of"] is not None else "")
            r.p(f"   {x['i']:2} {x['dir']}{flag}")
        if d["host"]["system"] == "Windows":
            continue
        base = [x["dir"] for x in e["path_entries"]]
        for name in ("login_noninteractive", "interactive_nonlogin", "probe_process"):
            other = d["environments"].get(name, {})
            if "path_entries" in other:
                have = {x["dir"] for x in other["path_entries"]}
                r.p(f"   vs {name}: {len(have)} entries; absent there: {[x for x in base if x not in have][:12]}")


def s2_init(r: Report, docs: dict) -> None:
    r.h("2. PATH-shaping lines in shell init files (file:line)")
    for h, d in docs.items():
        r.p(f"\n-- {h}")
        for f in d["shell_init"]["files"]:
            if not f.get("exists"):
                continue
            hits = [l for l in f.get("lines", []) if PATHY.search(l)]
            if hits or f.get("symlink"):
                r.p(f"   {f['path']}" + (f" -> {f['link_target']}" if f.get("symlink") else ""))
                for l in hits[:40]:
                    r.p(f"       {l[:170]}")


def s3_tools(r: Report, docs: dict) -> None:
    r.h("3. Tools: version (first line); '+N' = N more copies later on PATH")
    names = list(next(iter(docs.values()))["tools"])
    rows = [["tool", *docs]]
    for n in names:
        row = [n]
        for h in docs:
            t = docs[h]["tools"].get(n, {})
            if not t.get("all"):
                row.append("—")
                continue
            v = re.sub(r"^(\S+ )?(version )?", "", (t.get("version") or "").replace("\t", " "))[:28]
            row.append(f"{v or 'present'}" + (f" +{len(t['all']) - 1}" if len(t["all"]) > 1 else ""))
        rows.append(row)
    r.table(rows, 20, 34)
    r.p("\n-- shadowed copies (every match on PATH, in order)")
    for n in names:
        for h in docs:
            t = docs[h]["tools"].get(n, {})
            if len(t.get("all", [])) > 1:
                r.p(f"   {n:16} {h:16} {t['all']}")


def s4_go(r: Report, docs: dict) -> None:
    r.h("4. Go")
    rows = [["go env (GOTOOLCHAIN=local)", *docs]]
    rows += [[k, *[docs[h]["go"].get("go_env_local", {}).get(k, "—") for h in docs]] for k in GO_KEYS]
    rows.append(["GOTOOLCHAIN in shell env", *[str(docs[h]["go"].get("GOTOOLCHAIN_in_env")) for h in docs]])
    rows.append(["GOBIN in shell env", *[str(docs[h]["go"].get("GOBIN_in_env")) for h in docs]])
    r.table(rows, 26, 38)
    for h, d in docs.items():
        g = d["go"]
        r.p(f"\n-- {h}: go on PATH: {g.get('on_path')}")
        r.p(f"   installs: {[(i['dir'], i['version'], 'symlink' if i['symlink'] else '') for i in g.get('installs', [])]}")
        r.p(f"   cached toolchains: {g.get('modcache_toolchains')}")
        r.p(f"   GOENV file {g.get('goenv_file', {}).get('path')}: {g.get('goenv_file', {}).get('lines')}")
    r.p("\n-- Go tools installed: version [go1.26.x patch that built it]; '·' = absent")
    tools: dict[str, dict[str, str]] = {}
    for h, d in docs.items():
        for bindir, items in d["go"].get("bin_dirs", {}).items():
            for t in items:
                if not t.get("go"):
                    continue
                name = re.sub(r"\.exe$", "", t["file"])
                mod = t.get("mod", "").split("@")
                built = re.sub(r"^go\d+\.\d+\.", "", t["go"])
                where = "" if re.search(r"[/\\]go[/\\]bin$", bindir.rstrip("/\\")) else f" ({bindir})"
                tools.setdefault(name, {})[h] = f"{(mod[1] if len(mod) > 1 else '?')[:22]} [{built}]{where}"
                tools[name].setdefault("_pkg", t.get("path", ""))
    rows = [["tool", *docs, "package"]]
    rows += [[n, *[tools[n].get(h, "·") for h in docs], tools[n].get("_pkg", "")] for n in sorted(tools)]
    r.table(rows, 18, 30, 60)


def s5_mise(r: Report, docs: dict) -> None:
    r.h("5. mise")
    for h, d in docs.items():
        m = d["mise"]
        r.p(f"\n-- {h}: present={m.get('present')} {m.get('exe', '')} {m.get('version', '')}")
        if not m.get("present"):
            continue
        r.p(f"   config files: {m.get('config_files')}")
        r.p(f"   global config lines: {m.get('global_config', {}).get('lines')}")
        r.p("   settings: " + " | ".join(str(m.get("settings", "")).splitlines()[:30]))
        if isinstance(m.get("ls"), dict):
            r.p("   installed: " + ", ".join(f"{k}=" + "/".join(sorted({str(v.get('version')) for v in vs}))
                                            for k, vs in sorted(m["ls"].items())))


def s6_runtimes(r: Report, docs: dict) -> None:
    r.h("6. Runtimes")
    for h, d in docs.items():
        rt = d["runtimes"]
        r.p(f"\n-- {h}: JAVA_HOME={rt.get('JAVA_HOME')} ANDROID_HOME={rt.get('ANDROID_HOME')}")
        r.p(f"   JDKs: {[(j['dir'], j['version']) for j in rt.get('jdks', [])]}")
        r.p(f"   flutter: {rt.get('flutter')}")
        fs = rt.get("flutter_settings")
        r.p(f"   flutter settings: {fs['path'] + ': ' + ' '.join(fs['content'].split()) if fs else None}")
        for stale in rt.get("flutter_settings_stale", []):
            r.p(f"   STALE settings file (Flutter does not read it): {stale['path']}: "
                f"{' '.join(stale['content'].split())}")
        if rt.get("java_home_V"):
            r.p(f"   java_home -V: {' | '.join(str(rt['java_home_V']).splitlines())}")
    r.p("\n-- Android SDK packages (Pkg.Revision)")
    pk: dict[str, dict[str, str]] = {}
    for h, d in docs.items():
        for info in d["runtimes"].get("android_sdks", {}).values():
            for name, rev in info["packages"].items():
                pk.setdefault(name, {})[h] = rev
    r.table([["package", *docs]] + [[n, *[pk[n].get(h, "·") for h in docs]] for n in sorted(pk)], 40, 24)


def s7_packages(r: Report, docs: dict) -> None:
    r.h("7. Package managers")
    for h, d in docs.items():
        r.p(f"\n-- {h}: {sorted(d['packages'])}")
        for k, v in d["packages"].items():
            r.p(f"   [{k}]")
            for l in str(v if isinstance(v, str) else json.dumps(v)).splitlines()[:80]:
                r.p(f"      {l[:150]}")


def s8_git(r: Report, docs: dict) -> None:
    r.h("8. git global config (origin file shown) and global hooks")
    for h, d in docs.items():
        g = d["git"]
        r.p(f"\n-- {h}: global_git_hooks={g.get('global_git_hooks')} global_agent_hooks={g.get('global_agent_hooks')}")
        for l in str(g.get("global_config", "")).splitlines():
            r.p(f"   {l[:160]}")


def s9_agents(r: Report, docs: dict) -> None:
    r.h("9. Agent configuration files: symlink target / sha256[:12]")
    names = [k for k in next(iter(docs.values()))["agents"] if k != "claude_skills"]
    rows = [["file", *docs]]
    for n in names:
        row = [n]
        for h in docs:
            a = docs[h]["agents"].get(n, {})
            row.append("·" if not a.get("exists") else
                       ("->" + str(a.get("link_target"))[-22:] + " " if a.get("symlink") else "")
                       + str(a.get("sha256", ""))[:12])
        rows.append(row)
    r.table(rows, 30, 36)
    for h, d in docs.items():
        r.p(f"   claude skills {h}: {d['agents'].get('claude_skills')}")


def s10_repos(r: Report, docs: dict) -> None:
    r.h("10. Repositories (branch)")
    names = sorted({Path(x["dir"]).name for d in docs.values() for x in d["git"]["repos"]})
    rows = [["repo", *docs]]
    for n in names:
        rows.append([n, *[next((x["branch"] for x in docs[h]["git"]["repos"] if Path(x["dir"]).name == n), "·")
                          for h in docs]])
    r.table(rows, 34, 26)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=default_out())
    ap.add_argument("--reference", help="label shown first (default: the first alphabetically)")
    args = ap.parse_args()
    files = sorted(args.out.glob("*.json"))
    if not files:
        raise SystemExit(f"no probe outputs in {args.out}; run run_probe.py first")
    labels = [f.stem for f in files]
    if args.reference:
        if args.reference not in labels:
            raise SystemExit(f"--reference {args.reference!r} not among {labels}")
        labels.remove(args.reference)
        labels.insert(0, args.reference)
    docs = {h: json.loads((args.out / f"{h}.json").read_text(encoding="utf-8")) for h in labels}
    r = Report(labels)
    for section in (s1_path, s2_init, s3_tools, s4_go, s5_mise, s6_runtimes, s7_packages, s8_git, s9_agents,
                    s10_repos):
        section(r, docs)
    report = args.out / "report.txt"
    report.write_text("\n".join(r.lines), encoding="utf-8")
    print(f"{report}: {len(r.lines)} lines, {len(labels)} machines ({', '.join(labels)})")


if __name__ == "__main__":
    main()
