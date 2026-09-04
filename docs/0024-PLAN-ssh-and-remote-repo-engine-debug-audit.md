---
status: "complete"
date: 2026-09-04
associated-madr: "0024-MADR-ssh-and-remote-repo-engine-debug-audit.md"
---

# Implement the 2026-09-04 SSH / remote-repo engine remediation backlog

Associated MADR: [0024-MADR-ssh-and-remote-repo-engine-debug-audit.md](0024-MADR-ssh-and-remote-repo-engine-debug-audit.md)

## Goal

Close the nine defects and land the four improvements catalogued in MADR 0024,
in an order that respects their dependencies, with every safety property left
behind a test that has been **observed to fail** before it was made to pass.

A phase is done when its acceptance criteria are met — not when its edit
compiles.

## Scope

**In scope.** Findings H1, H2, H3, M1, M2, M3, M4, L1, L2 and improvements P1,
A1, A2 from the MADR. Files touched are confined to:

```
lib/core/ssh/ssh_client_manager.dart
lib/core/ssh/ssh_command_executor.dart
lib/core/ssh/adaptive_read_concurrency.dart
lib/core/ssh/native_ssh_socket.dart
lib/core/ssh/ssh_error_messages.dart
lib/core/ssh/environment_probe.dart
lib/core/exec/command_drain.dart
lib/core/exec/command_lanes.dart           (comment only)
lib/core/git/remote_watch_service.dart
lib/core/providers/app_providers.dart      (3 call sites)
```

plus their existing test files. **No new production file is created.**

**Gated separately.** P2 (command batching) is specified in full as Phase 8 but
is **not authorized by approval of this plan**. It changes the executor seam
and needs its own go-ahead. Phases 0–7 stand complete without it.

**Out of scope.** Anything not named in MADR 0024. In particular: the forge
services, the local backend beyond parity, the pop-out relay, and UI surfaces.

## Execution rules

These are binding for every phase.

1. **Phase 0 runs to completion before any file is edited.** The baseline is
   invalid if the tree changes while it is being measured — this is the
   deviation recorded against `0022-PLAN` Phase 0, and it is not repeated.
2. **Negative test first, every time.** Each phase writes its test, runs it
   against the *unfixed* code, and records the **verbatim failure output** in
   this document's execution record. Only then is the fix applied. A phase
   whose test was never seen red is not complete, and is not committed.
3. **Where the fix changes a signature**, the test cannot run against the old
   tree. The procedure is then: land the *signature* with the old body, run the
   test, record the failure, then land the body. This is called the
   **two-step landing** below and is named explicitly wherever it applies.
4. **Never dirty the tree to create a broken input.** Reproductions run as
   standalone programs under the scratch directory, or against fakes in
   `test/`. No `git checkout --`, no `git stash`, no `git restore`
   (`AGENTS.md`).
5. **Assert the edit landed.** After every `sed`/scripted edit, verify the file
   changed (checksum before/after) — a search-and-replace that matched nothing
   exits zero.
6. **Read whole test output**, never through `head`/`tail`/a narrow `grep`, when
   judging whether a check failed for the reason expected.
0. **Every `flutter` invocation in this plan means `.flutter-sdk/bin/flutter`.**
   See deviation (a): Homebrew's `flutter` on PATH is 3.47.2 while
   `build_macos.sh:41` pins `FLUTTER_VERSION="3.44.8"`, and the two SDKs pin
   different transitive versions. Running the wrong one rewrites
   `pubspec.lock` and reports two lints that do not exist on the pinned SDK.
7. **Per-phase commit** once `flutter analyze` and `flutter test` are clean for
   that phase, using exactly `git commit --no-edit` — the global
   `prepare-commit-msg` hook writes the message (`AGENTS.md`). No `-m`, no
   `-F`, no trailers.
8. **No `git push`.** Not at the end of a phase, not at the end of the plan.
9. **Any deviation stops execution and prompts**, with evidence, real
   resolutions, and the cost of doing nothing — then the deviation is recorded
   here (and in the MADR if it contradicts a stated fact) *before* it is acted
   on.

## Phase table

| # | Finding | Files | Risk | Depends on |
|---|---|---|---|---|
| 0 | — (baseline) | none | none | — |
| 1 | H1 attach gate | `ssh_client_manager.dart` | low | 0 |
| 2 | H2 compressed budget | `command_drain.dart`, `ssh_command_executor.dart` | medium | 0 |
| 3 | A1 + H3 + M3 watcher | `remote_watch_service.dart` | medium | 0 |
| 4 | M1 + A2 read limiter | `adaptive_read_concurrency.dart`, `ssh_command_executor.dart`, `app_providers.dart` | medium | 0 |
| 5 | M2 channel budget | `ssh_command_executor.dart`, `ssh_error_messages.dart`, `remote_watch_service.dart`, `command_lanes.dart` | medium | 3, 4 |
| 6 | L1 + L2 | `native_ssh_socket.dart`, `ssh_error_messages.dart` | low | 0 |
| 7 | P1 (closes M4) | `environment_probe.dart`, `app_providers.dart` | medium | 0 |
| 8 | P2 batching | `ssh_command_executor.dart` (+ new) | high | 2, **separate approval** |

Phases 1, 2, 3, 4, 6 and 7 are independent of one another and may be executed
in any order; the table's order is by severity. Phase 5 depends on 3 (it edits
`arm`) and 4 (it reads the degraded-mode cap).

---

## Implementation Steps

### Phase 0 — Baseline

**Objective.** Establish, against an unmodified tree, the exact pass/fail set
every later phase is compared to.

**Method.**

```sh
cd /Users/saxsmith/gitrepos/magic-git
git status --short          # must print nothing
git rev-parse HEAD          # record this SHA in the execution record
flutter analyze 2>&1 | tee "$SCRATCH/phase0-analyze.txt"
flutter test    2>&1 | tee "$SCRATCH/phase0-test.txt"
```

`$SCRATCH` is the session scratch directory. **Nothing is edited while these
run.**

**Extract and record:**

```sh
grep -cE '^[0-9]{2}:[0-9]{2} \+' "$SCRATCH/phase0-test.txt"   # sanity
tail -1 "$SCRATCH/phase0-test.txt"                            # +N ~M -K line
grep -oE '^[0-9:]+ \+[0-9]+ ~[0-9]+ -[0-9]+: [^ ].*\[E\]' "$SCRATCH/phase0-test.txt" \
  | sed 's/^[0-9:]* [^:]*: //' | sort -u > "$SCRATCH/phase0-failing-set.txt"
wc -l "$SCRATCH/phase0-failing-set.txt"
```

**Acceptance criteria.**

* `git status --short` is empty at start **and** at end.
* `flutter analyze` reports `No issues found!`.
* The final test line, the passing count, and `phase0-failing-set.txt` are
  transcribed verbatim into the execution record.
* **Measured 2026-09-04 at `6f24bfe`: `+3398 ~2`, "All tests passed!",
  analyzer `No issues found!`, `phase0-failing-set.txt` EMPTY.** The gate is
  therefore absolute: any failure in any later phase is new. If a later run
  shows one, **stop and prompt** — there is no allowlist to diff against.
* The figure this plan originally predicted (`+3350 ~2 -48`) was measured under
  the wrong SDK; see deviation (a).

**Commit.** None.

---

### Phase 1 — H1: bind the attach gate to its own invocation

**Finding.** MADR 0024 → H1. `withAttachGate`'s `finally` re-reads the
`_attachGate` field, so an overlapping connect's early return settles the
*successor's* gate and MADR 0018's readiness wait is skipped.

**Files.** `lib/core/ssh/ssh_client_manager.dart` (1 function, 3 lines);
`test/transport_readiness_race_test.dart` (1 test added).

#### 1a. Write the negative test

Append to the existing top-level group in
`test/transport_readiness_race_test.dart`:

```dart
test('an overlapping attach does not settle the newer handshake', () async {
  final manager = SSHClientManager();
  final firstBody = Completer<void>();
  final secondBody = Completer<void>();

  // Connect A (an auto-reconnect attempt) is in flight.
  final first = manager.withAttachGate<void>(() => firstBody.future);
  expect(manager.isAttachSettled, isFalse);

  // Connect B (the user picks another connection) starts while A is unfinished.
  final second = manager.withAttachGate<void>(() => secondBody.future);
  expect(manager.isAttachSettled, isFalse);

  // A returns immediately via one of _connect's supersession early-returns.
  firstBody.complete();
  await first;

  // THE CONTRACT: B is still handshaking, so a command must still wait.
  expect(
    manager.isAttachSettled,
    isFalse,
    reason: 'the superseded attach must not settle its successor\'s gate',
  );

  secondBody.complete();
  await second;
  expect(manager.isAttachSettled, isTrue);
});
```

#### 1b. Run it red and record the failure

```sh
flutter test test/transport_readiness_race_test.dart 2>&1 | tee "$SCRATCH/p1-red.txt"
cat "$SCRATCH/p1-red.txt"     # read it whole — rule 6
```

**Required observation:** the third `expect` fails with
`Expected: false / Actual: <true>` and the reason string. If it passes, **stop
and prompt** — the finding's premise is wrong and the MADR needs an amendment,
not a fix.

Independent corroboration already exists: `$SCRATCH/gate.dart` from the audit
reproduces the same result outside the test harness.

#### 1c. Apply the fix

In `lib/core/ssh/ssh_client_manager.dart`, replace lines 393–401 exactly:

```dart
  Future<T> withAttachGate<T>(Future<T> Function() body) async {
    if (!_attachGate.isCompleted) _attachGate.complete();
    _attachGate = Completer<void>();
    try {
      return await body();
    } finally {
      if (!_attachGate.isCompleted) _attachGate.complete();
    }
  }
```

with:

```dart
  Future<T> withAttachGate<T>(Future<T> Function() body) async {
    // Settle whatever attempt this one supersedes...
    if (!_attachGate.isCompleted) _attachGate.complete();
    // ...then hold THIS invocation's gate in a local. The `finally` below must
    // settle the gate this attempt installed, never whatever the field happens
    // to hold by then: with two connects overlapping, the field already
    // belongs to the successor, and completing it declares a handshake settled
    // while it is still running — which makes `isAttachSettled` true and sends
    // every command straight to SSHTransportNotReady (MADR 0018's exact
    // failure, in the one state it exists to handle).
    final gate = _attachGate = Completer<void>();
    try {
      return await body();
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  }
```

Assert the edit landed (rule 5): the file's checksum changes and
`grep -c 'final gate = _attachGate' lib/core/ssh/ssh_client_manager.dart` is 1.

#### 1d. Verify

```sh
flutter analyze
flutter test test/transport_readiness_race_test.dart
flutter test
```

**Acceptance criteria.**

* The Phase-1 test failed in 1b with the recorded message, and passes in 1d.
* The five pre-existing tests in `transport_readiness_race_test.dart` still
  pass — in particular the ones at `:57`, `:96`, `:113`, which cover the
  single-attach path this must not regress.
* Full-suite passing count rises by exactly **1** (the test added here);
  failing set identical to `phase0-failing-set.txt`.

**Commit.** `git add -u && git commit --no-edit`.

---

### Phase 2 — H2: bound a compressed read on the wire and during decompression

**Finding.** MADR 0024 → H2. The compressed branch buffers the whole gzip
stream, decompresses all of it, and only then charges the budget — so the
budget bounds what is *reported*, not what is *buffered*.

**Files.** `lib/core/exec/command_drain.dart`,
`lib/core/ssh/ssh_command_executor.dart`; tests in
`test/command_drain_test.dart`, `test/ssh_command_executor_test.dart`.

**This phase uses the two-step landing** (rule 3): `gunzipStdout` gains
parameters, so the test cannot compile against today's signature.

#### 2a. Design (fixed here so execution makes no choices)

Two independent bounds, because they stop two different things:

1. **Wire bound** — charge each arriving compressed chunk *before* it is
   appended, so the accumulate aborts mid-stream instead of growing without
   limit. The ceiling is `maxCommandWireBytes`, defined equal to
   `maxCommandOutputBytes`: gzip output cannot meaningfully exceed its input,
   so a wire stream larger than the decompressed cap could not have
   decompressed to something under it. The constant is separate from the value
   so the *reason* is on the record, not inferred from the number.

2. **Decompression bound** — decompress through a chunked converter into a
   sink that counts as it goes and stops at the caller's remaining allowance,
   rather than materialising the whole result and asking afterwards. This is
   what actually stops a bomb: gzip's maximum ratio is ~1032:1, so 50 MB of
   wire can decompress to ~51 GB.

The 256 KiB isolate offload (`gzipOffloadWireBytes`) is preserved. Overflow
crosses the isolate boundary as a **null return**, not a thrown
`SSHOutputExceeded`, so the phase does not depend on exception forwarding
semantics between isolates; the caller converts null to the exception.

#### 2b. Write the negative tests

In `test/command_drain_test.dart`:

```dart
test('the wire ceiling is stated as equal to the decompressed ceiling', () {
  // Not arbitrary: gzip output cannot meaningfully exceed its input, so a
  // wire stream over this size could not decompress to something under the
  // other cap. Pinned so a future edit to one must consider the other.
  expect(maxCommandWireBytes, maxCommandOutputBytes);
});
```

In `test/ssh_command_executor_test.dart`, inside the existing
`group('gunzipStdout', ...)`:

```dart
test('a gzip bomb is refused during decompression, not after it', () async {
  // 8 MiB of zeroes compresses to a few KiB — the classic shape.
  final raw = Uint8List(8 * 1024 * 1024);
  final wire = Uint8List.fromList(gzip.encode(raw));
  expect(wire.length, lessThan(64 * 1024), reason: 'sanity: it must be a bomb');

  await expectLater(
    SSHCommandExecutor.gunzipStdout(wire, limit: 1024, label: 'bomb'),
    throwsA(isA<SSHOutputExceeded>()),
  );
});

test('a compressed read under the limit still decodes whole', () async {
  final raw = Uint8List.fromList(utf8.encode('hello ' * 1000));
  final wire = Uint8List.fromList(gzip.encode(raw));
  expect(await SSHCommandExecutor.gunzipStdout(wire, limit: 1 << 20), raw);
});
```

#### 2c. Two-step landing: signature only, then run red

Add `maxCommandWireBytes` to `command_drain.dart`, and change
`gunzipStdout`'s signature to

```dart
static Future<List<int>> gunzipStdout(
  Uint8List wire, {
  int limit = maxCommandOutputBytes,
  String label = '',
}) async {
```

**leaving the body exactly as it is today.** Then:

```sh
flutter test test/command_drain_test.dart test/ssh_command_executor_test.dart 2>&1 \
  | tee "$SCRATCH/p2-red.txt"
cat "$SCRATCH/p2-red.txt"
```

**Required observation:** the bomb test fails — it decompresses all 8 MiB and
returns normally, so `expectLater` reports that no `SSHOutputExceeded` was
thrown. The two other tests pass. Record the verbatim message.

This is the deliberate broken input the rule demands: the signature accepts a
limit and the body ignores it, which is precisely the defect being fixed.

#### 2d. Apply the fix

**`lib/core/exec/command_drain.dart`** — add after `maxCommandOutputBytes`:

```dart
/// Ceiling on the **compressed** bytes one command may buffer before it is
/// decompressed. Equal to [maxCommandOutputBytes] on purpose: gzip output
/// cannot meaningfully exceed its input, so a wire stream larger than the
/// decompressed cap could not have decompressed to something under it. Kept as
/// its own name so the reasoning survives a future change to either number.
const int maxCommandWireBytes = maxCommandOutputBytes;
```

**`lib/core/ssh/ssh_command_executor.dart`** — replace the body of
`gunzipStdout` and add the bounded sink:

```dart
  /// Gunzips [wire], refusing to materialise more than [limit] decompressed
  /// bytes. Charging *after* a full decode (what this used to do) bounds what
  /// gets reported, not what gets allocated: gzip's maximum ratio is ~1032:1,
  /// so the allocation the budget was meant to prevent had already happened by
  /// the time it was consulted. Decoding through a counting sink stops it.
  ///
  /// Offloads above [gzipOffloadWireBytes] as before. Overflow returns null
  /// across the isolate boundary and becomes [SSHOutputExceeded] here, so this
  /// does not rely on exception forwarding between isolates.
  static Future<List<int>> gunzipStdout(
    Uint8List wire, {
    int limit = maxCommandOutputBytes,
    String label = '',
  }) async {
    final out = wire.length > gzipOffloadWireBytes
        ? await Isolate.run(() => boundedGunzip(wire, limit))
        : boundedGunzip(wire, limit);
    if (out == null) throw SSHOutputExceeded(label);
    return out;
  }

  /// Decompresses [wire], or returns null the moment the decompressed size
  /// would pass [limit]. Top-level-callable (not a closure) so `Isolate.run`
  /// can reach it.
  @visibleForTesting
  static Uint8List? boundedGunzip(Uint8List wire, int limit) {
    final sink = _CountingBytesSink(limit);
    try {
      final conv = gzip.decoder.startChunkedConversion(sink);
      conv.add(wire);
      conv.close();
    } on _BudgetExceeded {
      return null;
    }
    return sink.takeBytes();
  }
}

class _BudgetExceeded implements Exception {
  const _BudgetExceeded();
}

/// Accumulates decoded bytes, aborting the conversion the moment the running
/// total passes [limit] — the whole point being that the abort happens during
/// the decode rather than after it.
class _CountingBytesSink implements Sink<List<int>> {
  _CountingBytesSink(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _used = 0;

  @override
  void add(List<int> data) {
    _used += data.length;
    if (_used > limit) throw const _BudgetExceeded();
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}
```

Then replace the compressed branch at `ssh_command_executor.dart:875-888`:

```dart
      if (compressed) {
        stdoutFuture = () async {
          // Charge the WIRE bytes as they arrive. Without this the builder
          // below grows without any ceiling at all, and the budget below it
          // cannot un-allocate what has already been read.
          final wireBudget = OutputByteBudget(maxCommandWireBytes);
          final builder = BytesBuilder(copy: false);
          await for (final chunk in rawStdout) {
            wireBudget.charge(chunk.length, label);
            builder.add(chunk);
          }
          final wire = Uint8List.fromList(builder.takeBytes());
          stdoutWireBytes = wire.length;
          // Bound the decode by whatever the shared stdout+stderr budget has
          // left — stderr drains concurrently and may have spent some of it.
          final remaining = budget.limit - budget.used;
          final raw = await gunzipStdout(
            wire,
            limit: remaining < 0 ? 0 : remaining,
            label: label,
          );
          budget.charge(raw.length, label);
          final text = utf8.decode(raw, allowMalformed: true);
          onOutput?.call(text, stderr: false);
          return text;
        }();
      } else {
```

Add `import 'dart:io' show ... ZLibDecoder;` only if the analyzer requires it —
`gzip` is already imported at `ssh_command_executor.dart:3`.

#### 2e. Verify

```sh
flutter analyze
flutter test test/command_drain_test.dart test/ssh_command_executor_test.dart
flutter test
```

**Acceptance criteria.**

* The bomb test failed in 2c with the recorded message and passes in 2e.
* The two pre-existing `gunzipStdout` tests (`ssh_command_executor_test.dart:213`,
  `:224`) pass **unchanged** — they call the positional form, which the default
  arguments preserve.
* Full-suite passing count rises by exactly **3** (the tests added here);
  failing set unchanged.

**Commit.** `git add -u && git commit --no-edit`.

---

### Phase 3 — A1 + H3 + M3: the remote watcher

Three independent defects in one file and one function. Executed as one phase
to avoid three commits churning the same block; each carries its own test and
its own acceptance criterion, and any one can be dropped without the others.

**File.** `lib/core/git/remote_watch_service.dart`.
**Tests.** `test/remote_watch_service_test.dart` (fakes already present:
`_SilentStreamHandle` at `:73` exposes both `_stdout` and `_stderr`
controllers).

#### 3a. A1 — the record split

**Negative test** (add to `test/remote_watch_service_test.dart`):

```dart
test('a large burst is split in linear time, not per-record copies', () async {
  // Correctness and cost, in one test. The correctness half passes today —
  // which is the point: only the timing assertion can fail first.
  const records = 20000;
  final paths = [for (var i = 0; i < records; i++) 'src/m$i/f$i.dart'];

  final sw = Stopwatch()..start();
  final seen = await _drainWatcher(paths);        // helper below
  sw.stop();

  expect(seen.length, records);
  expect(seen.first, 'src/m0/f0.dart');
  expect(seen.last, 'src/m${records - 1}/f${records - 1}.dart');
  // Generous by 10x against the measured 0.9 ms, and ~150x under the measured
  // 133.7 ms of the per-record-copy loop, so this cannot flake on a slow
  // machine and cannot pass on the quadratic implementation.
  expect(
    sw.elapsedMilliseconds,
    lessThan(20),
    reason: 'splitting must not copy the remaining buffer per record',
  );
});
```

`_drainWatcher` feeds the paths through `_SilentStreamHandle._stdout` in
**32 KiB chunks** — dartssh2 3.3.0's negotiated `_maximumPacketSize`
(`ssh_client.dart:57`) and therefore the real arrival shape — and collects the
paths the service signals.

**Run red:**

```sh
flutter test test/remote_watch_service_test.dart --plain-name "linear time" 2>&1 \
  | tee "$SCRATCH/p3a-red.txt"; cat "$SCRATCH/p3a-red.txt"
```

**Required observation:** the three correctness expectations pass and the
timing expectation fails at roughly 130 ms. If the elapsed time is already
under 20 ms, **stop and prompt**: the machine or the chunking is not
reproducing the audit's conditions and the measurement must be re-established
before a fix is justified.

**Fix** — replace `remote_watch_service.dart:188-226`:

```dart
            buffer += chunk;
            var idx = buffer.indexOf(delimiter);
            while (idx >= 0) {
              final event = buffer.substring(0, idx);
              buffer = buffer.substring(idx + 1);
```

with a cursor, leaving the loop body byte-for-byte unchanged:

```dart
            buffer += chunk;
            // Cursor, not repeated re-slicing. `buffer = buffer.substring(...)`
            // per record copies the whole remainder and restarts the scan at 0,
            // which is quadratic in the arriving chunk — 133 ms of UI-isolate
            // time for a 20k-event `git checkout` burst at dartssh2's 32 KiB
            // packet size, against 0.9 ms here (MADR 0024 A1). One remainder
            // copy per chunk instead of one per record.
            var start = 0;
            var idx = buffer.indexOf(delimiter, start);
            while (idx >= 0) {
              final event = buffer.substring(start, idx);
              start = idx + 1;
```

and at the end of the loop replace `idx = buffer.indexOf(delimiter);` with
`idx = buffer.indexOf(delimiter, start);`, then before the `_maxBufferChars`
check insert:

```dart
            if (start > 0) buffer = buffer.substring(start);
```

**Acceptance:** the test passes; the pre-existing delimiter/partial-record
tests in the same file pass unchanged (they cover records straddling chunk
boundaries, which the cursor must preserve).

#### 3b. H3 — consume the watcher's stderr

**Negative test:**

```dart
test('a watcher diagnostic on stderr is surfaced, not discarded', () async {
  final diagnostics = <String>[];
  final service = RemoteWatchService(executor, onDiagnostic: diagnostics.add);
  // ... arm, then:
  handle.emitStderr(
    'Failed to watch /home/u/src; upper limit on inotify watches reached\n',
  );
  await pumpEventQueue();

  expect(diagnostics, isNotEmpty);
  expect(diagnostics.single, contains('upper limit on inotify watches'));
});

test('a flooding watcher cannot fill the log', () async {
  // 500 lines in, at most _maxDiagnosticLines out.
  ...
  expect(diagnostics.length, RemoteWatchService.maxDiagnosticLines);
});
```

**Run red:** `diagnostics` is empty — nothing reads stderr today. (The
constructor gains a named optional parameter, so this is a **two-step
landing**: add `onDiagnostic` unused, run red, then wire it.)

**Fix.** In `RemoteWatchService`:

```dart
  RemoteWatchService(this._executor, {this.onDiagnostic});

  /// Where a watcher's own stderr goes. Null discards it — but the SSH backend
  /// must not: dartssh2's `SSHSession._stderrController` is a
  /// single-subscription controller with no listener (ssh_session.dart:74), so
  /// unread stderr is queued in the Dart heap for the life of the channel, and
  /// the watcher's channel is the longest-lived one in the app. Reading it is
  /// what bounds it (MADR 0024 H3).
  final void Function(String line)? onDiagnostic;

  /// Lines reported per arm. `inotifywait` prints one failure line per
  /// directory it cannot watch, so a host at its watch limit emits one per
  /// entry in the surface — bounded here rather than relayed in full.
  static const int maxDiagnosticLines = 20;
```

and inside `arm`, immediately after the `handle.stdout.listen(...)` assignment:

```dart
        // Read stderr even when nobody is listening to the diagnostics: see
        // [onDiagnostic]. The watch-limit line in particular is the one message
        // that says WHY a watcher died and names the sysctl to raise, and it
        // used to be dropped, leaving the user with a silent polling fallback.
        var diagnosticsSeen = 0;
        var errBuffer = '';
        final errSub = handle.stderr.listen(
          (chunk) {
            errBuffer += chunk;
            var start = 0;
            var i = errBuffer.indexOf('\n', start);
            while (i >= 0) {
              final line = errBuffer.substring(start, i).trim();
              start = i + 1;
              if (line.isNotEmpty && diagnosticsSeen < maxDiagnosticLines) {
                diagnosticsSeen++;
                developer.log(line, name: 'RemoteWatchService');
                onDiagnostic?.call(line);
              }
              i = errBuffer.indexOf('\n', start);
            }
            if (start > 0) errBuffer = errBuffer.substring(start);
            if (errBuffer.length > _maxBufferChars) errBuffer = '';
          },
          onError: (Object _) {},
        );
```

and in the `WatchArmed` teardown, before `await sub.cancel();`:

```dart
          await errSub.cancel();
```

Wire it at `lib/core/providers/app_providers.dart:360-362`:

```dart
final remoteWatchServiceProvider = Provider<RemoteWatchService>((ref) {
  return RemoteWatchService(
    ref.watch(executorProvider),
    onDiagnostic: (line) =>
        ref.read(outputLogProvider.notifier).logInfo('watcher: $line'),
  );
});
```

**Acceptance:** both tests pass; the diagnostic reaches the output log; the
teardown cancels the stderr subscription (asserted by the existing
cancellation test in the same file, extended to check both subscriptions).

#### 3c. M3 — a failed probe is not "no watcher"

**Negative test:**

```dart
test('a failed watcher probe retries rather than caching "none"', () async {
  // The probe fails once (transport blip), then succeeds reporting fswatch.
  final executor = _ProbeFailsOnceExecutor();
  // ... arm through watchLifecycle ...
  // Today: the empty stdout of the failed probe is read as `none`, cached, and
  // the stream degrades to polling for recoveryInterval (3 minutes).
  expect(await firstMode, WatchMode.eventDriven);
});
```

**Run red:** the first emitted mode is `WatchMode.polling`, because
`_detectWatcher` returned `none` and `cachedTool` pinned it.

**Fix** — `remote_watch_service.dart:244-268`:

```dart
  Future<RemoteWatcherTool> _detectWatcher(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: [ /* unchanged */ ],
      lane: ExecLane.read,
      // Idempotent and read-only, so a blip is worth one re-issue.
      retries: 1,
    );
    // A failed command is not evidence about the host's tooling. Reading it as
    // `none` cached that verdict for the stream's life and cost three minutes
    // of polling on a host with a perfectly good fswatch (MADR 0024 M3).
    // Throwing lets watchLifecycle's restart budget retry in seconds — which
    // is what it is for — and nothing is cached, because the assignment at the
    // call site never completes.
    if (!result.isSuccess) {
      throw StateError(
        'watcher probe failed (exit ${result.exitCode}): '
        '${result.stderr.trim()}',
      );
    }
    switch (result.stdout.trim()) { /* unchanged */ }
  }
```

**Acceptance:** the test passes; the existing "no watcher tool → polling" test
(which returns exit 0 with `none\n`) still passes, proving the genuine case is
untouched.

#### 3d. Phase verification

```sh
flutter analyze
flutter test test/remote_watch_service_test.dart
flutter test test/watch_lifecycle_test.dart test/repo_status_watch_refresh_test.dart
flutter test
```

**Acceptance criteria.** All three sub-fixes' tests were seen red and are
green; full-suite passing count rises by exactly **4** (the tests added
here); failing set unchanged.

**Commit.** `git add -u && git commit --no-edit`.

---

### Phase 4 — M1 + A2: replace the read-concurrency controller

**Finding.** MADR 0024 → M1 (the RTT probe is suppressed while busy, so the
controller never samples under load; and it bands a single sample while
documenting a median) and A2 (replace the open-loop band table with a
closed-loop limiter over data already collected under load).

**Files.** `lib/core/ssh/adaptive_read_concurrency.dart` (rewritten),
`lib/core/ssh/ssh_command_executor.dart` (feed samples; drop `noteLinkRtt`),
`lib/core/providers/app_providers.dart` (2 call sites).
**Tests.** `test/adaptive_read_concurrency_test.dart`.

#### 4a. Write the discriminating test against the CURRENT API

This is the one place a test can be seen to fail without a two-step landing,
because `onRtt` still exists at that point:

```dart
test('a uniformly slow but unqueued link keeps its full read cap', () {
  // 250 ms RTT with no queueing is a satellite link that is perfectly happy at
  // the full ceiling. Today's band table maps >200 ms to 2 unconditionally and
  // pins it there — which is the defect: the bands encode absolute latency,
  // and latency is not congestion.
  final caps = <int>[];
  final a = AdaptiveReadConcurrency(onCapChanged: caps.add);
  for (var i = 0; i < 20; i++) {
    a.onRtt(const Duration(milliseconds: 250));
  }
  expect(a.effectiveCap, 4);
});
```

**Run red:**

```sh
flutter test test/adaptive_read_concurrency_test.dart --plain-name "unqueued" 2>&1 \
  | tee "$SCRATCH/p4-red.txt"; cat "$SCRATCH/p4-red.txt"
```

**Required observation:** `Expected: <4> / Actual: <2>`.

#### 4b. Design (fixed here)

A gradient limiter — the TCP Vegas shape, as used by Netflix's
`concurrency-limits`. Constants are pinned so execution makes no choices:

| symbol | value | why |
|---|---|---|
| `alpha` (EWMA) | `0.2` | ~14 samples of memory; a burst of five slow reads must not swing the cap |
| `warmupSamples` | `10` | below this, hold `noSampleCap` (3) exactly as today |
| `minRttWindow` | `300` samples or `5 min` | so a link that genuinely improves is not anchored to an old best |
| `gradientFloor` | `0.5` | one step per adjustment, never a collapse to 1 from a single spike |
| `allowance` | `sqrt(limit)` | the standard probe headroom that lets the limit rise |
| `smoothing` | `0.5` | move halfway to the target per adjustment |

```
onReadSample(d):
  n++
  minRtt = (n == 1 || d < minRtt || windowExpired) ? d : minRtt
  currentRtt = (n == 1) ? d : currentRtt*(1-alpha) + d*alpha
  if n < warmupSamples: return
  gradient   = (minRtt / currentRtt).clamp(gradientFloor, 1.0)
  target     = limit * gradient + sqrt(limit)
  next       = round(limit + (target - limit) * smoothing)
  commit(next.clamp(1, min(errorFloor, ceiling)))
```

`onChannelOpenError` keeps its present behaviour verbatim — `MaxSessions` is a
cliff, not a gradient, and must drop the floor immediately.

`onRtt` and `bandForRtt` are **removed**, not deprecated: leaving a second
input that cannot observe load is how M1 happened.

#### 4c. Apply

1. Rewrite `adaptive_read_concurrency.dart` to the design above, preserving the
   public surface `effectiveCap`, `onChannelOpenError`, `onSuccess`, `reset`,
   `onCapChanged`, `ceiling`, `noSampleCap`, and adding
   `onReadSample(Duration)`. Fold `onSuccess`'s error-floor recovery in
   unchanged.
2. `ssh_command_executor.dart` — in `_run`'s success path (`:761`, where
   `_adaptiveReads.onSuccess()` is called today), add for read-lane commands
   only:
   ```dart
   if (lane == ExecLane.read) _adaptiveReads.onReadSample(sw.elapsed);
   ```
   The stopwatch is already running in `_runBody`; hoist its elapsed value out
   through the result path rather than starting a second one.
3. Delete `noteLinkRtt` (`ssh_command_executor.dart:379`).
4. `app_providers.dart:1345-1349` and `:2396-2400` — drop the
   `ref.read(executorProvider).noteLinkRtt(rtt);` line from both. **Keep**
   `ref.read(pingSamplesProvider.notifier).add(rtt);` — the dashboard's latency
   sparkline is the ping's remaining, legitimate consumer.
5. Update the class doc: the ping keeps liveness, and no longer claims a median.

#### 4d. Verify

```sh
flutter analyze
flutter test test/adaptive_read_concurrency_test.dart
flutter test test/ssh_busy_split_test.dart test/connection_health_monitor_test.dart
flutter test
```

**Acceptance criteria.**

* 4a's test failed with `Actual: <2>` and now passes.
* A second new test — latency rising *with* concurrency (currentRtt drifting
  above minRtt) — drives the cap **down**, proving the controller still sheds
  load and that 4a's fix is not simply "never adjust".
* A third asserts `onChannelOpenError` still drops the floor immediately.
* Existing tests in `adaptive_read_concurrency_test.dart` that exercise
  `onRtt` are **rewritten, not deleted**, to the new input. Deleting them
  would lose the hysteresis and error-floor coverage they carry. If any cannot
  be expressed against the new API, **stop and prompt** rather than dropping
  the assertion.
* Failing set unchanged.

**Commit.** `git add -u && git commit --no-edit`.

---

### Phase 5 — M2: make the MaxSessions budget a counter

**Finding.** MADR 0024 → M2. Stream channels are unbounded and unscheduled, and
the budget exists only as a comment that omits them.

**Depends on** Phase 3 (edits `arm`) and Phase 4 (reads the read cap).

**Files.** `lib/core/ssh/ssh_command_executor.dart`,
`lib/core/ssh/ssh_error_messages.dart`, `lib/core/git/remote_watch_service.dart`,
`lib/core/exec/command_lanes.dart` (comment).

#### 5a. Design

```dart
/// Channels the stream lane may hold open at once.
///
/// In triple-client mode streams have their own TCP, so the budget is the
/// host's MaxSessions (10 by default) less headroom: 8. When the stream client
/// has degraded onto the command client, they share that connection with ≤4
/// reads, ≤2 isolated and (if sync also degraded) 1 sync — so 2 is what is
/// left. This used to be prose in command_lanes.dart that simply omitted
/// streams (MADR 0024 M2).
int get maxConcurrentStreams => _clientManager.streamClientDegraded ? 2 : 8;
```

A new typed exception, because the caller must distinguish "the host refused"
(`SSHChannelOpenError`, transient, retry) from "we refused" (deterministic,
do not retry, degrade this watcher to polling):

```dart
class SSHStreamBudgetExhausted implements Exception {
  const SSHStreamBudgetExhausted(this.command, this.active, this.limit);
  final String command;
  final int active;
  final int limit;
  @override
  String toString() =>
      'SSH stream budget exhausted ($active/$limit): $command';
}
```

It is added to `isTransientTransportError`'s **non-retryable** list, alongside
`SSHCommandTimeout` and friends.

#### 5b. Negative test

In `test/ssh_command_executor_test.dart`, using `bindTestClients` and
`test/helpers/fake_ssh_client.dart`:

```dart
test('the stream budget refuses the channel the host would refuse', () async {
  // Open exactly the budget, then one more.
  final handles = <SSHStreamHandle>[];
  for (var i = 0; i < executor.maxConcurrentStreams; i++) {
    handles.add(await executor.executeStream(repoPath: '/r', gitArgs: ['x']));
  }
  await expectLater(
    executor.executeStream(repoPath: '/r', gitArgs: ['x']),
    throwsA(isA<SSHStreamBudgetExhausted>()),
  );
  for (final h in handles) { await h.cancel(); }
  // And the slot comes back.
  handles.add(await executor.executeStream(repoPath: '/r', gitArgs: ['x']));
});
```

**Run red** (two-step landing: `maxConcurrentStreams` and the exception type
land first, unused). **Required observation:** the ninth `executeStream`
succeeds — no budget is enforced.

#### 5c. Apply

1. Add the getter and exception; enforce in `executeStream` **after** the
   readiness gate and generation checks and **before** `client.execute`
   (`ssh_command_executor.dart:1105`).
2. `isTransientTransportError` — add `SSHStreamBudgetExhausted` to the
   never-retry block at `:614-623`.
3. `humanizeSshError` — add an arm above the `SSHChannelOpenError` arm:
   *"Too many live streams on this connection. Close a repository window or a
   CI trace and try again."*
4. `remote_watch_service.dart` `arm` — catch it and degrade cleanly rather than
   burning the restart budget:
   ```dart
   final CommandStreamHandle handle;
   try {
     handle = await _executor.executeStream(...);
   } on SSHStreamBudgetExhausted catch (e) {
     onDiagnostic?.call('$e — falling back to polling for this repo');
     return const WatchUnavailable();
   }
   ```
5. `command_lanes.dart:118-127` — rewrite the budget comment to include
   streams and to say that the numbers are now enforced in
   `SSHCommandExecutor.maxConcurrentStreams`, not merely asserted here.

#### 5d. Verify

```sh
flutter analyze
flutter test test/ssh_command_executor_test.dart test/ssh_error_messages_test.dart
flutter test test/remote_watch_service_test.dart test/command_lanes_test.dart
flutter test
```

**Acceptance criteria.** Budget test seen red then green; the humanizer test
covers the new arm; failing set unchanged.

**Live-host confirmation (deferred, and named as such).** The offline test
proves the counter; it does not prove the number is right. Confirming that
requires `MaxSessions 4` on a test sshd with three repos watched, and is
recorded as an open item exactly as `0022-PLAN` Phase 15 is. **Do not mark
M2 closed on the unit test alone.**

**Commit.** `git add -u && git commit --no-edit`.

---

### Phase 6 — L1 + L2

**Files.** `lib/core/ssh/native_ssh_socket.dart`,
`lib/core/ssh/ssh_error_messages.dart`.

#### 6a. L1 — do not leak the socket when `tcpNoDelay` throws

`applyTcpOptions` puts `setOption(tcpNoDelay)` deliberately outside the
best-effort `try`. If it throws — a peer that closed between `Socket.connect`
and the option is the realistic case — the exception leaves `connect()` with
the socket neither closed nor destroyed, once per attempt, and
`_autoReconnect` allows twenty.

Extract the adoption step so the failure path is reachable from a test:

```dart
  static Future<SSHSocket> connect(String host, int port, {Duration? timeout}) async {
    // ignore: close_sinks
    final socket = await Socket.connect(host, port, timeout: timeout);
    return adopt(socket);
  }

  /// Takes ownership of [socket]: applies the TCP options, and destroys it if
  /// that fails rather than leaking an open descriptor out of a throwing
  /// connect. Separate from [connect] so the failure path is testable —
  /// [connect] opens its own socket and cannot be made to fail on demand.
  @visibleForTesting
  static SSHSocket adopt(Socket socket) {
    try {
      applyTcpOptions(socket);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
    return NativeSshSocket._(socket);
  }
```

**Negative test** in `test/native_ssh_socket_test.dart`, with a fake that
records the call — `implements Socket` plus `noSuchMethod` so only the two
members under test need bodies:

```dart
class _OptionRefusingSocket implements Socket {
  bool destroyed = false;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      throw const SocketException('closed');
  @override
  void destroy() => destroyed = true;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

test('a socket whose options are refused is destroyed, not leaked', () {
  final socket = _OptionRefusingSocket();
  expect(() => NativeSshSocket.adopt(socket), throwsA(isA<SocketException>()));
  expect(socket.destroyed, isTrue, reason: 'the descriptor must not leak');
});
```

**Two-step landing.** `adopt` lands first delegating straight to
`applyTcpOptions` with no `try`. **Required observation:** the throw is
asserted correctly but `socket.destroyed` is `false`.

#### 6b. L2 — humanize `CommandLaneOverrun`

`humanizeSshError` has no arm for it, so its two-sentence developer note
(*"This is a bug in the command executor…"*) reaches the UI — the leak class
MADR 0018 was written to close.

Add above the `TimeoutException` arm:

```dart
  if (error is CommandLaneOverrun) {
    return 'A command did not finish and was abandoned. Try again.';
  }
```

**Negative test** in `test/ssh_error_messages_test.dart`:

```dart
test('a reclaimed lane slot does not leak developer text to the UI', () {
  final msg = humanizeSshError(
    const CommandLaneOverrun(ExecLane.read, Duration(seconds: 90)),
  );
  expect(msg, 'A command did not finish and was abandoned. Try again.');
  expect(msg, isNot(contains('bug in the command executor')));
});
```

**Required observation:** it fails today with the raw `toString()`.

#### 6c. Verify

```sh
flutter analyze
flutter test test/native_ssh_socket_test.dart test/ssh_error_messages_test.dart
flutter test
```

**Acceptance criteria.** Both tests seen red then green; failing set unchanged.

**Commit.** `git add -u && git commit --no-edit`.

---

### Phase 7 — P1: take the login-shell PATH capture off the connect path (closes M4)

**Finding.** MADR 0024 → P1, and M4 with it: removing the file removes the
guessable `/tmp` target.

**Files.** `lib/core/ssh/environment_probe.dart`,
`lib/core/providers/app_providers.dart`.
**Tests.** `test/environment_probe_test.dart`.

#### 7a. Negative test

```dart
test('the connect probe spawns no login shell and waits on nothing', () {
  final script = EnvironmentResolver.probeScriptForTest;
  // Up to 3 s of connect latency, in 30 forked sleeps, for a payoff the
  // hardcoded Homebrew dirs below already cover (MADR 0024 P1).
  expect(script, isNot(contains('sleep')));
  expect(script, isNot(contains('SHELL')));
  expect(script, isNot(contains('-lc')));
  // ...and no guessable temp file (MADR 0024 M4).
  expect(script, isNot(contains(r'$$')));
  // What it must still do.
  expect(script, contains('/opt/homebrew/bin'));
  expect(script, contains('command -v'));
});
```

**Run red:** four of the six expectations fail. Record all four.

#### 7b. Apply

1. **`environment_probe.dart`** — delete lines 285–294 (the `_mg_lp` temp file,
   the backgrounded `${SHELL:-sh} -lc`, the `while [ $i -lt 30 ]` busy-wait,
   the `kill`/`wait`/`cat`/`rm`) and the now-unused `lp=""`; change
   `aug="$u:$c:$lp:$PATH:..."` to `aug="$u:$c:$PATH:..."`.
2. Add a second, separately-invoked script and resolver method:
   ```dart
   /// The login shell's own PATH, probed AFTER connect rather than during it.
   /// A `zshrc` that calls `brew shellenv` — or one that blocks on the network
   /// — used to cost up to 3 s on the connect critical path and again on each
   /// of up to 20 auto-reconnect attempts, for directories the per-OS list
   /// already covers in the common case. Best-effort: returns an empty list on
   /// any failure, and the session is fully usable without it.
   Future<List<String>> probeLoginShellPath({String repoPath = '.'}) async { ... }
   ```
   with a 5 s timeout and `lane: ExecLane.read`.
3. Add a pure merge helper, so the reconciliation is unit-testable without a
   transport:
   ```dart
   /// [current] with any [additional] directories it lacks appended, order and
   /// duplicates preserved from [current]. Appended, never prepended: the
   /// per-user-before-system ordering is load-bearing (see [RemoteEnvironment.path]).
   @visibleForTesting
   static String mergeLoginShellPath(String current, List<String> additional)
   ```
4. **`app_providers.dart`** — add `_reconcileLoginShellPath(attempt, repoPath)`
   to the `Future.wait` at `:1570-1581`. It probes, merges, and — only if the
   merge changed the string and the attempt is still current — calls
   `configureEnvironment` again and republishes the environment.

#### 7c. Verify

```sh
flutter analyze
flutter test test/environment_probe_test.dart
flutter test test/connection_env_reset_test.dart test/connection_race_test.dart
flutter test
```

**Acceptance criteria.**

* 7a's four expectations failed and now pass.
* A new test pins `mergeLoginShellPath`: appends only unknown directories,
  never reorders, and never prepends (which would invert the
  user-before-system ordering that keeps a `/usr/local/bin` shim from
  shadowing the real `glab` — the `glab-wrapper-path-shadowing` failure).
* `probeScriptForTest` still resolves every binary in `kProbedBinaries`
  (existing test, unchanged).
* Failing set unchanged.

**Measurement to record** (this phase's whole point). Before and after, from a
real connect, using the timing the code already captures at
`app_providers.dart:1367`:

```
envMs before: ____ ms      envMs after: ____ ms
```

If `envMs` does not drop, **stop and prompt**: the busy-wait was not the cost
and the finding needs re-grounding.

**Commit.** `git add -u && git commit --no-edit`.

---

### Phase 8 — P2: batch same-window read commands *(requires separate approval)*

**Not authorized by approval of this plan.** It is specified so the decision
can be made on evidence, not so it can be executed.

**Finding.** MADR 0024 → P2. Every `execute()` costs two round trips before the
command starts: `_openChannel` awaits `CHANNEL_OPEN_CONFIRMATION`
(`dartssh2 3.3.0 ssh_client.dart:1663`) and `sendExec` uses `wantReply: true`
(`ssh_channel.dart:90`). Twelve mutation families at 200 ms RTT with a read cap
of 4 is ~1.2 s of pure protocol overhead after a commit.

**Depends on Phase 2.** Batching multiplies the compressed path's exposure, and
H2 must be closed first.

**Shape.** A `ReadBatcher` in front of `ExecLane.read` only: collect for a
15 ms window, cap at 8 commands, emit one `sh -c` script that runs each in
sequence and frames results as `<index> <exit> <stdout-len> <stderr-len>\n`
followed by the raw bytes; demultiplex to the individual futures. This is
`GitCatFileBatch` (`git_cat_file_batch.dart:156-157`) generalised, including
its fail-open posture.

**Constraints, all binding:**

* Reads only. Never `exclusive` (the barrier *is* the `.git/index.lock`
  guarantee) and never `sync`.
* One deadline for the batch; on overrun, fail the batch and let
  `runWithRetries` re-issue members individually.
* The byte budget becomes per-member, not per-batch, or one large read starves
  its batch-mates.
* A cancelled member cannot kill the channel its batch-mates share.

**Gate.** Off by default behind a setting; the per-command path is retained
verbatim and is what runs unless the flag is on.

**Required evidence before it is considered.** A measurement against a real
remote of the round-trip cost this claims to remove — the arithmetic above is
derived from the library source, not observed on a link. Until that exists,
this phase should not be approved.

---

## Verification

**Per phase:** the commands listed in that phase, plus

```sh
flutter analyze          # must print: No issues found!
flutter test             # compared against phase0-failing-set.txt
```

**Gate comparison, every phase.** Compare the *passing count* and the *failing
set*, never a diff of the output. The `0022-PLAN` Phase 9 deviation is the
reason: a test file that failed to compile reported one failure while ten tests
silently did not run, and a diff of the summary called it identical. The check
is:

```sh
tail -1 "$SCRATCH/phaseN-test.txt"                 # passing count must RISE by
                                                   # the number of tests added
diff "$SCRATCH/phase0-failing-set.txt" "$SCRATCH/phaseN-failing-set.txt"
```

A passing count that does not rise by exactly the tests added means a file did
not compile. **Stop and prompt.**

**Whole-plan acceptance.**

1. Every phase's negative test was observed to fail, and its verbatim failure
   text is in the execution record below.
2. `flutter analyze` clean.
3. `flutter test` failing set identical to Phase 0; passing count is baseline
   plus the number of tests added — **17** across phases 1–7 (1 + 3 + 4 + 3 + 2
   + 2 + 2).
4. The tree is clean, and every phase is one commit written by the
   `prepare-commit-msg` hook.
5. MADR 0024's status moves `proposed` → `accepted`, `docs/README.md`'s row is
   updated, and this plan's status moves to `complete` — **except** that M2
   stays open pending its live-host confirmation, stated in the row rather than
   glossed.

**Explicitly NOT claimed on completion.** M2's number (8 / 2) is unconfirmed
against a real `MaxSessions`; P2 is unexecuted; and P1's improvement is
measured on one host, not characterised across shells.

## Rollout and Rollback

**Rollout.** Phases land in order as separate commits on `master`. Nothing here
is behind a feature flag except Phase 8, which is not authorized. There is no
migration, no persisted-format change, and no public API change — every edit is
internal to `lib/core/ssh/`, `lib/core/exec/` and
`lib/core/git/remote_watch_service.dart`.

**Rollback.** Per phase, `git revert <sha>` — the phases are independent except
5→(3,4) and 8→2, so reverting a middle phase does not strand a later one unless
that dependency is listed. The two phases with observable behaviour change:

* **Phase 4** replaces the read-cap controller. If throughput regresses on a
  real link, revert that single commit; nothing else reads
  `AdaptiveReadConcurrency`.
* **Phase 7** changes when the login-shell PATH is discovered, not whether. A
  tool that resolves only via a login shell now resolves a moment after
  connect rather than during it. If that proves user-visible, the reconciliation
  can be awaited before `connected` is published — a one-line change that
  restores the old ordering without restoring the busy-wait.

**Kill switch.** None is added. A flag per fix would be nine flags guarding
nine defect fixes, which is more risk than the fixes carry.

## Execution record

*(Filled in during execution — one entry per phase: what was done, the verbatim
red-test output, the verification output rather than a summary of it, and a
dated entry for every deviation, per `AGENTS.md`. Empty until the plan is
approved.)*

### Deviation (a) — 2026-09-04 — the plan did not say *which* `flutter`

**Found.** Phase 0's gates ("`git status --short` prints nothing",
"`flutter analyze` reports `No issues found!`") both failed on an unmodified
tree: analyze reported two `unawaited_return_in_try_block` warnings
(`pinned_branches.dart:29`, `image_diff_view.dart:105`) and rewrote
`pubspec.lock`, bumping six transitive packages.

**Evidence it was pre-existing, and then that it was not a defect at all.**
Both reproduced on a pristine `git clone` of `21721ef` with no edits. But the
cause is tooling, not code: `build_macos.sh:41` pins `FLUTTER_VERSION="3.44.8"`
and vendors it into `.flutter-sdk`, while Homebrew's `flutter` on PATH is
3.47.2. The Flutter SDK pins these packages *exactly* in its own
`pubspec.yaml` — 3.44.8 wants `test_api 0.7.11` / `matcher 0.12.19` /
`meta 1.18.0` / `vector_math 2.2.0`; 3.47.2 wants 0.7.12 / 0.12.20 / 1.19.0 /
2.4.2 — which is why `flutter pub get --enforce-lockfile` reports "Unable to
satisfy `pubspec.yaml` using `pubspec.lock`" against either SDK's lock when run
under the other. It also explains the `bd93c18` (bump) / `21721ef` (downgrade)
pair in the history: the same tug-of-war, twice.

Under the pinned SDK both gates pass as the plan specifies:

```
$ .flutter-sdk/bin/flutter analyze
No issues found! (ran in 11.5s)
$ git status --short          # pubspec.lock restored to HEAD by the SDK's own pub get
(clean)
```

**Decision.** No code change. Execution rule 0 added: every `flutter` in this
plan is `.flutter-sdk/bin/flutter`. `21721ef`'s lock is correct and is left
alone. The two lints are a 3.47.2-only rule and are **not** in scope.

**Left open for the maintainer** (not actioned, not blocking): `AGENTS.md`'s
Commands section says bare `flutter analyze` / `flutter test`, which is what
led here; and `FLUTTER_VERSION` is three minors behind the machine's Flutter.
Either making `AGENTS.md` name the vendored binary, or bumping the pin to
3.47.2 and re-locking once, would end the churn. Both are dependency/tooling
policy and belong to the maintainer.

### Deviation (d) — 2026-09-04 — P1's new probe trusted its own stdout

**Found.** Phase 7's full-suite run failed
`connection_env_reset_test.dart: a superseded connect's still-running env probe
cannot reconfigure the shared executor with the old host's PATH`, with the
resolved PATH ending `…/bin:OS=Linux\nPATH=/usr/bin:/bin\nBIN=git=/usr/bin/git`.

**Evidence, and what it actually meant.** The test's fake executor answers every
command with the connect probe's canned output, which is a fixture artifact —
but it surfaced a real defect in the code this phase *added*:
`probeLoginShellPath` split raw stdout on `:` and treated every fragment as a
directory. A login shell is a hostile source: `.zshrc` files print MOTDs,
version-manager chatter and warnings onto the same stdout as the value, and
appending that to a PATH whose **ordering is load-bearing** is precisely how a
`/usr/local/bin` shim ends up shadowing the real `glab` (the
`glab-wrapper-path-shadowing` failure this repo has already had once).

**Resolution — a fix, not a fixture change.** `parseLoginShellPath` now requires
each entry to be absolute and single-line, rejects anything containing `=`, and
caps the list at 64 entries. Four tests pin it, including the exact banner text
that produced the failure. The pre-existing test passes unmodified, which is the
point: it was right.

### Deviation (c) — 2026-09-04 — the pinned A2 control law can only grow

**Found.** Before writing any code, evaluating the control law this plan pinned
in Phase 4b across the range it actually operates in:

```
limit | gradient(inflation)      -> next
  4   | 0.50 (2.00x latency) -> 4
  3   | 0.50 (2.00x latency) -> 3
  2   | 0.50 (2.00x latency) -> 2
  1   | 0.50 (2.00x latency) -> 1

Can it EVER shrink in 1..4?  NO
```

`target = limit * gradient + sqrt(limit)` is Netflix's `concurrency-limits`
formulation, where limits run to the hundreds and `sqrt(limit)` is small
relative to the limit. At a ceiling of 4 the allowance dominates, so the
controller can only ever grow — strictly worse than the band table it replaces,
which at least could shed load. This is an error in this plan, not a discovery
about the code.

**Decision (maintainer, 2026-09-04): step controller on the gradient.** The
pinned-constants table in Phase 4b is superseded by:

| symbol | value | why |
|---|---|---|
| `alpha` (EWMA) | `0.2` | unchanged — ~14 samples of memory |
| `warmupSamples` | `10` | unchanged — hold `noSampleCap` below this |
| `shrinkBelow` | `0.70` | gradient under this (>1.43x latency inflation) steps the limit **down** by 1 |
| `growAbove` | `0.90` | gradient over this (<1.11x inflation) steps the limit **up** by 1 |
| `consecutiveRequired` | `3` | a direction must hold for three samples — reuses the hysteresis the class already has, and its existing tests already pin |
| `minRttWindow` | `300` samples or `5 min` | unchanged |

`gradient = minRtt / currentRtt`, clamped to `(0, 1]`. Error-floor and `reset`
semantics are unchanged. MADR 0024 gains Amendment A2.1.

**Coverage note.** Removing `bandForRtt` removes the only thing five of the
existing eleven tests assert (`band thresholds map RTT to cap`, `band
boundaries are inclusive`, `bandForRtt never exceeds the given ceiling`, `mixed
intermediate band settles at 3`, `RTT band 2 wins over a high error floor`).
Those are deleted rather than rewritten because the mechanism they cover is
deliberately gone; no *live* behaviour loses coverage. The remaining six —
warm-up, hysteresis, error floor, floor recovery, and both `reset` cases — are
rewritten against `onReadSample`.

### Deviation (b) — 2026-09-04 — A1 could not reach its target alone

**Found.** Phase 3a's timing gate (`< 50 ms` for a 20,000-event burst) still
failed after the A1 fix landed: **522 ms → 333 ms**, not the ~1 ms the isolated
benchmark predicted.

**Evidence.** `Coalescer.signal()` (`lib/core/git/coalescer.dart:48-73`) does a
`DateTime.now()` + `Timer.cancel()` + `new Timer()` per event. Measured over
the same 20,000 events: **295 ms**, against **9 ms** for a version that only
reschedules when the target fire time actually moves. `coalescer.dart` is
untouched by this work (`git status` showed only the two Phase 3 files) and
dates to the initial commit — genuinely pre-existing, and absent from MADR 0024.

**Decision (maintainer, 2026-09-04): fix it now, inside Phase 3.** Same burst,
same hot path, same jank; fixing the split and shipping the larger cost would
leave A1's claim unearned. Phase 3's file list gains
`lib/core/git/coalescer.dart` and `test/coalescer_test.dart`. Coalescing
semantics are load-bearing for MADR 0020, so the guard must never fire *late* —
only reschedule-on-earlier plus a tolerance on later — and it gets its own
negative test. MADR 0024 gains Amendment A1.1.

### Two incidental findings from Phase 3, recorded so they are not re-derived

* **Today's record split is correct.** All 60 boundary-straddling records
  arrive intact. A1 is purely a performance defect behind a correct
  implementation, exactly as the MADR states.
* **The A1 test hung because of H3.** With nothing listening to the watcher's
  stderr, the fake handle's `cancel()` awaited `close()` on a
  never-listened `StreamController`, whose future never completes. Wiring the
  H3 listener unblocked it. Two earlier hypotheses (an `onCancel`/`close()`
  deadlock; a `containsAll` mismatch pathology) were each reproduced
  standalone and **refuted** before the real cause was instrumented.

| Phase | Status | Commit | Red-test observed | Notes |
|---|---|---|---|---|
| 0 | complete | `3aa100a` | n/a | `+3398 ~2`, 0 failing, analyzer clean. Deviation (a). |
| 1 | complete | `17b64d4` | `isAttachSettled` `Expected: false / Actual: <true>`; and the command threw `SSHTransportNotReady` from `_run:731` instead of waiting | +2 tests |
| 2 | complete | `c955f47` | both bombs: `Expected: throws SSHOutputExceeded / Actual: emitted […]`, on-isolate and off-isolate | +4 tests. Fixture corrected first: zeroes compress ~1000:1, so 16 MiB of them is *under* the offload threshold — an incompressible prefix is needed to exercise the isolate path. |
| 3 | complete | `afb1cad` | timing `Expected: <50 / Actual: <522>`; stderr `Actual: []`; probe `Expected: eventDriven / Actual: polling` | +7 tests. Deviation (b) — coalescer folded in. |
| 4 | complete | `87fa9fa` | `Expected: <4> / Actual: <2>` for a slow-but-unqueued link | net **−2** tests (5 band-table tests deleted, 3 added). Deviation (c). |
| 5 | complete | `d10a334` | 9th stream opened: `Expected: throws SSHStreamBudgetExhausted / Actual: Future<CommandStreamHandle>` | +5 tests (3 budget, 2 humanizer). L2 landed here — its test shares the file. **M2's number is still unconfirmed against a live host.** |
| 6 | complete | `993996d` | `socket.destroyed` `Expected: true / Actual: <false>` | +1 test |
| 7 | complete | `e48e5ea` | probe script still contained `sleep`/`SHELL`/`$$`; merge returned its input unchanged | +9 tests. Deviation (d). |
| 8 | **not executed** | — | — | Requires separate approval, and a live-host measurement before it should be approved at all. |

### Result

`21721ef` → `e48e5ea`, twelve commits, **nothing pushed**.

* Suite: **3398 → 3424 passing, 2 skipped, 0 failing** at every phase gate.
  Net **+26** tests; each phase's delta matched its added tests exactly, which
  is what would have caught a file that silently failed to compile (it did, in
  Phase 4 — `noteLinkRtt` survived in `ssh_command_executor_test.dart` and the
  gate reported it as a load failure rather than letting 38 tests vanish).
* `.flutter-sdk/bin/flutter analyze`: `No issues found!` at every phase.
* Every fix was observed red first. The verbatim failures are in the table.

### Measurements

| what | before | after |
|---|---|---|
| 20k-event watcher burst, UI isolate (A1 + A1.1) | 522 ms | <50 ms (test bar); split alone 189 ms → ~1 ms, coalescer 295 ms → 9 ms |
| `Coalescer.signal()` x20000 | 295 ms | 9 ms |
| connect-path login-shell prelude (P1) | 140 ms | 10 ms |

The P1 figure is the host-side shell cost measured locally against a light
`/bin/bash` login shell — it is the **floor**, not the ceiling: the removed
busy-wait caps at 3 s, a heavy `zsh` (nvm/rbenv/`brew shellenv`) approaches it,
and it was re-paid on each of up to 20 auto-reconnect attempts. The plan asked
for an end-to-end `envMs` from a real connect; that needs a live remote host and
was **not** performed.

### Also observed, not actioned

* **`local_command_executor_test.dart: activityIdle: stderr pulses past the idle
  budget still complete` is load-flaky.** It failed once during Phase 3's
  full-suite run and passed in isolation twice and on re-run. It spawns a real
  `perl` process that must emit for 0.9 s without a 300 ms gap, so a loaded
  machine can starve it. It touches nothing this plan changed and was green at
  baseline. Worth a deflake, and out of scope here.
* **`AGENTS.md` says bare `flutter analyze` / `flutter test`**, which is what
  produced deviation (a). Naming `.flutter-sdk/bin/flutter`, or bumping
  `FLUTTER_VERSION` from 3.44.8 to the machine's 3.47.2 and re-locking once,
  would end the `pubspec.lock` churn behind `bd93c18`/`21721ef`.
