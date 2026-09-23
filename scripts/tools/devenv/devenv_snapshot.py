#!/usr/bin/env python3
"""devenv_snapshot.py — read-only fingerprint of every shell-init, history and env file
the probe could conceivably disturb (plus, on Windows, the registry environment).
Run before and after devenv_probe.py; the two outputs must be identical.
Python >= 3.9, stdlib only, stdout only."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

HOME = Path.home()
IS_WIN = os.name == "nt"
UNIX = [".bash_profile", ".bash_login", ".profile", ".bashrc", ".bash_aliases", ".bash_logout", ".bash_history",
        ".zshrc", ".zprofile", ".zshenv", ".zsh_history", ".inputrc", ".config/devenv.sh",
        ".config/mise/config.toml", ".config/go/env", "Library/Application Support/go/env",
        ".config/starship.toml", ".gitconfig"]
ETC = ["/etc/profile", "/etc/bash.bashrc", "/etc/bashrc", "/etc/paths", "/etc/environment", "/etc/wsl.conf"]


def fingerprint(p: Path) -> str:
    try:
        st = p.stat()
        return f"{hashlib.sha256(p.read_bytes()).hexdigest()[:16]} size={st.st_size} mtime={int(st.st_mtime)}"
    except FileNotFoundError:
        return "absent"
    except OSError as e:
        return f"error {e}"


def windows_extra() -> dict[str, str]:
    import winreg
    out = {}
    for name, hive, sub in (("HKCU\\Environment", winreg.HKEY_CURRENT_USER, "Environment"),
                            ("HKLM\\Environment", winreg.HKEY_LOCAL_MACHINE,
                             r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment")):
        vals, i = [], 0
        with winreg.OpenKey(hive, sub) as k:
            while True:
                try:
                    vals.append(repr(winreg.EnumValue(k, i)))
                except OSError:
                    break
                i += 1
        out[name] = hashlib.sha256("\n".join(sorted(vals)).encode()).hexdigest()[:16] + f" values={len(vals)}"
    appdata = Path(os.environ["APPDATA"])
    docs = [HOME / "Documents", HOME / "OneDrive/Documents"]
    files = [appdata / "go/env", appdata / "Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt"]
    files += [d / sub for d in docs for sub in ("PowerShell/profile.ps1", "PowerShell/Microsoft.PowerShell_profile.ps1",
                                                "WindowsPowerShell/Microsoft.PowerShell_profile.ps1")]
    out.update({str(f): fingerprint(f) for f in files})
    return out


def main() -> None:
    snap = {str(HOME / f): fingerprint(HOME / f) for f in UNIX}
    if not IS_WIN:
        snap.update({f: fingerprint(Path(f)) for f in ETC})
        for d in (Path("/etc/profile.d"), Path("/etc/paths.d"), HOME / ".bashrc.d"):
            if d.is_dir():
                snap.update({str(p): fingerprint(p) for p in sorted(d.iterdir())})
    else:
        snap.update(windows_extra())
    print(json.dumps(snap, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
