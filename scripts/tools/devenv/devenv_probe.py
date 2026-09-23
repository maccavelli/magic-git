#!/usr/bin/env python3
"""devenv_probe.py — read-only inventory of a developer's user environment.

One file, standard library only, Python >= 3.9, for Windows, WSL, Linux and macOS.
Prints one JSON document on stdout; the caller saves it.

Read-only by construction (the probe itself writes nothing; a tool asked for its
version may still refresh its own cache — agent CLIs are therefore located, not run; and
devenv_snapshot.py verifies shell init and history files are byte-identical afterwards):
  * writes no files — output goes to stdout only (remote hosts run it from `ssh host python3 -`);
  * every subprocess gets stdin=/dev/null and a timeout;
  * shells are probed the way a terminal starts them, but with history disabled on exit
    (`set +o history; unset HISTFILE`) so no history file is rewritten;
  * Go runs with GOTOOLCHAIN=local, so it can never download a toolchain;
  * Flutter and Dart are never executed (their versions are read from files) — running
    them can self-update or write analytics state;
  * brew runs with HOMEBREW_NO_AUTO_UPDATE=1; git with GIT_OPTIONAL_LOCKS=0 and only
    config/rev-parse reads.
Values of secret-looking variables and token-shaped strings are redacted.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

IS_WIN = os.name == "nt"
HOME = Path.home()
MAX_OUT = 20000
SECRET_NAME = re.compile(r"(KEY|TOKEN|SECRET|PASS(WORD|WD)?|CREDENTIAL|AUTH|COOKIE|SESSION|PRIVATE|BEARER)", re.I)
SECRET_VALUE = re.compile(r"(gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9_-]{16,}|"
                          r"xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|"
                          r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}|://[^/\s:@]+:[^/\s@]+@)")
SAFE_ENV = {"GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1", "GOTOOLCHAIN": "local", "MISE_YES": "0", "NO_COLOR": "1",
            "PAGER": "cat", "GIT_PAGER": "cat"}
MARK_A, MARK_B = "<<<DEVENV_PROBE_ENV", "DEVENV_PROBE_ENV>>>"

TOOLS: dict[str, list[str]] = {
    # Go toolchain and Go tools
    "go": ["version"], "gofmt": [], "gopls": ["version"], "dlv": ["version"],
    "golangci-lint": ["version", "--short"], "staticcheck": ["-version"], "govulncheck": ["-version"],
    "golint": [], "gofumpt": ["-version"], "goimports": [], "treefmt": ["--version"], "revive": ["--version"],
    "gosec": ["-version"], "gotestsum": ["--version"], "mockgen": ["--version"], "air": ["-v"],
    # environment managers and package managers
    "mise": ["--version"], "brew": ["--version"], "scoop": [], "choco": ["--version"], "winget": ["--version"],
    "apt": ["--version"], "pipx": ["--version"], "uv": ["--version"], "npm": ["--version"],
    # languages and runtimes
    "python3": ["--version"], "python": ["--version"], "node": ["--version"], "java": ["-version"],
    "javac": ["-version"], "rustc": ["--version"], "cargo": ["--version"], "rustup": ["--version"],
    "flutter": [], "dart": [],
    # build and CLI tooling
    "git": ["--version"], "gh": ["--version"], "glab": ["--version"], "make": ["--version"],
    "gcc": ["--version"], "clang": ["--version"], "cc": ["--version"], "cmake": ["--version"],
    "ninja": ["--version"], "just": ["--version"], "protoc": ["--version"], "pkg-config": ["--version"],
    "jq": ["--version"], "rg": ["--version"], "fd": ["--version"], "shellcheck": ["--version"],
    "shfmt": ["--version"], "curl": ["--version"], "wget": ["--version"], "ssh": ["-V"], "rsync": ["--version"],
    "tmux": ["-V"], "docker": ["--version"], "kubectl": ["version", "--client"], "oc": ["version", "--client"],
    "helm": ["version", "--short"], "terraform": ["version"], "adb": ["--version"], "sdkmanager": [],
    "mdsh": ["--version"], "mdformat": ["--version"], "actionlint": ["-version"], "zizmor": ["--version"],
    "markdownlint-cli2": ["--version"], "sh": [], "bash": ["--version"], "zsh": ["--version"],
    "pwsh": ["--version"], "starship": ["--version"], "direnv": ["version"],
    # agents and this project's binaries: located only, never executed (agent CLIs write
    # their own state/update-check files on start)
    "claude": [], "codex": [], "grok": [], "opencode": [], "kilo": [], "goose": [], "gemini": [], "agy": [],
    "mcremote": [], "mcrelay": [], "prepare-commit-msg": [],
}


# ---------------------------------------------------------------- helpers

def redact_text(s: str) -> str:
    s = SECRET_VALUE.sub("<redacted>", s)
    return re.sub(r"(?im)^(\s*(?:export\s+|set\s+|\$env:)?)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(.+)$",
                  lambda m: m.group(0) if not SECRET_NAME.search(m.group(2))
                  else f"{m.group(1)}{m.group(2)}{m.group(3)}<redacted>", s)


def redact_env(env: dict[str, str]) -> dict[str, str]:
    return {k: ("<redacted>" if SECRET_NAME.search(k) else SECRET_VALUE.sub("<redacted>", v))
            for k, v in sorted(env.items())}


def run(cmd: list[str], env: dict[str, str] | None = None, cwd: Path | None = None,
        timeout: int = 30, inject: bool = True, raw: bool = False) -> dict[str, object]:
    """inject=False for shell probes, so the captured environment is exactly the shell's.
    raw=True returns stdout alone and unredacted (for JSON the caller parses and redacts)."""
    base = dict(env if env is not None else os.environ)
    if inject:
        base.update(SAFE_ENV)
    try:
        p = subprocess.run(cmd, env=base, cwd=str(cwd or HOME), stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=timeout)
        stdout = p.stdout.decode("utf-8", "replace").strip()
        if raw:
            return {"rc": p.returncode, "out": stdout, "err": p.stderr.decode("utf-8", "replace")[:2000]}
        out = stdout or p.stderr.decode("utf-8", "replace").strip()   # e.g. java -version writes stderr
        return {"rc": p.returncode, "out": redact_text(out)[:MAX_OUT]}
    except FileNotFoundError:
        return {"rc": None, "out": "not found"}
    except subprocess.TimeoutExpired:
        return {"rc": None, "out": f"timeout after {timeout}s"}
    except OSError as e:
        return {"rc": None, "out": f"oserror: {e}"}


def file_info(p: Path, content: bool = True) -> dict[str, object]:
    info: dict[str, object] = {"path": str(p), "exists": p.exists() or p.is_symlink()}
    if not info["exists"]:
        return info
    info["symlink"] = p.is_symlink()
    if p.is_symlink():
        info["link_target"] = os.readlink(p)
    try:
        info["realpath"] = str(p.resolve())
        st = p.stat()
        info["size"], info["mtime"] = st.st_size, int(st.st_mtime)
        if p.is_file():
            data = p.read_bytes()
            info["sha256"] = hashlib.sha256(data).hexdigest()
            if content and len(data) < 200_000:
                text = data.decode("utf-8", "replace")
                info["lines"] = [f"{n}: {l}" for n, l in enumerate(redact_text(text).splitlines(), 1)
                                 if l.strip() and not l.lstrip().startswith(("#", "REM ", "::"))]
    except OSError as e:
        info["error"] = str(e)
    return info


def path_entries(path: str) -> list[dict[str, object]]:
    seen: dict[str, int] = {}
    out = []
    for i, e in enumerate(p for p in path.split(os.pathsep) if p):
        key = os.path.normcase(os.path.normpath(e))
        out.append({"i": i, "dir": e, "exists": os.path.isdir(e), "dup_of": seen.get(key)})
        seen.setdefault(key, i)
    return out


def which_all(name: str, path: str) -> list[str]:
    # Windows only executes PATHEXT extensions; an extensionless file (npm's sh shim) is not runnable there
    exts = os.environ.get("PATHEXT", ".COM;.EXE;.BAT;.CMD").lower().split(";") if IS_WIN else [""]
    hits = []
    for d in (p for p in path.split(os.pathsep) if p):
        for ext in exts:
            c = os.path.join(d, name + ext)
            if os.path.isfile(c) and (IS_WIN or os.access(c, os.X_OK)) and c not in hits:
                hits.append(c)
                break
    return hits


# ---------------------------------------------------------------- environments

def env_via_shell(shell: str, flags: list[str]) -> dict[str, object]:
    """Environment a shell ends up with after its init files, captured by this same Python."""
    py = sys.executable.replace("\\", "/")
    dump = (f"import os,json;print('{MARK_A}'+json.dumps(dict(os.environ))+'{MARK_B}')")
    script = f"set +o history 2>/dev/null; unset HISTFILE; \"{py}\" -c \"{dump}\""
    r = run([shell, *flags, "-c", script], timeout=60, inject=False, raw=True)
    out = str(r["out"])
    if MARK_A in out and MARK_B in out:
        captured = json.loads(out.split(MARK_A, 1)[1].split(MARK_B, 1)[0])
        noise = redact_text(out.split(MARK_A, 1)[0].strip())
        return {"shell": shell, "flags": flags, "env": captured, "stdout_noise": noise[:2000],
                "stderr": redact_text(str(r.get("err", "")))[:2000]}
    return {"shell": shell, "flags": flags, "error": redact_text(out + str(r.get("err", "")))[:3000]}


def unix_login_shell() -> str:
    if platform.system() == "Darwin":
        r = run(["dscl", ".", "-read", str(HOME), "UserShell"])
        m = re.search(r"UserShell:\s*(\S+)", str(r["out"]))
        if m:
            return m.group(1)
    try:
        import pwd
        return pwd.getpwuid(os.getuid()).pw_shell
    except (ImportError, KeyError):
        return os.environ.get("SHELL", "/bin/sh")


def windows_env_blocks() -> dict[str, object]:
    import ctypes
    import winreg
    from ctypes import wintypes

    def reg(hive, sub):
        out = {}
        with winreg.OpenKey(hive, sub) as k:
            i = 0
            while True:
                try:
                    n, v, t = winreg.EnumValue(k, i)
                except OSError:
                    break
                out[n] = {"value": v, "type": {1: "REG_SZ", 2: "REG_EXPAND_SZ"}.get(t, t)}
                i += 1
        return out

    user = reg(winreg.HKEY_CURRENT_USER, "Environment")
    machine = reg(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment")
    for d in (user, machine):
        for k in d:
            if SECRET_NAME.search(k):
                d[k]["value"] = "<redacted>"

    kernel, advapi, userenv = ctypes.windll.kernel32, ctypes.windll.advapi32, ctypes.windll.userenv
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    advapi.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    userenv.CreateEnvironmentBlock.argtypes = [ctypes.POINTER(ctypes.c_void_p), wintypes.HANDLE, wintypes.BOOL]
    userenv.DestroyEnvironmentBlock.argtypes = [ctypes.c_void_p]
    token, block, fresh = wintypes.HANDLE(), ctypes.c_void_p(), {}
    if advapi.OpenProcessToken(kernel.GetCurrentProcess(), 0x000A, ctypes.byref(token)) and \
            userenv.CreateEnvironmentBlock(ctypes.byref(block), token, False):
        ptr = block.value
        while True:
            s = ctypes.wstring_at(ptr)
            if not s:
                break
            k, _, v = s.partition("=")
            if k:
                fresh[k] = v
            ptr += (len(s) + 1) * 2
        userenv.DestroyEnvironmentBlock(block)
    return {"registry_user": user, "registry_machine": machine, "fresh_logon": fresh}


# ---------------------------------------------------------------- sections

def section_shell_init(login_shell: str) -> dict[str, object]:
    if IS_WIN:
        docs = Path(os.path.expandvars(windows_documents()))
        git_root = Path(r"C:\Program Files\Git")
        files = [d / sub for d in dict.fromkeys([docs, HOME / "Documents", HOME / "OneDrive/Documents"])
                 for sub in ("PowerShell/profile.ps1", "PowerShell/Microsoft.PowerShell_profile.ps1",
                             "PowerShell/Microsoft.VSCode_profile.ps1", "WindowsPowerShell/profile.ps1",
                             "WindowsPowerShell/Microsoft.PowerShell_profile.ps1")]
        files += [HOME / ".bashrc", HOME / ".bash_profile", HOME / ".profile", HOME / ".bash_login",
                 git_root / "etc/profile", git_root / "etc/bash.bashrc", git_root / "etc/profile.d/env.sh",
                 HOME / ".config/starship.toml"]
        return {"documents_dir": str(docs), "files": [file_info(f) for f in files]}
    candidates = ["/etc/profile", "/etc/bash.bashrc", "/etc/bashrc", "/etc/environment", "/etc/paths",
                  "/etc/wsl.conf", "/etc/zprofile", "/etc/zshrc"]
    candidates += sorted(str(p) for p in Path("/etc/paths.d").glob("*")) if Path("/etc/paths.d").is_dir() else []
    candidates += sorted(str(p) for p in Path("/etc/profile.d").glob("*")) if Path("/etc/profile.d").is_dir() else []
    home_files = [".bash_profile", ".bash_login", ".profile", ".bashrc", ".bash_aliases", ".bash_logout",
                  ".inputrc", ".zshrc", ".zprofile", ".zshenv", ".config/devenv.sh", ".config/starship.toml",
                  ".config/mise/config.toml", ".tool-versions", ".envrc"]
    paths = [Path(c) for c in candidates] + [HOME / h for h in home_files]
    paths += sorted((HOME / ".bashrc.d").glob("*")) if (HOME / ".bashrc.d").is_dir() else []
    seen, infos, queue = set(), [], list(paths)
    while queue:
        p = queue.pop(0)
        key = str(p)
        if key in seen:
            continue
        seen.add(key)
        info = file_info(p)
        infos.append(info)
        for line in info.get("lines", []) or []:   # follow `source X` / `. X` one file at a time
            m = re.search(r"(?:^|[;&|]\s*|\s)(?:source|\.)\s+[\"']?([~$A-Za-z0-9_./{}-]+)", str(line).split(": ", 1)[1])
            if m:
                target = os.path.expandvars(m.group(1).replace("~", str(HOME), 1).replace("${HOME}", str(HOME)))
                if "$" not in target and target.startswith("/") and len(seen) < 120:
                    queue.append(Path(target))
    return {"login_shell": login_shell, "files": infos}


def windows_documents() -> str:
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders") as k:
            return winreg.QueryValueEx(k, "Personal")[0]
    except OSError:
        return str(HOME / "Documents")


def section_environments(login_shell: str) -> tuple[dict[str, object], str, dict[str, str]]:
    envs: dict[str, object] = {"probe_process": {"env": dict(os.environ)}}
    if IS_WIN:
        blocks = windows_env_blocks()
        envs.update({k: v for k, v in blocks.items() if k.startswith("registry")})
        envs["fresh_logon"] = {"env": blocks["fresh_logon"]}
        gitbash = r"C:\Program Files\Git\bin\bash.exe"
        if os.path.isfile(gitbash):
            envs["gitbash_login_interactive"] = env_via_shell(gitbash, ["-l", "-i"])
        primary = "fresh_logon"
    else:
        envs["login_interactive"] = env_via_shell(login_shell, ["-l", "-i"])
        envs["login_noninteractive"] = env_via_shell(login_shell, ["-l"])
        envs["interactive_nonlogin"] = env_via_shell(login_shell, ["-i"])
        primary = "login_interactive" if "env" in envs["login_interactive"] else "probe_process"  # type: ignore
    primary_env = dict(envs[primary]["env"])  # type: ignore[index]
    for name, e in envs.items():
        if isinstance(e, dict) and "env" in e:
            p = e["env"].get("Path") or e["env"].get("PATH") or ""
            e["path_entries"] = path_entries(p)
            e["env"] = redact_env(e["env"])
    return envs, primary, primary_env


def section_tools(env: dict[str, str]) -> dict[str, object]:
    path = env.get("Path") or env.get("PATH") or ""
    out = {}
    for name, args in TOOLS.items():
        hits = which_all(name, path)
        entry: dict[str, object] = {"all": hits}
        if hits:
            entry["realpath"] = str(Path(hits[0]).resolve())
            if args and name not in ("flutter", "dart"):
                exe = hits[0]
                cmd = ["cmd", "/c", exe, *args] if IS_WIN and exe.lower().endswith((".cmd", ".bat")) else [exe, *args]
                r = run(cmd, env=env, timeout=25)
                entry["version"] = str(r["out"]).splitlines()[0][:200] if r["out"] else ""
                entry["rc"] = r["rc"]
        out[name] = entry
    return out


def go_binary_info(go: str, exe: Path, env: dict[str, str]) -> dict[str, object]:
    r = run([go, "version", "-m", str(exe)], env=env)
    lines = str(r["out"]).splitlines()
    if r["rc"] != 0 or not lines:
        return {"file": exe.name, "go": None}
    return {"file": exe.name, "go": lines[0].rsplit(": ", 1)[-1].strip(),
            "path": next((l.split("\t")[2] for l in lines if l.startswith("\tpath\t")), ""),
            "mod": next((l.split("\t")[2] + "@" + l.split("\t")[3] for l in lines if l.startswith("\tmod\t")), "")}


def section_go(env: dict[str, str]) -> dict[str, object]:
    path = env.get("Path") or env.get("PATH") or ""
    gos = which_all("go", path)
    out: dict[str, object] = {"on_path": gos, "GOTOOLCHAIN_in_env": env.get("GOTOOLCHAIN"),
                              "GOROOT_in_env": env.get("GOROOT"), "GOBIN_in_env": env.get("GOBIN")}
    if not gos:
        return out
    go = gos[0]
    r = run([go, "env", "-json"], env=env, raw=True)
    try:
        goenv = json.loads(str(r["out"]))
    except ValueError:
        goenv = {"error": str(r["out"])[:500]}
    out["go_env_local"] = redact_env({k: str(v) for k, v in goenv.items()})
    out["go_version_local"] = run([go, "version"], env=env)["out"]
    if goenv.get("GOENV"):
        out["goenv_file"] = file_info(Path(goenv["GOENV"]))
    installs = []
    pats = [HOME / "sdk", HOME / ".local", HOME / ".local/share/mise/installs/go", HOME / "go",
            Path("/usr/local"), Path("/usr/lib"), Path("/opt/homebrew/Cellar/go"), Path(r"C:\Program Files")]
    for base in pats:
        if base.is_dir():
            for d in base.iterdir():
                if (d / "VERSION").is_file() and (d / "bin").is_dir() and d.name.lower().startswith(("go", "1", "latest")):
                    installs.append({"dir": str(d), "symlink": d.is_symlink(),
                                     "version": (d / "VERSION").read_text(errors="replace").splitlines()[0]})
    out["installs"] = installs
    modcache = goenv.get("GOMODCACHE")
    if modcache and (Path(modcache) / "golang.org").is_dir():
        out["modcache_toolchains"] = sorted(p.name for p in (Path(modcache) / "golang.org").glob("toolchain@*"))
    bins = {}
    for d in {str(HOME / "go" / "bin"), goenv.get("GOBIN") or "", str(Path(goenv.get("GOPATH", "")) / "bin")}:
        if d and Path(d).is_dir():
            bins[d] = [go_binary_info(go, f, env) for f in sorted(Path(d).iterdir()) if f.is_file()]
    out["bin_dirs"] = bins
    return out


def section_mise(env: dict[str, str]) -> dict[str, object]:
    path = env.get("Path") or env.get("PATH") or ""
    hits = which_all("mise", path)
    if not hits:
        return {"present": False}
    m = hits[0]
    out: dict[str, object] = {"present": True, "exe": m, "version": run([m, "--version"], env=env)["out"],
                              "config_files": run([m, "config", "ls"], env=env)["out"],
                              "settings": run([m, "settings", "ls"], env=env)["out"],
                              "global_config": file_info(HOME / ".config/mise/config.toml")}
    r = run([m, "ls", "--json"], env=env, timeout=60, raw=True)
    try:
        out["ls"] = json.loads(str(r["out"]))
    except ValueError:
        out["ls"] = str(r["out"])[:4000]
    shims = HOME / ".local/share/mise/shims"
    out["shims"] = sorted(p.name for p in shims.iterdir()) if shims.is_dir() else []
    return out


def section_packages(env: dict[str, str]) -> dict[str, object]:
    path = env.get("Path") or env.get("PATH") or ""
    out: dict[str, object] = {}
    def have(n): return bool(which_all(n, path))
    if have("brew"):
        out["brew_prefix"] = run(["brew", "--prefix"], env=env)["out"]
        out["brew_formulae"] = run(["brew", "list", "--versions", "--formula"], env=env, timeout=60)["out"]
        out["brew_casks"] = run(["brew", "list", "--versions", "--cask"], env=env, timeout=60)["out"]
        out["brew_taps"] = run(["brew", "tap"], env=env)["out"]
    if have("dpkg-query"):
        r = run(["dpkg-query", "-W", "-f", "${Package}\t${Version}\n"], env=env, timeout=60)
        pk = re.compile(r"^(build-essential|gcc|g\+\+|clang|llvm|cmake|ninja-build|pkg-config|libgtk-3-dev|"
                        r"python3|python3-(pip|venv)|git|make|curl|wget|jq|ripgrep|fd-find|shellcheck|shfmt|"
                        r"openjdk-\S+|golang\S*|unzip|zip|xz-utils|tmux|rsync|docker\S*|podman|sqlite3|"
                        r"libsqlite3-dev|lld|gdb|strace|zsh|bash)\t")
        lines = str(r["out"]).splitlines()
        out["dpkg_count"] = len(lines)
        out["dpkg_dev_subset"] = [l for l in lines if pk.match(l + ("" if "\t" in l else "\t"))]
    if have("pipx"):
        out["pipx"] = run(["pipx", "list", "--short"], env=env)["out"]
    if have("uv"):
        out["uv_tools"] = run(["uv", "tool", "list"], env=env)["out"]
    if have("npm"):
        npm = which_all("npm", path)[0]
        cmd = ["cmd", "/c", npm] if IS_WIN else [npm]
        out["npm_global"] = run([*cmd, "ls", "-g", "--depth=0"], env=env, timeout=60)["out"]
    if have("cargo"):
        out["cargo_installs"] = run(["cargo", "install", "--list"], env=env)["out"]
    if IS_WIN:
        if have("scoop"):
            out["scoop"] = run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", "scoop list"], env=env,
                               timeout=90)["out"]
        if have("choco"):
            out["choco"] = run(["choco", "list", "--limit-output"], env=env, timeout=90)["out"]
    return out


def section_runtimes(env: dict[str, str]) -> dict[str, object]:
    path = env.get("Path") or env.get("PATH") or ""
    out: dict[str, object] = {"JAVA_HOME": env.get("JAVA_HOME"), "ANDROID_HOME": env.get("ANDROID_HOME"),
                              "ANDROID_SDK_ROOT": env.get("ANDROID_SDK_ROOT")}
    jdks = []
    for base in [HOME / "sdk", Path("/Library/Java/JavaVirtualMachines"), Path("/usr/lib/jvm"),
                 HOME / ".local/share/mise/installs/java", Path(r"C:\Program Files\Eclipse Adoptium"),
                 Path(r"C:\Program Files\Java"), Path(r"C:\Program Files\Microsoft")]:
        if base.is_dir():
            for d in base.iterdir():
                rel = d / "release"
                if not rel.is_file():
                    rel = d / "Contents/Home/release"
                if rel.is_file():
                    m = re.search(r'JAVA_VERSION="([^"]+)"', rel.read_text(errors="replace"))
                    jdks.append({"dir": str(d), "version": m.group(1) if m else "?"})
    for p in Path("/opt/homebrew/opt").glob("openjdk*") if Path("/opt/homebrew/opt").is_dir() else []:
        rel = p / "libexec/openjdk.jdk/Contents/Home/release"
        if rel.is_file():
            m = re.search(r'JAVA_VERSION="([^"]+)"', rel.read_text(errors="replace"))
            jdks.append({"dir": str(p), "version": m.group(1) if m else "?"})
    out["jdks"] = jdks
    fl = which_all("flutter", path)
    if fl:
        real = Path(fl[0]).resolve()
        if real.name.startswith("mise"):   # a mise shim resolves to mise itself: ask mise
            where = str(run([str(real), "which", "flutter"], env=env)["out"]).strip()
            real = Path(where).resolve() if where.startswith("/") else real
        root = real.parent.parent
        fv = root / "bin/cache/flutter.version.json"
        out["flutter"] = {"root": str(root),
                          "version": json.loads(fv.read_text()).get("frameworkVersion") if fv.is_file() else
                          (root / "version").read_text().strip() if (root / "version").is_file() else "?",
                          "dart": (root / "bin/cache/dart-sdk/version").read_text().strip()
                          if (root / "bin/cache/dart-sdk/version").is_file() else "?"}
    # The file Flutter itself reads: %APPDATA%\.flutter_settings on Windows; elsewhere
    # $XDG_CONFIG_HOME/flutter/settings (default ~/.config) when present, else the legacy
    # ~/.flutter_settings. Any other settings file is reported as stale — on one host a
    # leftover ~/.flutter_settings named a different JDK than the one Flutter used.
    appdata = Path(os.environ.get("APPDATA") or HOME / "AppData/Roaming")
    if IS_WIN:
        effective = appdata / ".flutter_settings"
    else:
        xdg = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config") / "flutter/settings"
        effective = xdg if xdg.is_file() else HOME / ".flutter_settings"
    candidates = {effective, HOME / ".flutter_settings", HOME / ".config/flutter/settings",
                  appdata / ".flutter_settings"}
    if effective.is_file():
        out["flutter_settings"] = {"path": str(effective), "content": redact_text(effective.read_text())}
    out["flutter_settings_stale"] = [{"path": str(p), "content": redact_text(p.read_text())}
                                     for p in sorted(candidates) if p != effective and p.is_file()]
    roots = {r for r in (env.get("ANDROID_HOME"), env.get("ANDROID_SDK_ROOT"), str(HOME / "sdk/android-sdk"),
                         str(HOME / "Library/Android/sdk"), str(HOME / "Android/Sdk"),
                         str(HOME / ".local/share/android-sdk"), "/opt/homebrew/share/android-commandlinetools",
                         str(HOME / "AppData/Local/Android/Sdk")) if r and Path(r).is_dir()}
    android = {}
    for r in sorted(roots):
        pkgs = {}
        props = [sp for pat in ("*/source.properties", "*/*/source.properties", "*/*/*/source.properties")
                 for sp in Path(r).glob(pat)]   # bounded depth: never walk the NDK tree
        for sp in props:
            m = re.search(r"Pkg\.Revision=(\S+)", sp.read_text(errors="replace"))
            pkgs[str(sp.parent.relative_to(r)).replace("\\", "/")] = m.group(1) if m else "?"
        lic = Path(r) / "licenses"
        android[r] = {"packages": dict(sorted(pkgs.items())),
                      "licenses": sorted(p.name for p in lic.iterdir()) if lic.is_dir() else []}
    out["android_sdks"] = android
    if platform.system() == "Darwin":
        out["java_home_V"] = run(["/usr/libexec/java_home", "-V"])["out"]
    return out


def section_git(env: dict[str, str]) -> dict[str, object]:
    out: dict[str, object] = {"global_config": run(["git", "config", "--global", "--list", "--show-origin"],
                                                   env=env)["out"]}
    hooks = HOME / ".global-git-hooks"
    out["global_git_hooks"] = sorted(p.name for p in hooks.iterdir()) if hooks.is_dir() else None
    agent_hooks = HOME / ".global-agent-hooks"
    out["global_agent_hooks"] = sorted(p.name for p in agent_hooks.iterdir()) if agent_hooks.is_dir() else None
    repos = []
    for base in (HOME / "gitrepos", HOME / "src", HOME / "code"):
        if base.is_dir():
            for d in sorted(base.iterdir()):
                if (d / ".git").exists():
                    repos.append({"dir": str(d),
                                  "origin": str(run(["git", "-C", str(d), "config", "--get", "remote.origin.url"],
                                                    env=env)["out"]),
                                  "branch": str(run(["git", "-C", str(d), "rev-parse", "--abbrev-ref", "HEAD"],
                                                    env=env)["out"])})
    out["repos"] = repos
    return out


def section_agents() -> dict[str, object]:
    files = [".claude/CLAUDE.md", ".claude/settings.json", ".codex/AGENTS.md", ".codex/config.toml",
             ".config/opencode/AGENTS.md", ".config/kilo/AGENTS.md", ".gemini/AGENTS.md", ".gemini/GEMINI.md",
             ".grok/AGENTS.md", ".config/goose/config.yaml"]
    out = {f: {k: v for k, v in file_info(HOME / f, content=False).items() if k != "lines"} for f in files}
    skills = HOME / ".claude/skills"
    out["claude_skills"] = sorted(p.name for p in skills.iterdir()) if skills.is_dir() else []  # type: ignore
    return out


def main() -> None:
    login_shell = "powershell" if IS_WIN else unix_login_shell()
    envs, primary, penv = section_environments(login_shell)
    doc = {
        "probe_version": 1,
        "host": {"node": platform.node(), "system": platform.system(), "release": platform.release(),
                 "machine": platform.machine(), "python": sys.version.split()[0], "python_exe": sys.executable,
                 "user": os.environ.get("USER") or os.environ.get("USERNAME"), "home": str(HOME),
                 "wsl": "microsoft" in platform.release().lower(), "login_shell": login_shell},
        "primary_env": primary,
        "environments": envs,
        "shell_init": section_shell_init(login_shell),
        "tools": section_tools(penv),
        "go": section_go(penv),
        "mise": section_mise(penv),
        "runtimes": section_runtimes(penv),
        "packages": section_packages(penv),
        "git": section_git(penv),
        "agents": section_agents(),
    }
    sys.stdout.write(json.dumps(doc, indent=1, default=str))


if __name__ == "__main__":
    main()
