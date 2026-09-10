#!/usr/bin/env python3
"""Sabotage harness — check whether a test can actually fail.

A gate, assertion or regression test that has only ever been observed passing is
indistinguishable from one that does nothing.  This applies a catalogue of
deliberate defects ("mutations") to `lib/`, runs the tests that claim to cover
them, and reports which mutations went UNNOTICED.

    tool/mutate.py catalogue.json            # run every mutation in the file
    tool/mutate.py catalogue.json --only glab   # substring-filter by label
    tool/mutate.py catalogue.json --keep      # leave the worktree for inspection
    tool/mutate.py --check                    # every catalogue: applies, still compiles
    tool/mutate.py --check a.json b.json      # the same, for the catalogues named

The catalogue is JSON: a list of objects with

    label   a short name for the defect, e.g. "creation level ignored"
    file    path under the repo root, e.g. "lib/core/gitlab/glab_service.dart"
    find    the exact source text to replace (must occur EXACTLY ONCE)
    replace what to put there instead
    tests   list of test paths to run; omit to run the whole suite

Six properties of this harness are load-bearing, each learned by getting it
wrong first:

1.  **It runs in a scratch `git worktree`, never in your tree.**  Mutating the
    working tree to create a broken input means cleaning up afterwards with a
    `git checkout --`, which is exactly the destructive-command-as-diagnostic
    the project rules forbid.  Your tree is never touched, and an interrupted
    run leaves a directory rather than damage.

2.  **A mutation that does not apply is reported, not skipped silently.**  A
    search-and-replace that matched nothing still exits zero.  `dart format`
    reflows source, so a `find` string copied from an editor may no longer
    exist — three separate times in MADR 0032's execution a "surviving"
    mutation turned out never to have been applied.  A DID-NOT-APPLY line is a
    broken catalogue entry, NOT a passing test.

3.  **A survivor is a question, not a verdict.**  It means the mutation was not
    detected — which is sometimes a missing assertion, and sometimes a mutation
    that changes nothing observable (MADR 0032 Phase 5 had one of each in the
    same run).  Read the code before writing a test.

4.  **The unmutated tree must pass first, or no result means anything.**  A
    mutation is detected by its tests failing — and a broken tree fails them too.
    MADR 0045's first catalogue run mirrored none of a new, untracked
    directory, so every test that imported it failed to build, and 25 mutations
    were reported KILLED without ever having been observed.  The harness now runs
    the selected tests on the unmutated worktree before the first mutation, and
    stops with BASELINE RED if they fail.  It also mirrors every uncommitted
    path — each untracked file, including those inside new directories, and every
    deletion — and stops on any path it cannot mirror, rather than skipping it.

5.  **A kill is a named test failing — nothing less.**  A run can fail with no
    test observing the mutation at all: it did not build, or the tool itself
    failed.  A 0041 entry named a type that does not exist (`_NeverThrown`), and
    the records of MADRs 0041, 0043 and 0044 each counted it KILLED.  A failed
    run is now KILLED only when a named test failed; one that did not build is
    DOES NOT COMPILE, and one with no named failure is OBSERVED BY NO TEST —
    both broken entries that fail the run, as DID NOT APPLY does.  The compile
    detector reads the tester's own wording, so before the first mutation a
    compile canary proves it still recognises this SDK's output.

6.  **A catalogue rots between the runs that would notice.**  Code moves under
    an entry long after the MADR that wrote it closed: anchors stop matching,
    and a replacement can stop compiling.  Each is caught only when that
    catalogue next runs, which may be never.  `--check` applies every entry of
    every catalogue and analyses the whole package — no test runs — so a stale
    or uncompilable entry surfaces at the next phase boundary.  Its first run
    found the second never-compiled entry and 15 stale anchors (0045 plan,
    deviation (c)).  It proves itself too: the unmutated package must analyse
    clean, and a planted type error must be reported, before any entry counts
    as sound.

Prior art: `mutation_test` on pub.dev generates mutations from operator rules
and runs the suite per mutation.  This harness is the complement, not a
replacement — it takes a HAND-WRITTEN catalogue aimed at named contracts and
runs only the tests that claim to cover them, which is what makes it fast
enough to use inside a single phase of work.
"""

import argparse
import functools
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGUE_DIR = os.path.join(REPO, 'tool', 'mutations')

# A run takes minutes and is usually redirected to a file, where Python's block
# buffering would hold every line until exit — turning a live progress report
# into a single dump. Flushing per line is the whole point of printing as it
# goes.
print = functools.partial(print, flush=True)  # noqa: A001

# What the Flutter tester prints when a test does not build: flutter_tools'
# `lib/src/test/flutter_platform.dart`, on `TestCompilerFailure`. An SDK upgrade
# can reword it, which is why `compile_canary` re-proves it on every run.
COMPILE_FAILURE_MARKER = 'Compilation failed for testPath='

KILLED = 'KILLED'
DOES_NOT_COMPILE = 'DOES NOT COMPILE'
OBSERVED_BY_NO_TEST = 'OBSERVED BY NO TEST'
REASONS = {
    KILLED: 'tests failed',
    DOES_NOT_COMPILE: 'does not compile',
    OBSERVED_BY_NO_TEST: 'the run failed, but no test did',
}

# Written into the scratch worktree only, and removed before the first mutation.
CANARY_LIB = os.path.join('lib', 'mutate_compile_canary.dart')
CANARY_TEST = os.path.join('test', 'mutate_compile_canary_test.dart')
CANARY_SOURCE = "const int mutateCompileCanary = 'not an int';\n"

# `dart analyze` exits 0 (clean), 1 (infos, when fatal), 2 (warnings) or 3
# (errors). Anything else means the analysis did not complete, and an empty
# error list from an analysis that never ran would read as "compiles".
ANALYZE_EXIT_CODES = {0, 1, 2, 3}


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def load_catalogue(path):
    with open(path) as handle:
        return json.load(handle)


def read_anchor(path, find):
    """(source, matches) for one entry. A missing file, or an empty anchor,
    applies nowhere — `''.count('')` is 1, which would "apply" to nothing."""
    if not find or not os.path.isfile(path):
        return None, 0
    with open(path) as handle:
        source = handle.read()
    return source, source.count(find)


def create_worktree():
    """A scratch worktree at HEAD, holding the working tree's uncommitted changes."""
    worktree = tempfile.mkdtemp(prefix='mutate-')
    add = run(['git', 'worktree', 'add', '--detach', worktree, 'HEAD'], REPO)
    if add.returncode:
        sys.exit(f'could not create worktree:\n{add.stderr}')
    print(f'worktree: {worktree}')
    try:
        copied, deleted = mirror_working_tree(worktree)
    except BaseException:
        remove_worktree(worktree, keep=False)
        raise
    print(f'mirrored {copied} uncommitted file(s), removed {deleted} deleted')
    return worktree


def remove_worktree(worktree, keep):
    if keep:
        print(f'\nworktree kept at {worktree}')
    else:
        run(['git', 'worktree', 'remove', '--force', worktree], REPO)


def pub_get(worktree, required):
    pub = run(['flutter', 'pub', 'get', '--enforce-lockfile'], worktree)
    if pub.returncode == 0:
        return
    if required:
        sys.exit(f'`flutter pub get` failed in the worktree:\n{pub.stdout}{pub.stderr}')
    print('WARNING: `flutter pub get` failed in the worktree', file=sys.stderr)


def mirror_working_tree(worktree, repo=REPO):
    """Copy uncommitted changes into the worktree; return (copied, deleted).

    The worktree is created at HEAD, so without this a catalogue aimed at
    work-in-progress silently tests the last commit instead — passing for
    entirely the wrong reason.

    `--untracked-files=all`, because plain `--porcelain` lists a new untracked
    directory as ONE entry, which is not a file and used to be skipped whole
    (MADR 0045 plan, deviation (a)). `-z`, so paths are never quoted and a rename
    arrives as two NUL-separated fields. A deleted path is removed from the
    worktree too, or a test would still compile against a file that is gone.
    Anything else that cannot be mirrored stops the run: a silently skipped path
    is exactly the defect this replaces.
    """
    out = run(
        ['git', 'status', '--porcelain', '--untracked-files=all', '-z'], repo
    ).stdout
    fields = out.split('\0')
    copied = deleted = 0
    i = 0
    while i < len(fields):
        entry = fields[i]
        i += 1
        if not entry:
            continue
        code, path = entry[:2], entry[3:]
        if 'R' in code or 'C' in code:
            # Porcelain v1 with -z: "XY new\0old\0". The old name must go.
            old = fields[i]
            i += 1
            if 'R' in code:
                stale = os.path.join(worktree, old)
                if os.path.isfile(stale):
                    os.remove(stale)
                    deleted += 1
        src = os.path.join(repo, path)
        dst = os.path.join(worktree, path)
        if 'D' in code and not os.path.exists(src):
            if os.path.isfile(dst):
                os.remove(dst)
                deleted += 1
            continue
        if not os.path.isfile(src):
            sys.exit(f'mirror: cannot mirror {path!r} ({code!r}) — neither a '
                     f'file nor a deletion')
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(src, dst)
        copied += 1
    return copied, deleted


def failing_test_names(output):
    """Names of the tests a `flutter test` run reported as failed, in order."""
    names, seen = [], set()
    for line in output.splitlines():
        if line.strip().endswith('[E]'):
            name = line.split(': ', 2)[-1].replace(' [E]', '').strip()
            if name not in seen:
                seen.add(name)
                names.append(name)
    return names


def classify_failure(output):
    """Why a failed `flutter test` run failed: (verdict, evidence lines).

    Only a named test failing is KILLED. A run that did not build observed
    nothing, and neither did one that failed without a test failing — the
    tester reports a file that could not load as a pseudo-test named
    `loading <path>`, which is not a test. Compile failure wins over any named
    failure alongside it: part of the experiment never ran.
    """
    compile_errors = list(dict.fromkeys(
        line.split(COMPILE_FAILURE_MARKER, 1)[1].split(': ', 1)[-1].strip()
        for line in output.splitlines()
        if COMPILE_FAILURE_MARKER in line
    ))
    if compile_errors:
        return DOES_NOT_COMPILE, compile_errors
    names = failing_test_names(output)
    tests = [name for name in names if not name.startswith('loading ')]
    if tests:
        return KILLED, tests
    tail = [line.strip() for line in output.splitlines() if line.strip()][-5:]
    return OBSERVED_BY_NO_TEST, names or tail


def package_name(worktree):
    with open(os.path.join(worktree, 'pubspec.yaml')) as handle:
        for line in handle:
            if line.startswith('name:'):
                return line.split(':', 1)[1].strip()
    sys.exit('pubspec.yaml has no `name:` line')


def compile_canary(worktree):
    """Stop the run unless a mutation that does not build is classified as one.

    Writes a `lib` file with a type error, and a test importing it, into the
    scratch worktree, runs that test, and removes both. If the tester's output
    no longer carries COMPILE_FAILURE_MARKER, every mutation that does not
    build would silently count as a kill again (0045 plan, deviation (b)).
    """
    lib, test = (os.path.join(worktree, path) for path in (CANARY_LIB, CANARY_TEST))
    for path in (lib, test):
        if os.path.exists(path):
            sys.exit(f'CANARY: {path} already exists; refusing to overwrite it')
    with open(lib, 'w') as handle:
        handle.write(CANARY_SOURCE)
    with open(test, 'w') as handle:
        handle.write(
            f"import 'package:{package_name(worktree)}/mutate_compile_canary.dart';\n"
            '\n'
            'void main() {\n'
            '  print(mutateCompileCanary);\n'
            '}\n'
        )
    try:
        result = run(['flutter', 'test', CANARY_TEST], worktree)
    finally:
        os.remove(lib)
        os.remove(test)
    output = result.stdout + result.stderr
    verdict = classify_failure(output)[0] if result.returncode else 'PASSED'
    if verdict != DOES_NOT_COMPILE:
        print(f'CANARY: a deliberate compile error was classified {verdict!r}, '
              f'not {DOES_NOT_COMPILE!r}. The tester no longer prints '
              f'{COMPILE_FAILURE_MARKER!r}, so a mutation that does not build '
              f'would count as a kill — no result would be valid.')
        sys.exit(3)


def analyzer_errors(worktree):
    """Every analyzer ERROR in the whole package, without line or column.

    The whole package, because a mutation that compiles in its own file can
    break a file that uses it. Positions are dropped so that a mutation which
    shifts lines cannot make an existing error look new.
    """
    result = run(['dart', 'analyze', '--format=machine', '.'], worktree)
    if result.returncode not in ANALYZE_EXIT_CODES:
        sys.exit(f'dart analyze did not complete (exit {result.returncode}):\n'
                 f'{(result.stdout + result.stderr)[-2000:]}')
    root = os.path.realpath(worktree)
    errors = set()
    for line in (result.stdout + result.stderr).splitlines():
        fields = line.split('|')
        if len(fields) >= 8 and fields[0] == 'ERROR':
            path = os.path.relpath(os.path.realpath(fields[3]), root)
            errors.add(f'{path}: {fields[2]}: {"|".join(fields[7:])}')
    return errors


def analyzer_canary(worktree):
    """Stop the check unless a planted type error is reported against its file."""
    lib = os.path.join(worktree, CANARY_LIB)
    if os.path.exists(lib):
        sys.exit(f'CANARY: {lib} already exists; refusing to overwrite it')
    with open(lib, 'w') as handle:
        handle.write(CANARY_SOURCE)
    try:
        errors = analyzer_errors(worktree)
    finally:
        os.remove(lib)
    if not any(error.startswith(f'{CANARY_LIB}: ') for error in errors):
        print('CANARY: a planted type error was not reported by `dart analyze` '
              '— an entry that does not compile would pass the check.')
        sys.exit(3)


def check(catalogues, only, keep):
    """Every entry applies exactly once and leaves the package without an error.

    Runs no test, so it is cheap enough for every phase boundary; it does not
    replace a run, which is what shows the mutation is caught.
    """
    started = time.monotonic()
    sound, stale, uncompilable = 0, [], []
    worktree = create_worktree()
    try:
        pub_get(worktree, required=True)
        baseline = analyzer_errors(worktree)
        if baseline:
            print(f'BASELINE RED: the unmutated package has {len(baseline)} '
                  'analyzer error(s) — no entry could be judged.')
            for error in sorted(baseline)[:10]:
                print(f'          -> {error}')
            sys.exit(2)
        print('baseline clean: the unmutated package analyses without an error')
        analyzer_canary(worktree)
        print('analyzer canary recognised: a planted type error is reported')

        for catalogue in catalogues:
            name = os.path.basename(catalogue)
            entries = [e for e in load_catalogue(catalogue) if only in e['label']]
            print(f'{name}: {len(entries)} entries')
            for entry in entries:
                label = f'{name}: {entry["label"]}'
                target = os.path.join(worktree, entry['file'])
                source, hits = read_anchor(target, entry['find'])
                if hits != 1:
                    stale.append((label, hits))
                    print(f'  DID NOT APPLY [{hits} matches]: {entry["label"]}')
                    continue
                with open(target, 'w') as handle:
                    handle.write(source.replace(entry['find'], entry['replace']))
                try:
                    errors = sorted(analyzer_errors(worktree))
                finally:
                    with open(target, 'w') as handle:
                        handle.write(source)
                if not errors:
                    sound += 1
                    continue
                uncompilable.append(label)
                print(f'  {DOES_NOT_COMPILE}: {entry["label"]}')
                for error in errors[:4]:
                    print(f'          -> {error}')
    finally:
        remove_worktree(worktree, keep)

    minutes, seconds = divmod(round(time.monotonic() - started), 60)
    total = sound + len(stale) + len(uncompilable)
    print(
        f'\n{total} entries in {len(catalogues)} catalogue(s): {sound} sound, '
        f'{len(stale)} did not apply, {len(uncompilable)} do not compile '
        f'({minutes}m {seconds:02d}s)'
    )
    for label, hits in stale:
        print(f'  BROKEN   : {label} ({hits} matches — fix the catalogue)')
    for label in uncompilable:
        print(f'  BROKEN   : {label} (does not compile — fix the catalogue)')
    return 1 if stale or uncompilable else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('catalogues', nargs='*', metavar='catalogue')
    ap.add_argument('--check', action='store_true',
                    help='apply every entry and analyse the package, running no '
                         'test; every catalogue in tool/mutations/ unless named')
    ap.add_argument('--only', default='', help='substring filter on the label')
    ap.add_argument('--keep', action='store_true', help='keep the worktree')
    args = ap.parse_args()

    if args.check:
        catalogues = args.catalogues or sorted(
            glob.glob(os.path.join(CATALOGUE_DIR, '*.json'))
        )
        if not catalogues:
            sys.exit(f'no catalogues in {CATALOGUE_DIR}')
        sys.exit(check(catalogues, args.only, args.keep))
    if len(args.catalogues) != 1:
        ap.error('give exactly one catalogue to run, or --check')

    mutations = [
        m for m in load_catalogue(args.catalogues[0]) if args.only in m['label']
    ]
    if not mutations:
        sys.exit('no mutations selected')

    worktree = create_worktree()
    killed, survived, unapplied, unobserved = [], [], [], []
    try:
        pub_get(worktree, required=False)

        # BASELINE FIRST. Every test these mutations name must pass with no
        # mutation applied, or a KILLED line cannot be told apart from a tree
        # that never compiled. A mutation without `tests` runs the whole suite,
        # so the baseline does too.
        if any(not m.get('tests') for m in mutations):
            baseline_tests = []
        else:
            baseline_tests = list(
                dict.fromkeys(t for m in mutations for t in m['tests'])
            )
        baseline = run(['flutter', 'test'] + baseline_tests, worktree)
        if baseline.returncode:
            verdict, evidence = classify_failure(baseline.stdout + baseline.stderr)
            print('BASELINE RED: the unmutated tree fails the tests this '
                  f'catalogue relies on ({REASONS[verdict]}) — no mutation '
                  'result would be valid.')
            for line in evidence[:10]:
                print(f'          -> {line}')
            sys.exit(2)
        print(f'baseline green: {len(baseline_tests) or "all"} test file(s)')

        # CANARY SECOND, for the same reason: a detector that has stopped
        # matching is indistinguishable from a catalogue with nothing to report.
        compile_canary(worktree)
        print('compile canary recognised: a mutation that does not build is not a kill')

        for mutation in mutations:
            label = mutation['label']
            target = os.path.join(worktree, mutation['file'])
            source, hits = read_anchor(target, mutation['find'])
            if hits != 1:
                # NOT a survivor: the experiment never happened.
                unapplied.append((label, hits))
                print(f'DID NOT APPLY [{hits} matches]: {label}')
                continue

            backup = source
            open(target, 'w').write(
                source.replace(mutation['find'], mutation['replace'])
            )
            result = run(
                ['flutter', 'test'] + mutation.get('tests', []), worktree
            )
            open(target, 'w').write(backup)

            if result.returncode == 0:
                survived.append(label)
                print(f'SURVIVED: {label}')
                continue
            verdict, evidence = classify_failure(result.stdout + result.stderr)
            if verdict == KILLED:
                killed.append((label, evidence))
                print(f'KILLED  : {label}')
            else:
                # NOT a kill: the run failed, but no test observed the mutation.
                unobserved.append((label, verdict))
                print(f'{verdict}: {label}')
            for line in evidence[:4]:
                print(f'          -> {line}')
    finally:
        remove_worktree(worktree, args.keep)

    did_not_compile = [label for label, v in unobserved if v == DOES_NOT_COMPILE]
    no_test = [label for label, v in unobserved if v == OBSERVED_BY_NO_TEST]
    print(
        f'\n{len(killed)} killed, {len(survived)} survived, '
        f'{len(unapplied)} did not apply, {len(did_not_compile)} did not compile, '
        f'{len(no_test)} observed by no test'
    )
    for label in survived:
        print(f'  SURVIVOR : {label}')
    for label, hits in unapplied:
        print(f'  BROKEN   : {label} ({hits} matches — fix the catalogue)')
    for label, verdict in unobserved:
        print(f'  BROKEN   : {label} ({REASONS[verdict]} — fix the catalogue)')

    # A catalogue entry that did not apply, did not compile, or failed without
    # a test failing is a broken experiment, and fails the run exactly like a
    # survivor does.
    sys.exit(1 if survived or unapplied or unobserved else 0)


if __name__ == '__main__':
    main()
