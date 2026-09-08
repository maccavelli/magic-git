#!/usr/bin/env python3
"""Sabotage harness — check whether a test can actually fail.

A gate, assertion or regression test that has only ever been observed passing is
indistinguishable from one that does nothing.  This applies a catalogue of
deliberate defects ("mutations") to `lib/`, runs the tests that claim to cover
them, and reports which mutations went UNNOTICED.

    tool/mutate.py catalogue.json            # run every mutation in the file
    tool/mutate.py catalogue.json --only glab   # substring-filter by label
    tool/mutate.py catalogue.json --keep      # leave the worktree for inspection

The catalogue is JSON: a list of objects with

    label   a short name for the defect, e.g. "creation level ignored"
    file    path under the repo root, e.g. "lib/core/gitlab/glab_service.dart"
    find    the exact source text to replace (must occur EXACTLY ONCE)
    replace what to put there instead
    tests   list of test paths to run; omit to run the whole suite

Three properties of this harness are load-bearing, each learned by getting it
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

Prior art: `mutation_test` on pub.dev generates mutations from operator rules
and runs the suite per mutation.  This harness is the complement, not a
replacement — it takes a HAND-WRITTEN catalogue aimed at named contracts and
runs only the tests that claim to cover them, which is what makes it fast
enough to use inside a single phase of work.
"""

import argparse
import functools
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A run takes minutes and is usually redirected to a file, where Python's block
# buffering would hold every line until exit — turning a live progress report
# into a single dump. Flushing per line is the whole point of printing as it
# goes.
print = functools.partial(print, flush=True)  # noqa: A001


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def mirror_working_tree(worktree):
    """Copy uncommitted changes into the worktree.

    The worktree is created at HEAD, so without this a catalogue aimed at
    work-in-progress silently tests the last commit instead — passing for
    entirely the wrong reason.
    """
    status = run(['git', 'status', '--porcelain'], REPO).stdout.splitlines()
    copied = 0
    for line in status:
        path = line[3:].split(' -> ')[-1].strip()
        src = os.path.join(REPO, path)
        if not os.path.isfile(src):
            continue
        dst = os.path.join(worktree, path)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(src, dst)
        copied += 1
    return copied


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('catalogue')
    ap.add_argument('--only', default='', help='substring filter on the label')
    ap.add_argument('--keep', action='store_true', help='keep the worktree')
    args = ap.parse_args()

    with open(args.catalogue) as handle:
        mutations = json.load(handle)
    if args.only:
        mutations = [m for m in mutations if args.only in m['label']]
    if not mutations:
        sys.exit('no mutations selected')

    worktree = tempfile.mkdtemp(prefix='mutate-')
    add = run(['git', 'worktree', 'add', '--detach', worktree, 'HEAD'], REPO)
    if add.returncode:
        sys.exit(f'could not create worktree:\n{add.stderr}')
    print(f'worktree: {worktree}')
    print(f'mirrored {mirror_working_tree(worktree)} uncommitted file(s)')

    pub = run(['flutter', 'pub', 'get'], worktree)
    if pub.returncode:
        print('WARNING: `flutter pub get` failed in the worktree', file=sys.stderr)

    killed, survived, unapplied = [], [], []
    try:
        for mutation in mutations:
            label = mutation['label']
            target = os.path.join(worktree, mutation['file'])
            source = open(target).read()
            hits = source.count(mutation['find'])
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
            else:
                out = result.stdout + result.stderr
                names, seen = [], set()
                for line in out.splitlines():
                    if line.strip().endswith('[E]'):
                        name = line.split(': ', 2)[-1].replace(' [E]', '').strip()
                        if name not in seen:
                            seen.add(name)
                            names.append(name)
                killed.append((label, names))
                print(f'KILLED  : {label}')
                for name in names[:4]:
                    print(f'          -> {name}')
    finally:
        if args.keep:
            print(f'\nworktree kept at {worktree}')
        else:
            run(['git', 'worktree', 'remove', '--force', worktree], REPO)

    print(
        f'\n{len(killed)} killed, {len(survived)} survived, '
        f'{len(unapplied)} did not apply'
    )
    for label in survived:
        print(f'  SURVIVOR : {label}')
    for label, hits in unapplied:
        print(f'  BROKEN   : {label} ({hits} matches — fix the catalogue)')

    # A catalogue entry that did not apply is a broken experiment and fails the
    # run, exactly like a survivor does.
    sys.exit(1 if survived or unapplied else 0)


if __name__ == '__main__':
    main()
