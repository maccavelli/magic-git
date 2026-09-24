#!/usr/bin/env python3
"""Check that this Python can run the repository's Python tooling.

Magic Git's development tooling is Python: the mutation harness
(scripts/tools/mutate.py), the developer-environment probe
(scripts/tools/devenv/), and the agent hooks under .agents/. All of it uses
the standard library only, so there is nothing to install. What can still go
wrong is the interpreter: too old, a minimal build missing a stdlib module,
or a different `python3` on PATH than the one you tested with. This script
checks each of those and exits non-zero if the tooling would not run.

    python3 dependencies.py              # check this checkout
    python3 dependencies.py --verbose    # also list every module each file needs
    python3 dependencies.py --root DIR   # check another checkout (e.g. a scratch clone)

What it checks:

* This interpreter, and the `python3` the scripts' shebangs find on PATH, are
  at least MIN_PYTHON.
* Every .py file in the repository compiles under this interpreter.
* Every module those files import resolves here. The list is read from the
  files themselves, so it cannot fall behind a new script. Modules that exist
  only on another platform (winreg on Windows, pwd on POSIX) are skipped, and
  an import guarded by `except ImportError` is reported as optional.
* The optional extras below, which are reported but never required.
* .gitignore keeps Python's caches and virtualenvs out of commits.

The version check runs before anything else, and this file sticks to syntax
any Python 3 can parse, so an old interpreter gets a clear message rather than
a SyntaxError.
"""

from __future__ import annotations

import argparse
import ast
import importlib.util
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

MIN_PYTHON = (3, 12)

# Trees that are not the repository's own Python: vendored SDKs, build output,
# generated plugin packages, interpreter environments.
SKIP_DIRS = frozenset({
    ".git", ".flutter-sdk", ".dart_tool", "build", "ephemeral",
    ".venv", ".venv-icons", "node_modules", "__pycache__",
})

# Stdlib modules that exist on one platform only; the scripts that import them
# choose the platform at run time.
PLATFORM_ONLY = {
    "winreg": "win32", "msvcrt": "win32", "_winapi": "win32", "winsound": "win32",
    "pwd": "posix", "grp": "posix", "fcntl": "posix", "termios": "posix",
    "resource": "posix", "tty": "posix", "pty": "posix",
}

# Every rule a Python run could need, from the global agent rules.
GITIGNORE_RULES = (
    "__pycache__/", "*.py[cod]", ".pytest_cache/", ".mypy_cache/",
    ".ruff_cache/", ".venv/",
)

GUARD_EXCEPTIONS = frozenset({"ImportError", "ModuleNotFoundError"})


@dataclass(frozen=True)
class Extra:
    """A package no required tool needs, but one workflow can use."""

    module: str
    package: str
    used_by: str


EXTRAS = (
    Extra("PIL", "pillow",
          "scripts/generate_app_icons.sh, only where `sips` is missing (not macOS)"),
)


@dataclass
class Report:
    failures: list[str] = field(default_factory=list)

    def ok(self, message: str) -> None:
        print(f"  ok    {message}")

    def info(self, message: str) -> None:
        print(f"  info  {message}")

    def fail(self, message: str) -> None:
        print(f"  FAIL  {message}")
        self.failures.append(message)


@dataclass
class Imports:
    required: set[str] = field(default_factory=set)
    optional: set[str] = field(default_factory=set)


def version_text(version: tuple[int, ...]) -> str:
    return ".".join(str(part) for part in version)


def check_interpreter(report: Report) -> bool:
    here = tuple(sys.version_info[:3])
    label = f"Python {version_text(here)} ({sys.executable})"
    if here[:2] >= MIN_PYTHON:
        report.ok(f"{label} >= {version_text(MIN_PYTHON)}")
        return True
    report.fail(f"{label} is older than {version_text(MIN_PYTHON)}; "
                "run ./devenv.sh, or `brew install python3`")
    return False


def check_path_python(report: Report) -> None:
    """The scripts run as `#!/usr/bin/env python3`, so PATH decides which one."""
    found = shutil.which("python3")
    if found is None:
        report.fail("no `python3` on PATH, which every script's shebang needs")
        return
    try:
        result = subprocess.run(
            [found, "-c", "import sys; print(*sys.version_info[:3], sep='.')"],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        report.fail(f"`python3` on PATH ({found}) did not run: {error}")
        return
    text = result.stdout.strip()
    try:
        version = tuple(int(part) for part in text.split("."))
    except ValueError:
        report.fail(f"`python3` on PATH ({found}) reported no version: {text!r}")
        return
    if version[:2] >= MIN_PYTHON:
        report.ok(f"`python3` on PATH is {text} ({found})")
    else:
        report.fail(f"`python3` on PATH is {text} ({found}), older than "
                    f"{version_text(MIN_PYTHON)}; put a newer one first on PATH")


def python_files(root: Path) -> list[Path]:
    return sorted(
        path for path in root.rglob("*.py")
        if not SKIP_DIRS.intersection(path.relative_to(root).parts[:-1])
    )


def is_guard(node: ast.Try) -> bool:
    """Whether a try statement catches a failed import."""
    for handler in node.handlers:
        caught = handler.type
        names = caught.elts if isinstance(caught, ast.Tuple) else [caught]
        if any(isinstance(n, ast.Name) and n.id in GUARD_EXCEPTIONS for n in names):
            return True
    return False


def collect_imports(tree: ast.AST) -> Imports:
    found = Imports()

    def visit(node: ast.AST, guarded: bool) -> None:
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names = [node.module]
        else:
            names = []
        for name in names:
            top = name.split(".")[0]
            (found.optional if guarded else found.required).add(top)
        if isinstance(node, ast.Try) and is_guard(node):
            for child in node.body:
                visit(child, True)
            for child in [*node.handlers, *node.orelse, *node.finalbody]:
                visit(child, guarded)
            return
        for child in ast.iter_child_nodes(node):
            visit(child, guarded)

    visit(tree, False)
    found.optional -= found.required
    return found


def is_local(module: str, script: Path) -> bool:
    """A sibling module or package: the script's own directory is sys.path[0]."""
    here = script.parent
    return (here / f"{module}.py").is_file() or (here / module / "__init__.py").is_file()


def applies_here(module: str) -> bool:
    platform = PLATFORM_ONLY.get(module)
    if platform is None:
        return True
    if platform == "win32":
        return sys.platform == "win32"
    return sys.platform != "win32"


def resolves(module: str) -> bool:
    try:
        return importlib.util.find_spec(module) is not None
    except (ImportError, ValueError):
        return False


def check_file(path: Path, root: Path, report: Report, verbose: bool) -> None:
    name = path.relative_to(root)
    try:
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source, filename=str(path))
        compile(tree, str(path), "exec")
    except (SyntaxError, UnicodeDecodeError, ValueError) as error:
        report.fail(f"{name} does not compile under Python "
                    f"{version_text(tuple(sys.version_info[:3]))}: {error}")
        return
    imports = collect_imports(tree)
    external = sorted(m for m in imports.required if not is_local(m, path))
    missing = [m for m in external if applies_here(m) and not resolves(m)]
    if missing:
        report.fail(f"{name} imports modules this Python lacks: {', '.join(missing)}")
    else:
        report.ok(f"{name}")
    for module in sorted(imports.optional):
        if not is_local(module, path) and not resolves(module):
            report.info(f"{name} can use `{module}`, which is not installed (optional)")
    if verbose:
        print(f"          needs: {' '.join(external) or '(nothing)'}")


def check_extras(report: Report) -> None:
    for extra in EXTRAS:
        if resolves(extra.module):
            report.ok(f"optional {extra.package} is installed")
        else:
            report.info(f"optional {extra.package} is not installed; it is used by "
                        f"{extra.used_by}. Install it into a virtualenv if you need it.")


def check_gitignore(root: Path, report: Report) -> None:
    ignore = root / ".gitignore"
    if not ignore.is_file():
        report.fail(".gitignore is missing, so Python caches could be committed")
        return
    lines = {line.strip() for line in ignore.read_text(encoding="utf-8").splitlines()}
    missing = [rule for rule in GITIGNORE_RULES if rule not in lines]
    if missing:
        report.fail(f".gitignore lacks {', '.join(missing)}")
    else:
        report.ok(".gitignore keeps Python caches and virtualenvs out of commits")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent,
                        help="the checkout to check (default: this file's directory)")
    parser.add_argument("--verbose", action="store_true",
                        help="list the modules each file imports")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    report = Report()
    print("Interpreter")
    if not check_interpreter(report):
        # Nothing below means anything on an interpreter below the floor.
        return 1
    check_path_python(report)
    files = python_files(root)
    print(f"Scripts ({len(files)} under {root})")
    if not files:
        report.fail(f"no Python files under {root}; is --root a checkout?")
    for path in files:
        check_file(path, root, report, args.verbose)
    print("Optional")
    check_extras(report)
    print("Repository")
    check_gitignore(root, report)
    print()
    if report.failures:
        print(f"{len(report.failures)} problem(s). The tooling will not run as-is.")
        return 1
    print("The Python tooling can run here.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
