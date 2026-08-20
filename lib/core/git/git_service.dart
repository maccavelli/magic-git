import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../exec/operation_activity.dart';
import '../forge/forge.dart';
import '../ssh/shell_escaper.dart';
import '../ssh/ssh_command_executor.dart';
import '../undo/undo_types.dart';
import '../utils/git_porcelain_parser.dart';
import 'branch_comparison.dart';
import 'git_cat_file_batch.dart';
import 'log_search.dart';
import 'repo_tree.dart';

/// How `git pull` integrates upstream work.
enum PullMode { ffOnly, rebase, merge }

/// How aggressively `git push` overwrites the remote.
enum PushForce { none, withLease, force }

/// The scope a `git reset` moves: HEAD only, HEAD + index, or everything.
enum ResetMode { soft, mixed, hard }

/// How `git merge` integrates a branch into the current one.
enum MergeMode { normal, noFf, ffOnly, squash }

/// A git operation left mid-flight — waiting for the user to continue (resolve +
/// commit) or abort — detected from the state files under the git dir.
enum PendingOp { none, merge, cherryPick, revert, rebase }

/// One step in an interactive rebase's todo list.
///
/// No `reword`: [rebaseInteractive] runs headlessly with `GIT_EDITOR=true` (to
/// accept squashed-commit messages non-interactively), which also forces
/// `reword` to accept the message unchanged — there is no way to actually
/// prompt for a new one over this transport, so it would silently do nothing.
enum RebaseAction { pick, squash, fixup, drop }

/// A single line of an interactive-rebase plan: what to do with [hash].
class RebaseStep {
  final RebaseAction action;
  final String hash;
  const RebaseStep(this.action, this.hash);
}

/// One line of `git blame` output: the commit that last touched a source line.
class BlameLine {
  final String hash; // Commit that introduced/last-changed this line
  final String author;
  final String date; // Author date (ISO 8601)
  final String summary; // Commit subject
  final int lineNumber; // 1-based line number in the final file
  final String content; // The source line text
  const BlameLine({
    required this.hash,
    required this.author,
    required this.date,
    required this.summary,
    required this.lineNumber,
    required this.content,
  });
}

/// Thrown when a remote git command exits non-zero. Carries the raw result so
/// callers can distinguish failure modes (stderr text, exit code) rather than
/// collapsing everything into one opaque error.
class GitException implements Exception {
  final String message;
  final SSHCommandResult result;

  const GitException(this.message, this.result);

  // ---- Failure classification -------------------------------------------
  //
  // The one place git's English error prose is matched. UIs branch on these
  // to escalate (offer force, offer remove-the-worktree) instead of
  // dead-ending on the raw message; a wording change in a future git breaks
  // one line here, not a scattering of string literals.

  /// `git branch -d/-D` refused because a worktree has the branch checked
  /// out (there is no `--ignore-other-worktrees` for branch deletion — the
  /// worktree must be removed first).
  bool get branchHeldByWorktree =>
      result.stderr.contains('used by worktree at');

  /// `git branch -d` refused an unmerged branch; `-D` overrides.
  bool get branchNotFullyMerged => result.stderr.contains('not fully merged');

  /// `git worktree remove` refused a dirty worktree; one `--force` overrides.
  bool get worktreeDirty =>
      result.stderr.contains('contains modified or untracked files');

  /// `git worktree remove`/`move` refused a locked worktree; remove needs
  /// `--force --force`, move has no override.
  bool get worktreeLocked => result.stderr.contains('locked working tree');

  @override
  String toString() =>
      'GitException: $message (exit ${result.exitCode})\n${result.stderr}';
}

/// The stash list changed between the UI rendering it and the user acting:
/// the positional `stash@{n}` the user aimed at is no longer the entry they
/// saw, so the operation refused to run and NOTHING was modified. Callers
/// refresh the list and let the user re-aim. See [GitStash.oid].
class StashStaleException implements Exception {
  const StashStaleException();

  @override
  String toString() =>
      'The stash list changed before the action could run — nothing was '
      'modified.';
}

/// Parsed `git count-objects -vH` — the repo's object-store footprint, for
/// the dashboard. Sizes are git's own human-readable strings.
class RepoFootprint {
  final int looseObjects;
  final String looseSize;
  final int inPackObjects;
  final int packs;
  final String packSize;
  final String? garbageSize;

  const RepoFootprint({
    required this.looseObjects,
    required this.looseSize,
    required this.inPackObjects,
    required this.packs,
    required this.packSize,
    this.garbageSize,
  });

  /// Many loose objects (or several packs) mean `git gc` would shrink and
  /// speed up the store — the threshold mirrors git's own auto-gc default.
  bool get wouldBenefitFromGc => looseObjects > 6700 || packs > 50;
}

/// A branch, remote-tracking ref, or tag, from `git for-each-ref`.
class GitRef {
  final String name; // Full refname, e.g. refs/heads/main
  final String oid; // Object the ref points at (tag object for annotated tags)
  final bool isHead; // True for the currently checked-out branch
  final String? upstream; // Short upstream name, if tracking
  final String subject; // Tip commit / tag subject
  final String? peeledOid; // For annotated tags: the underlying commit

  /// Absolute path of the worktree this branch is checked out in, or null if
  /// it isn't checked out anywhere. From `%(worktreepath)`.
  ///
  /// Note git's own documentation is wrong about this field: it claims the path
  /// is only reported for *linked* worktrees, but it is in fact populated for
  /// the main and current worktree too (verified against git 2.55). So a
  /// non-null value does NOT by itself mean "checked out somewhere else" —
  /// compare against the current worktree's toplevel ([RepoLayout.toplevel])
  /// to decide that. [isHead] remains the test for "checked out *here*".
  ///
  /// The path may also point at a worktree whose directory has been deleted
  /// (git still reports it until `worktree prune` runs), so callers must not
  /// assume it exists on disk.
  final String? worktreePath;

  /// Commits this branch has that its upstream doesn't / vice versa, from
  /// `%(upstream:track)`. Both zero when in sync, untracked, or when the
  /// upstream is [upstreamGone]. Only meaningful for local branches.
  final int ahead;
  final int behind;

  /// The configured upstream no longer exists (`[gone]`) — its remote branch
  /// was deleted and a pruning fetch removed the tracking ref. The classic
  /// sign of a stale local branch left behind by a merged PR.
  final bool upstreamGone;

  /// When this ref was created, as unix epoch seconds, from
  /// `%(creatordate:unix)`. For an annotated tag this is the tagger date; for
  /// a lightweight tag (which stores no date of its own) git resolves it to
  /// the pointed-at commit's committer date — verified against real git, so
  /// both kinds sort together chronologically. Null when the remote git
  /// echoed the atom back (pre-2.7) or the field is missing.
  final int? creatorDate;

  /// Tip commit author metadata. Unlike [creatorDate] (committer/tagger
  /// activity), these fields are attribution only and may be absent when the
  /// remote Git does not support the corresponding format atom.
  final int? authorDate;
  final String? authorName;
  final String? authorEmail;

  const GitRef({
    required this.name,
    required this.oid,
    required this.isHead,
    this.upstream,
    required this.subject,
    this.peeledOid,
    this.worktreePath,
    this.ahead = 0,
    this.behind = 0,
    this.upstreamGone = false,
    this.creatorDate,
    this.authorDate,
    this.authorName,
    this.authorEmail,
  });

  bool get isRemote => name.startsWith('refs/remotes/');
  bool get isTag => name.startsWith('refs/tags/');
  bool get isLocalBranch => name.startsWith('refs/heads/');

  /// Checked out in a worktree OTHER than the current one — the one canonical
  /// spelling of this test. `%(worktreepath)` is also set for the *current*
  /// worktree (git's own docs get this wrong — see [worktreePath]), so
  /// [isHead] is what excludes "checked out here". git refuses both checkout
  /// and delete for such a branch, which is why every UI branches on it.
  bool get isCheckedOutElsewhere =>
      isLocalBranch && !isHead && worktreePath != null;

  /// [worktreePath] when [isCheckedOutElsewhere], else null — the nullable
  /// form the UIs actually switch on.
  String? get elsewhereWorktreePath =>
      isCheckedOutElsewhere ? worktreePath : null;

  /// The commit this ref decorates — the peeled commit for annotated tags,
  /// otherwise the object itself.
  String get commitOid => peeledOid ?? oid;

  String get shortName => name
      .replaceFirst('refs/heads/', '')
      .replaceFirst('refs/remotes/', '')
      .replaceFirst('refs/tags/', '');
}

/// Where a repository's git data actually lives, from one `git rev-parse`.
///
/// The only correct test for "am I in a linked worktree" is
/// [isLinkedWorktree] — `gitDir != gitCommonDir`. Do NOT test whether `.git` is
/// a file: submodules use a gitfile too, and for a submodule these two dirs are
/// equal.
class RepoLayout {
  /// The working-tree root (`--show-toplevel`), absolute and symlink-resolved.
  final String toplevel;

  /// This worktree's private git dir. For a linked worktree that is
  /// `<main>/.git/worktrees/<id>`; for the main worktree it equals
  /// [gitCommonDir].
  final String gitDir;

  /// The shared git dir — always the main repository's `.git`. Holds the
  /// objects, the shared refs, and every worktree's admin directory.
  final String gitCommonDir;

  const RepoLayout({
    required this.toplevel,
    required this.gitDir,
    required this.gitCommonDir,
  });

  bool get isLinkedWorktree => gitDir != gitCommonDir;

  /// A submodule's git dir lives under the superproject's `.git/modules/…`.
  /// Unlike a linked worktree, its git dir and common dir are the *same*, so
  /// this is the only thing distinguishing the two cases.
  bool get isSubmodule =>
      !isLinkedWorktree && gitDir.contains('/.git/modules/');

  /// The main repository's working-tree root — the parent of [gitCommonDir].
  ///
  /// Only meaningful for a conventional `<repo>/.git` layout. It is null for a
  /// bare repo, `--separate-git-dir`, or a `$GIT_DIR` override, where the
  /// common dir is not a `.git` inside the main worktree. Callers that need
  /// this to be exact should read the first record of
  /// [GitService.gitWorktrees] instead, which git documents as always being the
  /// main worktree.
  String? get mainWorktreePath {
    if (!gitCommonDir.endsWith('/.git')) return null;
    return gitCommonDir.substring(0, gitCommonDir.length - '/.git'.length);
  }
}

/// A worktree from `git worktree list --porcelain`.
///
/// Named `GitWorktree`, not `Worktree`, because "worktree" already means *the
/// working tree* throughout this codebase (`WorktreeEditStamps`,
/// `git restore --worktree`). This type is the `git worktree` concept: one of
/// several checkouts sharing a single repository.
class GitWorktree {
  /// Absolute, symlink-resolved path (git realpath's these, so it compares
  /// safely against `rev-parse --path-format=absolute` output but may not
  /// string-match a path the user typed).
  final String path;

  /// Tip commit, or null when HEAD is unborn — see [isUnborn].
  final String? headOid;

  /// Full refname (`refs/heads/foo`), or null when detached or bare.
  final String? branch;

  final bool isDetached;
  final bool isBare;

  /// True for the main worktree, which git always lists first. It can never be
  /// removed or pruned.
  final bool isMain;

  final bool isLocked;

  /// Why it's locked. Empty string when locked without a reason — which is why
  /// this can't double as the locked flag; use [isLocked].
  final String? lockReason;

  /// Why git considers this prunable (e.g. "gitdir file points to non-existent
  /// location" — i.e. someone deleted the directory). Null when healthy. Never
  /// reported for the main worktree.
  final String? prunableReason;

  const GitWorktree({
    required this.path,
    this.headOid,
    this.branch,
    this.isDetached = false,
    this.isBare = false,
    this.isMain = false,
    this.isLocked = false,
    this.lockReason,
    this.prunableReason,
  });

  /// A worktree created with `--orphan`, or any repo with no commits yet: git
  /// reports an all-zero HEAD. Note it still emits a `branch` line in this
  /// case, so [branch] is non-null and [isDetached] is false — the null OID is
  /// the only signal. A bare entry also has no HEAD line, which is why this
  /// must exclude [isBare] rather than test [headOid] alone.
  bool get isUnborn => !isBare && headOid == null;

  /// The directory name, which is what the UI labels a worktree with. Full
  /// paths are too long to scan and branch names alone are ambiguous.
  String get name {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  /// Short branch name for display, or a short OID when detached.
  String get branchLabel {
    if (branch != null) return branch!.replaceFirst('refs/heads/', '');
    if (isBare) return 'bare';
    final oid = headOid;
    if (oid == null) return 'unborn';
    return '(detached ${oid.substring(0, oid.length < 7 ? oid.length : 7)})';
  }

  /// The directory is gone (or its admin dir is corrupt), so the entry is a
  /// tombstone: offer Prune (forget it) or Repair (point it at the moved dir).
  bool get isPrunable => prunableReason != null;
}

/// The all-zero object id git reports for an unborn HEAD.
const String _nullOid = '0000000000000000000000000000000000000000';

/// Parses `git worktree list --porcelain -z`.
///
/// Records are separated by an empty field (`\0\0`); within a record each line
/// is a `\0`-terminated field whose first word is the key. The first field is
/// always `worktree <path>`, and the first *record* is always the main
/// worktree. Verified against git 2.55 output — the shapes are:
///
/// ```
///   worktree PATH / bare                                 (bare main repo)
///   worktree PATH / HEAD OID   / branch refs/heads/x     (normal)
///   worktree PATH / HEAD OID   / detached                (detached)
///   worktree PATH / HEAD 000…0 / branch refs/heads/x     (unborn / --orphan)
/// ```
/// …plus an optional trailing `locked [reason]` and/or `prunable REASON`.
///
/// Note the unborn shape: `--orphan` still emits a `branch` line, so the
/// all-zero OID is the *only* signal that HEAD is unborn.
///
/// `-z` is required, not a nicety: git does not quote paths in the newline form
/// (only lock reasons), so a path containing a newline silently corrupts it.
List<GitWorktree> parseWorktreeList(String raw) {
  final worktrees = <GitWorktree>[];
  // Escapes, not literal NUL bytes: raw control bytes in a source file make
  // it register as binary to grep, which is already a papercut in this file.
  // Deliberately no `.trim()` on fields — a trailing space is legal in a path.
  const nul = '\u0000';
  for (final record in raw.split('$nul$nul')) {
    final fields = record.split(nul).where((f) => f.isNotEmpty).toList();
    if (fields.isEmpty) continue;

    String? path;
    String? headOid;
    String? branch;
    var isDetached = false;
    var isBare = false;
    var isLocked = false;
    String? lockReason;
    String? prunableReason;

    for (final field in fields) {
      final sp = field.indexOf(' ');
      final key = sp == -1 ? field : field.substring(0, sp);
      final value = sp == -1 ? '' : field.substring(sp + 1);
      switch (key) {
        case 'worktree':
          path = value;
        case 'HEAD':
          // An unborn HEAD is reported as the null OID, not omitted.
          headOid = value == _nullOid ? null : value;
        case 'branch':
          branch = value;
        case 'detached':
          isDetached = true;
        case 'bare':
          isBare = true;
        case 'locked':
          // `locked` alone (no reason) is a bare flag; the reason is optional.
          isLocked = true;
          lockReason = value;
        case 'prunable':
          // Always carries a reason when emitted.
          prunableReason = value;
      }
    }
    if (path == null || path.isEmpty) continue;

    worktrees.add(
      GitWorktree(
        path: path,
        headOid: headOid,
        branch: branch,
        isDetached: isDetached,
        isBare: isBare,
        // Documented invariant: git always lists the main worktree first.
        isMain: worktrees.isEmpty,
        isLocked: isLocked,
        lockReason: lockReason,
        prunableReason: prunableReason,
      ),
    );
  }
  return worktrees;
}

/// An entry from `git stash list`.
class GitStash {
  final int index;

  /// The stash commit's OID — the entry's STABLE identity. [index] is merely
  /// positional: every push or drop re-numbers all entries, so anything that
  /// acts on a stash later than the render must aim by [oid] (apply, show) or
  /// verify against it before acting (pop, drop — see [StashStaleException]).
  final String oid;

  final String branch; // Branch the stash was made on
  final String message;
  final String relativeDate; // e.g. "2 hours ago"; '' when unknown

  const GitStash({
    required this.index,
    required this.oid,
    required this.branch,
    required this.message,
    this.relativeDate = '',
  });

  String get ref => 'stash@{$index}';

  /// The human note without git's `WIP on <branch>: <sha>` / `On <branch>:`
  /// boilerplate — the part worth reading at a glance.
  String get subject {
    // 7..64 hex, not 7..40: a SHA-256 repo's abbreviated stash oid can run up
    // to 64 chars, and a {7,40} bound would stop consuming mid-hash and leak
    // the hash's tail into the displayed subject.
    final m = RegExp(
      r'^(?:WIP on|On) [^:]+:\s*(?:[0-9a-f]{7,64}\s+)?(.*)$',
    ).firstMatch(message);
    final s = m?.group(1)?.trim();
    return (s == null || s.isEmpty) ? message : s;
  }
}

/// Strips any stray ASCII Unit/Record Separator bytes (0x1F/0x1E) from a
/// parsed field's value.
///
/// [GitService.fieldSep]/[recordSep] are ordinary bytes, so a commit subject
/// containing one literally (adversarial or otherwise) can already cause a
/// record/field to be mis-split before this ever runs — that residual risk
/// isn't something a post-hoc string clean can undo, and a fully robust fix
/// (e.g. a length-prefixed format) would be a much larger change than this
/// bug warrants. What this *does* guard is display: it keeps any such stray
/// separator byte that survives into a field's value from leaking further
/// into the UI as a raw, invisible control character.
String _stripSeps(String s) =>
    s.contains('\u0000') || s.contains('\u001e') || s.contains('\u001f')
    ? s
          .replaceAll('\u0000', '')
          .replaceAll('\u001e', '')
          .replaceAll('\u001f', '')
    : s;

/// Parses `git log` output (field/record separated). Top-level so it can run in
/// a background isolate via `Isolate.run`.
List<GitCommit> parseGitLog(String raw) {
  final commits = <GitCommit>[];
  for (final record in raw.split(GitService.recordSep)) {
    final trimmed = record.replaceFirst(RegExp(r'^\n'), '');
    if (trimmed.trim().isEmpty) continue;
    final f = trimmed.split(GitService.fieldSep);
    // A record with fewer than 7 fields is truncated/malformed (e.g. a
    // transport hiccup mid-stream). Deliberately skip it and keep parsing the
    // rest of the log rather than aborting the whole history render; this is a
    // fire-and-forget top-level parse with no warnings channel to surface it.
    if (f.length < 7) continue;
    final subject = f.length == 7
        ? f[6]
        : f.sublist(6).join(GitService.fieldSep);
    commits.add(
      GitCommit(
        hash: f[0],
        shortHash: f[1],
        authorName: f[2],
        authorEmail: f[3],
        date: f[4],
        parents: f[5].isEmpty ? const [] : f[5].split(' '),
        subject: _stripSeps(subject),
      ),
    );
  }
  return commits;
}

/// Parses the file-history walk: [parseGitLog]'s wire format interleaved with
/// `--name-status` records. Top-level so it can run in a background isolate.
///
/// Shape (single pathspec, so one status line per commit): each commit emits
/// `<fields><recordSep>` followed by a blank line and its status line
/// (`M\t<path>`, `A\t<path>`, `R<score>\t<old>\t<new>`, …). Splitting on
/// [GitService.recordSep] therefore yields chunks in which the status lines
/// belong to the PREVIOUS chunk's commit and the fieldSep-bearing line opens
/// the next one.
List<FileHistoryEntry> parseFileHistory(String raw) {
  final entries = <FileHistoryEntry>[];
  for (final chunk in raw.split(GitService.recordSep)) {
    String? fieldsLine;
    String? statusLine;
    for (final line in chunk.split('\n')) {
      if (line.contains(GitService.fieldSep)) {
        fieldsLine = line;
      } else if (statusLine == null && line.trim().isNotEmpty) {
        // First status line only: the walk has exactly one pathspec, so any
        // further lines are unexpected noise, never a better answer.
        statusLine = line;
      }
    }
    if (statusLine != null && entries.isNotEmpty) {
      final path = _pathFromNameStatus(statusLine);
      if (path != null) {
        final last = entries.last;
        entries[entries.length - 1] = FileHistoryEntry(
          commit: last.commit,
          pathAtCommit: path,
        );
      }
    }
    if (fieldsLine != null) {
      final f = fieldsLine.split(GitService.fieldSep);
      if (f.length < 7) continue; // truncated/malformed — same posture as log
      final subject = f.length == 7
          ? f[6]
          : f.sublist(6).join(GitService.fieldSep);
      entries.add(
        FileHistoryEntry(
          commit: GitCommit(
            hash: f[0],
            shortHash: f[1],
            authorName: f[2],
            authorEmail: f[3],
            date: f[4],
            parents: f[5].isEmpty ? const [] : f[5].split(' '),
            subject: _stripSeps(subject),
          ),
        ),
      );
    }
  }
  return entries;
}

/// The path a `--name-status` line assigns the file **at that commit** — the
/// sole path for M/A/D records, the NEW name for an R/C record (old\tnew).
/// Null for a line that doesn't parse as a status record.
String? _pathFromNameStatus(String line) {
  final parts = line.split('\t');
  if (parts.length < 2) return null;
  return _unquoteGitPath(parts.last);
}

/// Undoes git's C-style path quoting (`core.quotePath` handles most of it via
/// `-c core.quotepath=false`, but paths containing quotes/backslashes/control
/// bytes are quoted regardless). A path not wrapped in double quotes passes
/// through untouched.
///
/// Escapes name raw BYTES (an octal pair like `\303\251` is one UTF-8 é), so
/// the unquote accumulates bytes and decodes once at the end — decoding each
/// escape as a code point would mangle every non-ASCII name into mojibake.
String _unquoteGitPath(String path) {
  if (path.length < 2 || !path.startsWith('"') || !path.endsWith('"')) {
    return path;
  }
  final inner = path.substring(1, path.length - 1);
  final bytes = <int>[];
  for (var i = 0; i < inner.length; i++) {
    final ch = inner[i];
    if (ch != r'\' || i + 1 >= inner.length) {
      bytes.addAll(utf8.encode(ch));
      continue;
    }
    final next = inner[++i];
    switch (next) {
      case 'n':
        bytes.add(0x0A);
      case 't':
        bytes.add(0x09);
      case 'r':
        bytes.add(0x0D);
      case '"':
      case r'\':
        bytes.addAll(utf8.encode(next));
      default:
        // Octal escape (\NNN) — up to three digits, one raw byte.
        if (next.codeUnitAt(0) >= 0x30 && next.codeUnitAt(0) <= 0x37) {
          var value = next.codeUnitAt(0) - 0x30;
          var digits = 1;
          while (digits < 3 && i + 1 < inner.length) {
            final c = inner.codeUnitAt(i + 1);
            if (c < 0x30 || c > 0x37) break;
            value = value * 8 + (c - 0x30);
            i++;
            digits++;
          }
          bytes.add(value);
        } else {
          bytes.addAll(utf8.encode(next)); // unknown escape — keep the char
        }
    }
  }
  return const Utf8Decoder(allowMalformed: true).convert(bytes);
}

/// Parses `git reflog` output (field/record separated, same wire format as
/// [parseGitLog]). Top-level so it can run in a background isolate.
List<ReflogEntry> parseReflog(String raw) {
  final entries = <ReflogEntry>[];
  for (final record in raw.split(GitService.recordSep)) {
    final trimmed = record.replaceFirst(RegExp(r'^\n'), '');
    if (trimmed.trim().isEmpty) continue;
    final f = trimmed.split(GitService.fieldSep);
    if (f.length < 5) continue; // truncated/malformed — skip, keep parsing
    // %gs is `<action>: <detail>` ("checkout: moving from a to b",
    // "commit (amend): subject", "reset: moving to HEAD~1"). Split at the
    // first colon; an unexpected shape becomes all-detail with no action.
    final gs = _stripSeps(f[3]);
    final colon = gs.indexOf(': ');
    final subject = f.length == 5
        ? f[4]
        : f.sublist(4).join(GitService.fieldSep);
    entries.add(
      ReflogEntry(
        hash: f[0],
        shortHash: f[1],
        selector: _stripSeps(f[2]),
        action: colon < 0 ? '' : gs.substring(0, colon),
        detail: colon < 0 ? gs : gs.substring(colon + 2),
        subject: _stripSeps(subject),
      ),
    );
  }
  return entries;
}

/// Parses `git blame --line-porcelain` output into one [BlameLine] per source
/// line. Top-level so it can run in a background isolate for large files. Each
/// line block is a header row (`<sha> <orig> <final> [<num>]`) followed by
/// key/value headers and a tab-prefixed content line.
List<BlameLine> parseBlame(String raw) {
  final lines = <BlameLine>[];
  // 40 hex for SHA-1 repos, 64 for SHA-256 — anchored on the trailing space so
  // a SHA-256 header still matches (otherwise every blame line parses as empty).
  final headerRe = RegExp(r'^([0-9a-f]{40,64}) \d+ (\d+)');
  String hash = '';
  int lineNumber = 0;
  String author = '';
  String summary = '';
  int authorTime = 0;

  for (final line in raw.split('\n')) {
    final m = headerRe.firstMatch(line);
    if (m != null) {
      hash = m.group(1)!;
      lineNumber = int.tryParse(m.group(2)!) ?? 0;
      continue;
    }
    if (line.startsWith('author ')) {
      author = line.substring(7);
    } else if (line.startsWith('author-time ')) {
      authorTime = int.tryParse(line.substring(12).trim()) ?? 0;
    } else if (line.startsWith('summary ')) {
      summary = line.substring(8);
    } else if (line.startsWith('\t')) {
      // The content line closes the current block.
      final date = authorTime == 0
          ? ''
          : DateTime.fromMillisecondsSinceEpoch(
              authorTime * 1000,
              isUtc: true,
            ).toIso8601String().substring(0, 10);
      lines.add(
        BlameLine(
          hash: hash,
          author: author,
          date: date,
          summary: summary,
          lineNumber: lineNumber,
          content: line.substring(1),
        ),
      );
    }
  }
  return lines;
}

/// Splits NUL-delimited `ls-files -z` output into non-empty path entries.
/// Top-level so it can run in a background isolate for very large repos.
/// The remote the app targets when several are configured: `origin` when
/// present, else the first listed. One definition, so push buttons, tag
/// badges, and [remoteTagsProvider] can never disagree about which remote
/// they mean. Callers handle the no-remotes case themselves.
String defaultRemote(List<String> remotes) =>
    remotes.contains('origin') ? 'origin' : remotes.first;

List<String> splitNulPaths(String raw) =>
    raw.split('\u0000').where((s) => s.isNotEmpty).toList();

/// Groups refs by the commit they decorate (peeled for annotated tags), so a
/// history view can look up all labels for a commit hash in O(1). Within each
/// commit, order is deterministic: HEAD, local branches, remote branches, tags.
Map<String, List<GitRef>> refsByCommit(List<GitRef> refs) {
  final map = <String, List<GitRef>>{};
  for (final ref in refs) {
    (map[ref.commitOid] ??= []).add(ref);
  }
  int rank(GitRef r) {
    if (r.isHead) return 0;
    if (r.isLocalBranch) return 1;
    if (r.isRemote) return 2;
    return 3; // tag
  }

  for (final list in map.values) {
    list.sort((a, b) => rank(a).compareTo(rank(b)));
  }
  return map;
}

/// A single commit, from `git log`.
class GitCommit {
  final String hash;
  final String shortHash;
  final String authorName;
  final String authorEmail;
  final String date; // ISO 8601 (author date)
  final List<String> parents;
  final String subject;

  const GitCommit({
    required this.hash,
    required this.shortHash,
    required this.authorName,
    required this.authorEmail,
    required this.date,
    required this.parents,
    required this.subject,
  });

  bool get isMerge => parents.length > 1;
}

/// One row of a single file's history: the commit, plus the path the file bore
/// **in that commit**. `--follow` walks through renames, so commits below a
/// rename touched the file under its old name — and a diff scoped to the
/// current name comes back empty for them. The per-commit path is what lets
/// the file-history view scope each commit's diff to the name that commit
/// actually used.
class FileHistoryEntry {
  final GitCommit commit;

  /// Repo-relative path of the file as of [commit], from the walk's
  /// `--name-status` output (the new name for a rename record). Null when the
  /// status record was missing/unparseable — callers fall back to the queried
  /// path, which is the pre-fix behavior.
  final String? pathAtCommit;

  const FileHistoryEntry({required this.commit, this.pathAtCommit});
}

/// The combined result of [GitService.status], [GitService.refs], and
/// [GitService.pendingOp] — see [GitService._snapshot] for why these three are
/// fetched together in one round trip.
class RepoSnapshot {
  final GitStatus status;
  final List<GitRef> refs;
  final PendingOp pendingOp;
  final List<String> refParseWarnings;

  /// Names of the repo's *configured* remotes (`git remote`), e.g.
  /// `['origin']`. This — not [refs] — is the truth for "does this repo have
  /// a remote": a freshly created or cloned EMPTY repository has a perfectly
  /// wired `origin` but zero remote-tracking refs, and every UI gate that
  /// tested `refs.any(isRemote)` falsely reported "No remote detected" for
  /// exactly the repos the create/clone flows had just set up correctly.
  final List<String> remotes;

  const RepoSnapshot({
    required this.status,
    required this.refs,
    required this.pendingOp,
    this.remotes = const [],
    this.refParseWarnings = const [],
  });
}

/// Valid refs plus non-fatal malformed-row diagnostics from the same snapshot.
class RefsResult {
  final List<GitRef> refs;
  final List<String> parseWarnings;

  const RefsResult(this.refs, this.parseWarnings);
}

/// One `git reflog` entry: where a ref (HEAD) pointed and why it moved.
/// Recovery actions always use [hash] — reflog indices shift with every new
/// entry, so a stored `HEAD@{n}` would go stale immediately.
class ReflogEntry {
  final String hash;
  final String shortHash;

  /// Display selector, e.g. `HEAD@{2 minutes ago}` (`%gd` under
  /// `--date=relative`).
  final String selector;

  /// The reflog action verb from `%gs` — `commit`, `checkout`, `reset`,
  /// `rebase (finish)`, `pull`, … Empty when the message had no `<action>: `
  /// prefix.
  final String action;

  /// The rest of the reflog message ("moving from main to feature").
  final String detail;

  /// The commit's own subject line — what the state at [hash] looks like.
  final String subject;

  const ReflogEntry({
    required this.hash,
    required this.shortHash,
    required this.selector,
    required this.action,
    required this.detail,
    required this.subject,
  });
}

/// One anchored pre-destroy snapshot under `refs/magic-git/snapshots/` —
/// the Recovery sheet's second section.
class SnapshotRef {
  final String refName;
  final String oid;

  /// Flavor A snapshots carry `stash create`'s own subject ("WIP on main:
  /// …"); flavor B ones are created with the literal subject
  /// `magic-git snapshot`.
  final String subject;
  final String relativeDate;

  const SnapshotRef({
    required this.refName,
    required this.oid,
    required this.subject,
    required this.relativeDate,
  });

  /// Flavor B (temp-index commit of deleted untracked files) restores with
  /// `git restore`; flavor A (a `stash create` commit) restores with
  /// `git stash apply`. See [GitService.restoreSnapshot].
  bool get isUntrackedSnapshot => subject == 'magic-git snapshot';
}

/// Parses `git for-each-ref`'s `fieldSep`-delimited output (see
/// [GitService.refs]) into [GitRef]s. Top-level so [GitService._fetchSnapshot]
/// and [GitService.refs] share one implementation.
/// The only shapes a peeled OID may take (SHA-1 / SHA-256). Anything else in
/// that field position — an echoed format atom, or spillover from an
/// adversarial field — must read as "no peeled OID", never corrupt
/// [GitRef.commitOid]-based grouping.
final RegExp _oidShape = RegExp(r'^[0-9a-f]{40,64}$');

RefsResult parseRefsDetailed(String raw) {
  final refs = <GitRef>[];
  final warnings = <String>[];
  var recordNumber = 0;
  for (final line in raw.split('\n')) {
    if (line.trim().isEmpty) continue;
    recordNumber++;
    final f = line.split('\u0000');
    if (f.isNotEmpty && f.last.isEmpty) f.removeLast();
    // Twelve fixed machine fields precede the unconstrained subject.
    if (f.length < 13) {
      warnings.add(
        'Dropped malformed ref record $recordNumber: '
        'expected at least 13 fields, found ${f.length}.',
      );
      continue;
    }
    String at(int i) => f[i];
    // Peeled commit for annotated tags. Shape-validated (see [_oidShape]) so
    // no non-OID text can ever land here.
    final peeled = at(4);
    // A git older than 2.23 doesn't know `%(worktreepath)` and echoes the
    // format atom back verbatim. Requiring a leading `/` rejects that (and any
    // other non-path) without needing a version probe here.
    final wt = at(5);
    // `%(upstream:track)`: `[ahead 2, behind 1]` (either half alone), `[gone]`,
    // or empty. Parsed by shape, so an old git echoing the atom back verbatim
    // reads as "no tracking data" rather than garbage — same defense as the
    // worktreepath field above.
    final track = at(6);
    // `%(creatordate:unix)`: epoch seconds, or the echoed atom on a pre-2.7
    // git — int.tryParse turns that (and any other non-number) into null, the
    // same no-probe defense as the fields above.
    final created = int.tryParse(at(7).trim());
    // `%(symref)`: non-empty (the target refname) for symbolic refs like
    // refs/remotes/origin/HEAD — aliases, not real branches, so they are
    // dropped here for every consumer (the sidebar once offered checkout and
    // remote-delete on a bogus "origin/HEAD" row). Shape-tested against a
    // `refs/` prefix so an old git echoing the atom back doesn't drop every
    // ref.
    if (at(8).startsWith('refs/')) continue;
    final authorDate = int.tryParse(at(9).trim());
    final authorName = _supportedRefAtom(at(10), '%(authorname)');
    final authorEmail = _normalizeAuthorEmail(
      _supportedRefAtom(at(11), '%(authoremail)'),
    );
    // The subject is the LAST format field (see [_refsFormat]): one that
    // contains the separator byte splits into extra trailing fields, which
    // rejoining reconstructs — the machine fields above can never shift.
    final subject = f.sublist(12).join('\u0000');
    refs.add(
      GitRef(
        isHead: f[0] == '*',
        name: f[1],
        oid: f[2],
        upstream: f[3].isEmpty ? null : f[3],
        subject: _stripSeps(subject),
        peeledOid: _oidShape.hasMatch(peeled) ? peeled : null,
        worktreePath: wt.startsWith('/') ? wt : null,
        ahead: _trackCount(track, 'ahead'),
        behind: _trackCount(track, 'behind'),
        upstreamGone: track == '[gone]',
        creatorDate: created,
        authorDate: authorDate,
        authorName: authorName,
        authorEmail: authorEmail,
      ),
    );
  }
  return RefsResult(refs, warnings);
}

/// Source-compatible facade. [fieldSep] remains optional for older callers;
/// actual snapshots use NUL framing and [parseRefsDetailed].
List<GitRef> parseRefs(String raw, [String? fieldSep]) {
  if (raw.contains('\u0000') || fieldSep == null) {
    return parseRefsDetailed(raw).refs;
  }
  // Compatibility for existing fixtures while they migrate to the fixed NUL
  // format. Convert only the nine legacy fixed separators; the remainder is
  // the old unconstrained subject and is preserved as one final field.
  final converted = <String>[];
  for (final line in raw.split('\n')) {
    if (line.trim().isEmpty) continue;
    final fields = line.split(fieldSep);
    if (fields.length < 5) continue;
    final legacy = List<String>.generate(
      10,
      (i) => fields.length > i ? fields[i] : '',
    );
    final subject = fields.length > 9 ? fields.sublist(9).join(fieldSep) : '';
    converted.add([...legacy.take(9), '', '', '', subject, ''].join('\u0000'));
  }
  return parseRefsDetailed(converted.join('\n')).refs;
}

String? _supportedRefAtom(String value, String literalAtom) {
  final trimmed = value.trim();
  return trimmed.isEmpty || trimmed == literalAtom ? null : trimmed;
}

String? _normalizeAuthorEmail(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.startsWith('<') && trimmed.endsWith('>') && trimmed.length >= 2) {
    return trimmed.substring(1, trimmed.length - 1).trim();
  }
  return trimmed;
}

int _trackCount(String track, String key) {
  final match = RegExp('$key (\\d+)').firstMatch(track);
  return match == null ? 0 : int.parse(match.group(1)!);
}

/// Drives remote `git` through the shared [SSHCommandExecutor], returning typed
/// domain objects. All read commands use plumbing/machine formats with stable
/// delimiters; parsing of large output is pushed to a background isolate.
class GitService {
  final CommandExecutor _executor;

  /// Per-repo environment overlays keyed by the exact `repoPath` string a
  /// command is issued against. Injected into every command's `extraEnv` by
  /// [_scopeEnvFor], so a repo registered here runs *all* of its git commands
  /// with that environment — no call site changes.
  ///
  /// The load-bearing use is the **bare repo with a separate work tree** (the
  /// dotfiles pattern: a bare `~/.home.git` whose work tree is `$HOME`). Git
  /// otherwise discovers its repository by walking up from the process's
  /// working directory to a `.git`; a bare repo has none in the work tree, so
  /// discovery fails. Registering `GIT_DIR`/`GIT_WORK_TREE` here makes git
  /// target the bare repo explicitly instead — the exact env form of the
  /// canonical `git --git-dir=… --work-tree=… …` alias. See [registerRepoScope].
  ///
  /// The two command funnels ([_run]/[_runVoid] and [_runCaptured]) consult
  /// this, and every direct `_executor.execute` site that runs git injects
  /// `extraEnv: _scopeEnvFor(repoPath)` itself. The deliberate exceptions —
  /// commands with no git discovery to scope — are the plain-`cat` reads
  /// ([readFile], [conflictFile]), the `base64` read ([readFileBase64]), and
  /// [validateLocalRepoRoot], whose whole job is classifying a folder by
  /// git's *native* discovery before any scope exists. Multi-repo sweeps
  /// ([setFsmonitorMany]) pin scope per subshell instead, so one repo's env
  /// can't bleed into another's.
  final Map<String, Map<String, String>> _repoScopeEnv = {};

  // Field/record separators for log output: ASCII Unit/Record Separators, which
  // cannot appear in commit metadata, so they parse unambiguously without the
  // NUL collision that `-z` + `%00` would cause.
  static const String fieldSep = '\u001f';
  static const String recordSep = '\u001e';

  static const Duration defaultCommitTimeout = Duration(minutes: 5);
  static const Duration defaultNetworkTimeout = Duration(minutes: 3);

  /// Absolute ceiling for a network op that is still emitting progress.
  /// Stall detection uses [networkTimeout] (the settings field).
  static const Duration defaultNetworkCeiling = Duration(minutes: 30);

  /// Ceiling for user-supplied hooks ([runInWorktree]): a cold-cache `pnpm
  /// install` legitimately outlives [defaultCommitTimeout], and on
  /// [ExecLane.isolated] a long hook no longer holds anything else up — so the
  /// bound only needs to catch a hook that has actually wedged (a dead
  /// registry, a prompt waiting for input that will never come), visibly
  /// rather than never.
  static const Duration defaultHookTimeout = Duration(minutes: 30);

  /// A commit may fire a slow prepare-commit-msg (AI) hook; network ops cross a
  /// possibly-slow link. These get generous per-command timeouts so the executor
  /// doesn't kill a legitimately slow operation as if it had hung. Short reads
  /// (status, log, refs) keep the tighter [SSHCommandExecutor.defaultTimeout].
  /// Both are user-configurable via settings, so a genuinely long push isn't
  /// killed — hence instance fields rather than constants.
  final Duration commitTimeout;
  final Duration networkTimeout;

  /// Scheduler / activity ceiling: at least [defaultNetworkCeiling], or the
  /// user's stall budget if they raised it above that.
  Duration get _networkCeiling => networkTimeout > defaultNetworkCeiling
      ? networkTimeout
      : defaultNetworkCeiling;

  /// Committer identity applied to every commit-creating command (commit,
  /// amend, merge, cherry-pick, revert, rebase) via `-c user.name/-c
  /// user.email`, so commits are authored correctly regardless of the remote
  /// host's own git config. Null/empty when unset — git then uses its own
  /// config as before. See [_idArgs].
  final String? committerName;
  final String? committerEmail;

  /// Receives an [UndoRecord] after every successful undoable mutation (see
  /// `_runCaptured`). Wired by `gitServiceProvider` to push onto the
  /// `UndoJournal`; null (e.g. in most tests) simply disables recording —
  /// mutations behave identically either way.
  final void Function(UndoRecord record)? onUndoRecord;
  final OperationEventCallback? onOperationEvent;

  /// One automatic retry for idempotent reads, so a sub-second transport blip
  /// (e.g. mid-reconnect) doesn't surface as an error before auto-reconnect
  /// kicks in. Never applied to mutations — see [SSHCommandExecutor.execute].
  static const int _readRetries = 1;

  /// Parse in a background isolate only when output exceeds this size.
  static const int _isolateThreshold = 32 * 1024;

  GitService(
    this._executor, {
    this.commitTimeout = defaultCommitTimeout,
    this.networkTimeout = defaultNetworkTimeout,
    this.committerName,
    this.committerEmail,
    this.onUndoRecord,
    this.onOperationEvent,
  });

  /// `-c user.name=… -c user.email=…` overrides to inject right after `git` on
  /// any commit-creating command, or empty when no identity is configured.
  List<String> get _idArgs => [
    if (committerName != null && committerName!.trim().isNotEmpty) ...[
      '-c',
      'user.name=${committerName!.trim()}',
    ],
    if (committerEmail != null && committerEmail!.trim().isNotEmpty) ...[
      '-c',
      'user.email=${committerEmail!.trim()}',
    ],
  ];

  /// Registers a git-dir / work-tree scope for every command issued against
  /// [repoPath]. After this, all `_run`/`_runCaptured`-based reads and
  /// mutations for [repoPath] carry `GIT_DIR=`[gitDir] and (when given)
  /// `GIT_WORK_TREE=`[workTree] — the environment equivalent of
  /// `git --git-dir=<gitDir> --work-tree=<workTree>`.
  ///
  /// For the bare dotfiles repo, [repoPath] and [workTree] are both the work
  /// tree (e.g. `$HOME`) and [gitDir] is the bare repo (e.g. `~/.home.git`).
  /// [repoPath] is matched by exact string, so pass the same value the app
  /// uses to issue commands. Idempotent; re-registering replaces the scope.
  void registerRepoScope(
    String repoPath, {
    required String gitDir,
    String? workTree,
  }) {
    _repoScopeEnv[repoPath] = {'GIT_DIR': gitDir, 'GIT_WORK_TREE': ?workTree};
  }

  /// Removes any scope registered for [repoPath] (on disconnect / repo close),
  /// reverting it to ordinary working-directory-based discovery.
  void unregisterRepoScope(String repoPath) {
    _repoScopeEnv.remove(repoPath);
  }

  /// Drops every registered scope. [GitService] is an app-lifetime singleton
  /// keyed only by backend (not per connection), so its scope registry would
  /// otherwise outlive the connection that populated it — a scope registered
  /// for `/home/user` on host A stays live and gets injected into host B's
  /// commands (even ordinary ones, incl. `validateRepoPath`) after a reconnect
  /// to a different host at the same path. The connect flow calls this before
  /// re-registering this connection's own scopes, and disconnect calls it so
  /// nothing leaks across sessions. [ConnectionState.scopedGitDirs] remains the
  /// durable source of truth the connect flow re-registers from.
  void clearAllRepoScopes() {
    _repoScopeEnv.clear();
  }

  /// Whether [repoPath] currently has a git-dir/work-tree scope registered.
  bool isRepoScoped(String repoPath) => _repoScopeEnv.containsKey(repoPath);

  /// The repo's tracked files (`git ls-files`, NUL-delimited so paths with
  /// newlines survive), work-tree-relative and forward-slash — exactly the
  /// shape [computeBoundedWatchSpec] wants to build the bounded watch surface
  /// for a scoped work-tree repo. Scope-aware: routed through [_run], so for a
  /// scoped repo it lists the *external* git-dir's index, not the work tree.
  Future<List<String>> listTrackedFiles(String repoPath) async {
    final result = await _run(
      repoPath,
      ['git', 'ls-files', '-z'],
      'List tracked files',
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    return result.stdout.split('\u0000').where((s) => s.isNotEmpty).toList();
  }

  /// The env overlay to inject for a command against [repoPath], or null when
  /// the repo has no registered scope (the overwhelming common case — an
  /// ordinary repo with a `.git` in its work tree). Null rather than an empty
  /// map so the executors' `...?extraEnv` spread is a true no-op for unscoped
  /// repos, leaving their behavior byte-for-byte unchanged.
  Map<String, String>? _scopeEnvFor(String repoPath) => _repoScopeEnv[repoPath];

  /// Verifies [repoPath] is a git working tree on the remote host. Called at
  /// connect time so the session fails fast instead of surfacing errors on the
  /// first provider fetch.
  Future<void> validateRepoPath(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['git', 'rev-parse', '--is-inside-work-tree'],
      timeout: const Duration(seconds: 20),
      retries: _readRetries,
      lane: ExecLane.read,
    );
    // A missing `git` comes back as 127 (the shell's "command not found", or
    // the local backend's ProcessException mapped to the same). Surface that
    // honestly instead of the misleading "not a git repository" — the repo
    // path may be perfectly valid; git simply isn't on the host's PATH.
    if (result.exitCode == 127) {
      throw GitException(_gitNotFoundMessage, result);
    }
    if (!result.isSuccess || result.stdout.trim() != 'true') {
      throw GitException('not a git repository: $repoPath', result);
    }
  }

  /// Shown when a `git` invocation exits 127 (binary not found). Points the
  /// user at the two ways to fix it.
  static const String _gitNotFoundMessage =
      'git was not found on the host. Install git, or set its path in '
      'Settings → External tools.';

  /// Extra validation for the **local** backend only (never the SSH path, where
  /// opening a subdirectory of a repo is perfectly valid): confirms the picked
  /// folder is a repository root the sandbox can actually work in, and reports
  /// its [RepoLayout] so the caller knows what kind it is.
  ///
  /// Under the macOS App Sandbox the app may read only the folders the user
  /// granted through a picker. A picked *subdirectory*, a *submodule* (git dir
  /// under `<super>/.git/modules/…`), and a `--separate-git-dir` repo all pass
  /// [validateRepoPath]'s plain `--is-inside-work-tree` check and would then
  /// fail every real read with a raw, confusing permission error — so they are
  /// rejected here with an actionable message.
  ///
  /// A **linked worktree** is the one case that looks the same but is legitimate.
  /// Its git data also lives outside the picked folder (in
  /// `<main>/.git/worktrees/…`), but it is a first-class checkout the user
  /// deliberately created, so instead of rejecting it this returns the layout
  /// with [RepoLayout.isLinkedWorktree] set. The caller
  /// (`ConnectionController._connectLocal`) is then responsible for holding a
  /// SECOND security-scoped grant on the main repository before any git runs —
  /// see `ScopedAccess`, which refcounts exactly that.
  ///
  /// Returns null when it cannot determine the layout (e.g. a git too old for
  /// `--path-format`). That is a deliberate fail-*open*: [validateRepoPath] has
  /// already confirmed a work tree, and a genuine permission error would still
  /// surface on the first real read.
  Future<RepoLayout?> validateLocalRepoRoot(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      // --path-format=absolute forces --git-dir/--git-common-dir to absolute,
      // normalized paths (no `..`, no relative form) so the containment checks
      // below are pure string math.
      gitArgs: [
        'git',
        'rev-parse',
        '--path-format=absolute',
        '--show-toplevel',
        '--git-dir',
        '--git-common-dir',
      ],
      timeout: const Duration(seconds: 20),
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!result.isSuccess) return null;
    final lines = const LineSplitter()
        .convert(result.stdout)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 3) return null;

    // Resolve symlinks on both sides so a granted `/tmp/x` (→ `/private/tmp/x`)
    // can't false-mismatch git's canonical output. On failure (e.g. a git dir
    // outside the sandbox grant that can't even be stat'd) keep git's already-
    // absolute path — the check then correctly fails closed.
    String canonical(String path) {
      try {
        return Directory(path).resolveSymbolicLinksSync();
      } catch (_) {
        return path;
      }
    }

    bool within(String parent, String child) =>
        child == parent || child.startsWith('$parent/');

    final repoRoot = canonical(repoPath);
    if (canonical(lines[0]) != repoRoot) {
      throw GitException(
        'The selected folder is inside a larger repository — its root is '
        "elsewhere. Pick the repository's top-level folder instead.",
        result,
      );
    }

    final layout = RepoLayout(
      toplevel: repoRoot,
      gitDir: canonical(lines[1]),
      gitCommonDir: canonical(lines[2]),
    );

    // A linked worktree: git dir differs from common dir. Legitimate — the
    // caller acquires the main repo's grant too. This is the ONLY correct test;
    // "is `.git` a file" would also match a submodule.
    if (layout.isLinkedWorktree) return layout;

    // Everything else must keep its git data inside the folder we were granted,
    // or no read will work. This catches submodules (`.git/modules/…`) and
    // `--separate-git-dir`, whose git dir is unreachable and — unlike a linked
    // worktree — has no main-repo path we could ask the user to grant.
    if (!within(repoRoot, layout.gitCommonDir)) {
      throw GitException(
        layout.isSubmodule
            ? 'This is a submodule — its git data lives inside the parent '
                  "repository, which the app sandbox can't reach from here. "
                  'Open the parent repository instead.'
            : "This repository's git data is stored outside the selected "
                  "folder, which the app sandbox can't reach. Open a repository "
                  'whose `.git` lives inside it.',
        result,
      );
    }
    return layout;
  }

  /// Working-tree + branch status via porcelain v2. `--no-optional-locks` (also
  /// enforced via the env prelude) keeps this read from ever taking index.lock.
  /// Bundled with [refs] and [pendingOp] into one round trip — see [_snapshot].
  Future<GitStatus> status(String repoPath) async =>
      (await _snapshot(repoPath)).status;

  /// Local branches, remote-tracking refs, and tags. Bundled with [status] and
  /// [pendingOp] into one round trip — see [_snapshot].
  Future<List<GitRef>> refs(String repoPath) async {
    final snapshot = await _snapshot(repoPath);
    _latestRefParseWarnings[repoPath] = snapshot.refParseWarnings;
    return snapshot.refs;
  }

  /// Refs and non-fatal parse warnings from the same combined snapshot.
  ///
  /// This deliberately calls the virtual [refs] seam so test doubles and
  /// specialized services that override it remain source-compatible. The real
  /// implementation records warnings while resolving [refs]; an override has
  /// no parser warnings and therefore returns an empty warning list.
  Future<RefsResult> refsWithWarnings(String repoPath) async {
    final refs = await this.refs(repoPath);
    final warnings = _latestRefParseWarnings.remove(repoPath) ?? const [];
    return RefsResult(refs, warnings);
  }

  /// Which git operation, if any, is mid-flight — a merge, cherry-pick, revert,
  /// or (interactive) rebase — so the UI can show the right "in progress,
  /// resolve & commit or abort" banner. Bundled with [status] and [refs] into
  /// one round trip — see [_snapshot].
  Future<PendingOp> pendingOp(String repoPath) async =>
      (await _snapshot(repoPath)).pendingOp;

  /// The repo's *configured* remotes (`git remote`) — the correct test for
  /// "does this repo have a remote" (see [RepoSnapshot.remotes]; remote-
  /// tracking refs are empty for an empty repository even with a perfectly
  /// wired origin). Bundled with [status]/[refs]/[pendingOp] into one round
  /// trip — see [_snapshot].
  Future<List<String>> remotes(String repoPath) async =>
      (await _snapshot(repoPath)).remotes;

  // ---------------------------------------------------------------------------
  // git worktree
  //
  // Read commands take ExecLane.read; every mutation takes ExecLane.exclusive
  // because they write `<common>/.git/worktrees/…` and, for add/remove, the
  // working tree itself.
  //
  // Deliberately NOT routed through [_runCaptured]: the undo journal restores a
  // moved HEAD/branch tip, and no worktree command moves HEAD in the repo it's
  // run from. Undoing `worktree add` means removing a directory, which isn't an
  // UndoRecord this model can express. The safety net is git's own: `remove`
  // refuses a dirty or locked worktree unless forced, and the UI confirms first.
  // ---------------------------------------------------------------------------

  /// Where this repo's git data lives — the one call that answers "is this a
  /// linked worktree, and if so where is the main repository".
  ///
  /// Prefers `--path-format=absolute` (usable absolute/symlink-resolved paths).
  /// On Git that rejects that flag (pre-2.31, still within the app's 2.24
  /// floor), falls back to `--absolute-git-dir` and canonicalizes every path
  /// on the command host with POSIX `cd -P`/`pwd -P`. The fallback must not use
  /// this app process's filesystem: [repoPath] may name an SSH host path.
  Future<RepoLayout> repoLayout(String repoPath) =>
      _resolveRepoLayout(repoPath, extraEnv: _scopeEnvFor(repoPath));

  static const _legacyRepoLayoutScript = r'''
canon_dir() {
  p=$1
  case "$p" in
    /*) ;;
    *) p="./$p" ;;
  esac
  (CDPATH= cd -P "$p" && pwd -P)
}
top=$(git rev-parse --show-toplevel) || exit $?
git_dir=$(git rev-parse --absolute-git-dir) || exit $?
common_dir=$(git rev-parse --git-common-dir) || exit $?
top=$(canon_dir "$top") || exit $?
git_dir=$(canon_dir "$git_dir") || exit $?
common_dir=$(canon_dir "$common_dir") || exit $?
printf '%s\n%s\n%s\n' "$top" "$git_dir" "$common_dir"
''';

  Future<RepoLayout> _resolveRepoLayout(
    String repoPath, {
    required Map<String, String>? extraEnv,
  }) async {
    final modern = await _executor.execute(
      repoPath: repoPath,
      extraEnv: extraEnv,
      gitArgs: [
        'git',
        'rev-parse',
        '--path-format=absolute',
        '--show-toplevel',
        '--git-dir',
        '--git-common-dir',
      ],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (modern.isSuccess) {
      final layout = _parseRepoLayoutLines(modern.stdout);
      if (layout != null) return layout;
    }

    // Git < 2.31 rejects `--path-format`. Resolve the fallback on the command
    // host so an SSH path is never interpreted against the local Mac.
    final legacy = await _executor.execute(
      repoPath: repoPath,
      extraEnv: extraEnv,
      gitArgs: ['sh', '-c', _legacyRepoLayoutScript],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!legacy.isSuccess) {
      throw GitException('Could not resolve the repository layout', legacy);
    }
    final layout = _parseRepoLayoutLines(legacy.stdout);
    if (layout == null) {
      throw GitException('Could not resolve the repository layout', legacy);
    }
    return layout;
  }

  /// Parses the three absolute, host-canonicalized repository layout paths.
  RepoLayout? _parseRepoLayoutLines(String stdout) {
    final lines = const LineSplitter()
        .convert(stdout)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 3) return null;

    return RepoLayout(
      toplevel: lines[0],
      gitDir: lines[1],
      gitCommonDir: lines[2],
    );
  }

  /// The gitfile-redirect target of `<repoPath>/.git`, when `.git` is a *file*
  /// containing `gitdir: <path>` — the dotfiles redirect into e.g.
  /// `~/.home.git`. Returns the target (resolved against [repoPath] when
  /// relative), or null when `.git` is a directory, absent, or not a parseable
  /// gitfile. Reads over the executor seam (plain `cat`), so it works on both
  /// backends with no scope registered — this exists precisely to *find* the
  /// scope before one exists.
  Future<String?> gitfileRedirectTarget(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      // `cat` fails cleanly when `.git` is a directory or missing — the exit
      // code is the classifier, no stderr parsing needed.
      gitArgs: ['cat', '--', '.git'],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!result.isSuccess) return null;
    final line = const LineSplitter()
        .convert(result.stdout)
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('gitdir:'), orElse: () => '');
    var target = line.isEmpty ? '' : line.substring('gitdir:'.length).trim();
    while (target.startsWith('./')) {
      target = target.substring(2);
    }
    if (target.isEmpty) return null;
    // A relative target is relative to the gitfile's directory. No `..`
    // collapsing needed: this value is only ever handed to git (as GIT_DIR),
    // which normalizes internally, and [scopedRepoLayout]'s
    // `--path-format=absolute` output is what callers persist.
    return target.startsWith('/') ? target : '$repoPath/$target';
  }

  /// [repoLayout] under an explicit scope overlay — the same
  /// `GIT_DIR`/`GIT_WORK_TREE` environment [registerRepoScope] would inject —
  /// WITHOUT touching the scope registry.
  ///
  /// This is the probe for the one layout native discovery cannot resolve at
  /// all: a **bare** git-dir behind a `.git` gitfile redirect (`git init
  /// --bare ~/.home.git` + `gitdir: ~/.home.git`). Bare means no work tree, so
  /// unscoped `rev-parse --show-toplevel` dies with "must be run in a work
  /// tree"; the overlay supplies the work tree exactly as the eventual scope
  /// registration will. Used by the add sheet's auto-detection to validate a
  /// candidate git-dir before anything is registered or persisted — a garbage
  /// candidate throws instead of silently mis-registering.
  /// [repoLayout] with the gitfile-redirect fallback: native discovery first,
  /// then — when that fails — the `.git` redirect target validated through
  /// [scopedRepoLayout]. This resolves every layout the app supports,
  /// including the one native discovery can't (a bare git-dir behind a
  /// hand-written redirect), and is resilient to a poisoned scope registry:
  /// a stale registered scope for [repoPath] can fail the native probe, but
  /// the fallback carries its own explicit overlay and still resolves the
  /// truth. Returns null when neither path resolves (not a repo, or a
  /// redirect-less bare git-dir).
  Future<RepoLayout?> detectRepoLayout(String repoPath) async {
    try {
      return await repoLayout(repoPath);
    } on Object {
      try {
        final target = await gitfileRedirectTarget(repoPath);
        if (target == null) return null;
        return await scopedRepoLayout(repoPath, gitDir: target);
      } catch (_) {
        return null;
      }
    }
  }

  Future<RepoLayout> scopedRepoLayout(
    String repoPath, {
    required String gitDir,
  }) => _resolveRepoLayout(
    repoPath,
    extraEnv: {'GIT_DIR': gitDir, 'GIT_WORK_TREE': repoPath},
  );

  /// All worktrees of this repository, main worktree first.
  ///
  /// Requires git 2.36 for `-z`, which is not optional: git does not quote
  /// paths in the newline porcelain form, so a path containing a newline
  /// silently corrupts the parse. Callers gate on the probed git version and
  /// show an explanatory empty state rather than parsing a riskier format.
  Future<List<GitWorktree>> gitWorktrees(String repoPath) async {
    final result = await _run(
      repoPath,
      ['git', 'worktree', 'list', '--porcelain', '-z'],
      'List worktrees',
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    return parseWorktreeList(result.stdout);
  }

  /// Creates a worktree at [path].
  ///
  /// Exactly one of [newBranch] (create a branch), [detach], or neither (check
  /// out the existing [commitish]) applies. [force] overrides "branch is
  /// already used by another worktree" and "path is registered but missing" —
  /// it does NOT override a path that simply already exists.
  Future<void> addWorktree(
    String repoPath, {
    required String path,
    String? newBranch,
    bool resetBranch = false,
    String? commitish,
    bool detach = false,
    bool? track,
    bool lock = false,
    String? lockReason,
    bool force = false,
  }) async {
    final args = ['git', 'worktree', 'add'];
    if (force) args.add('--force');
    if (detach) args.add('--detach');
    if (newBranch != null) {
      // -B resets an existing branch to the start point; -b refuses if it
      // exists. Never both.
      args.addAll([resetBranch ? '-B' : '-b', newBranch]);
    }
    if (track == true) args.add('--track');
    if (track == false) args.add('--no-track');
    if (lock) {
      args.add('--lock');
      // A reason is only meaningful alongside --lock, and git rejects it alone.
      if (lockReason != null && lockReason.isNotEmpty) {
        args.addAll(['--reason', lockReason]);
      }
    }
    // `git worktree add` accepts neither `--end-of-options` nor `--` (both exit
    // 129 with a usage dump — verified against git 2.55), unlike every other
    // worktree subcommand. So there is no way to tell it "the rest are
    // operands", and a leading `-` would be parsed as a flag. Every path the UI
    // produces is absolute (folder picker or path template) and every commit-ish
    // comes from a ref list, so this is unreachable in practice — but it must
    // fail loudly rather than turn into a misparsed git invocation.
    if (path.startsWith('-') || (commitish?.startsWith('-') ?? false)) {
      throw ArgumentError(
        'worktree add cannot take a path or revision starting with "-" '
        '(git provides no end-of-options for this subcommand)',
      );
    }
    args.add(path);
    if (commitish != null && commitish.isNotEmpty) args.add(commitish);
    await _runVoid(
      repoPath,
      args,
      'Add worktree',
      timeout: defaultCommitTimeout,
    );
  }

  /// Removes the worktree at [path] — deletes its directory AND its admin dir.
  ///
  /// Refuses when it has modified or untracked files, and (separately) when it
  /// is locked. [force] once overrides the dirty case; git needs `--force`
  /// *twice* to remove a locked worktree, which is what [force] + [locked]
  /// produces. The main worktree can never be removed.
  Future<void> removeWorktree(
    String repoPath,
    String path, {
    bool force = false,
    bool locked = false,
  }) async {
    final args = ['git', 'worktree', 'remove'];
    if (force) args.add('--force');
    if (force && locked) args.add('--force');
    args.addAll(['--end-of-options', path]);
    await _runVoid(
      repoPath,
      args,
      'Remove worktree',
      timeout: defaultCommitTimeout,
    );
  }

  /// Forgets admin entries whose worktree directory is gone. Never deletes a
  /// working tree. With [dryRun], reports what it *would* prune so the UI can
  /// show the user the list before they commit to it.
  Future<List<String>> pruneWorktrees(
    String repoPath, {
    bool dryRun = false,
  }) async {
    final args = ['git', 'worktree', 'prune', '--verbose'];
    if (dryRun) args.add('--dry-run');
    final result = await _run(
      repoPath,
      args,
      'Prune worktrees',
      // The dry-run preview only reads the admin dir — it must not wait
      // behind (or barrier ahead of) real mutations just to show a list.
      lane: dryRun ? ExecLane.read : ExecLane.exclusive,
    );
    // `--verbose` reports one line per entry ("Removing worktrees/x: <reason>")
    // on **stderr**, not stdout — verified against git 2.55, and true for the
    // real run as well as `--dry-run`. Read both so a future git that moves it
    // to stdout doesn't silently produce an empty preview.
    return const LineSplitter()
        .convert('${result.stdout}\n${result.stderr}')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// Marks a worktree as not-prunable and not-removable — the mechanism for one
  /// living on removable media or a network share, which would otherwise be
  /// silently reaped by `gc`'s auto-prune while unmounted.
  Future<void> lockWorktree(
    String repoPath,
    String path, {
    String? reason,
  }) async {
    final args = ['git', 'worktree', 'lock'];
    if (reason != null && reason.isNotEmpty) args.addAll(['--reason', reason]);
    args.addAll(['--end-of-options', path]);
    await _runVoid(repoPath, args, 'Lock worktree');
  }

  Future<void> unlockWorktree(String repoPath, String path) => _runVoid(
    repoPath,
    ['git', 'worktree', 'unlock', '--end-of-options', path],
    'Unlock worktree',
  );

  /// Moves a worktree, rewriting both halves of the two-way link. Cannot move
  /// the main worktree.
  Future<void> moveWorktree(String repoPath, String from, String to) async {
    await _runVoid(
      repoPath,
      ['git', 'worktree', 'move', '--end-of-options', from, to],
      'Move worktree',
      timeout: defaultCommitTimeout,
    );
  }

  /// Re-links worktrees whose directories were moved outside git (e.g. dragged
  /// in Finder), which is what leaves an entry `prunable` with "gitdir file
  /// points to non-existent location". Passing the new [paths] repairs links
  /// pointing *at* them; passing none repairs links *from* this repo.
  Future<void> repairWorktrees(
    String repoPath, [
    List<String> paths = const [],
  ]) async {
    await _runVoid(repoPath, [
      'git',
      'worktree',
      'repair',
      '--end-of-options',
      ...paths,
    ], 'Repair worktrees');
  }

  /// Copies gitignored files matching [globs] from [from] into a freshly-created
  /// worktree at [to].
  ///
  /// This closes the single biggest real-world hole in `git worktree`:
  /// `worktree add` checks out **tracked** files only. So the new worktree has
  /// no `.env`, no `.env.local`, none of the untracked-but-essential config the
  /// project needs — and it fails on first run with an error that says nothing
  /// about worktrees. Every developer hits this; no desktop Git GUI fixes it.
  ///
  /// Uses `git ls-files --others --ignored` so the source of truth is git's own
  /// ignore rules: only files git is deliberately *not* tracking are eligible,
  /// which is exactly the set `worktree add` left behind. A glob that matches a
  /// tracked file therefore copies nothing — the file is already there.
  ///
  /// Directories are copied recursively, and parents are created as needed, so a
  /// glob like `config/*.local` works. Missing matches are not an error: a repo
  /// with no `.env` should create a worktree, not fail.
  ///
  /// Returns the raw result so the caller can put it in the Output view: each
  /// copied file is reported on stdout, each failed one on stderr. Any failed
  /// copy throws — a worktree silently missing half its `.env` files is exactly
  /// the confusing state this feature exists to prevent.
  Future<SSHCommandResult> copyIgnoredFiles({
    required String from,
    required String to,
    required List<String> globs,
  }) async {
    if (globs.isEmpty) {
      return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    return _run(
      from,
      ['sh', '-c', copyIgnoredFilesScript(to: to, globs: globs)],
      'Copy ignored files into the worktree',
      timeout: defaultCommitTimeout,
      // Isolated, like [runInWorktree] and for the same reason: it writes
      // into a brand-new checkout nothing else touches (the source side only
      // *reads* ignored files), and someone globbing a big fixture dir would
      // otherwise hold the exclusive barrier and stall every read in the app.
      // This call site was missed when the isolated lane was introduced.
      lane: ExecLane.isolated,
    );
  }

  /// The copy pipeline for [copyIgnoredFiles], separated so the dash-compat
  /// test can execute it under `/bin/dash` directly.
  ///
  /// It MUST stay POSIX-sh clean: the service runs it via `sh -c`, and on
  /// Debian-family remotes `sh` is **dash**. The previous bash-only
  /// `while read -r -d ''` loop errored instantly there — the loop body never
  /// ran, `fail` stayed 0, and the step reported SUCCESS having copied
  /// nothing, which is precisely the silent-missing-`.env` state this feature
  /// exists to prevent. `xargs -0` provides the NUL-safe iteration instead
  /// (universally available; on empty input BSD xargs runs nothing and GNU
  /// runs once with no file operand, which the `$#` guard turns into a
  /// clean exit — a glob matching nothing must not be an error).
  ///
  /// Failure contract, unchanged: each copied file is reported on stdout and
  /// each failed one on stderr; a failed copy makes that invocation exit 1,
  /// xargs keeps going (only 255 aborts it) and finishes with 123 — one bad
  /// copy fails the whole step after still attempting the rest. The
  /// `set -o pipefail` additionally surfaces a failed `git ls-files` where
  /// the shell supports the option; it is probed in a **subshell** first
  /// because `set` is a POSIX special builtin whose failure ABORTS a
  /// non-interactive shell — a bare `set -o pipefail 2>/dev/null` killed
  /// dash outright (exit 2, message swallowed by the redirect), which is
  /// worse than the degraded no-pipefail mode.
  ///
  /// The destination is passed through xargs as a fixed argv element (never
  /// interpolated into the per-file script), so [ShellEscaper.escape]'s
  /// single-quoted token is unwrapped exactly once by the outer shell —
  /// the nested-quoting bug that once created a directory literally named
  /// `'` in the source repo cannot recur, and paths with spaces survive.
  static String copyIgnoredFilesScript({
    required String to,
    required List<String> globs,
  }) {
    final pathspecs = globs.map(ShellEscaper.escape).join(' ');
    // Per-file worker: $1 is the destination (fixed), $2 the file (appended
    // by xargs -n1). Filenames arrive as argv, so their content is never
    // re-parsed by a shell.
    const worker =
        '[ "\$#" -ge 2 ] || exit 0; dest="\$1"; f="\$2"; '
        'if mkdir -p "\$dest/\$(dirname "\$f")" && cp -R "\$f" "\$dest/\$f"; '
        'then printf \'copied %s\\n\' "\$f"; '
        'else printf \'failed %s\\n\' "\$f" >&2; exit 1; fi';
    return '(set -o pipefail) 2>/dev/null && set -o pipefail; '
        'git ls-files -z --others --ignored --exclude-standard -- $pathspecs '
        '| xargs -0 -n1 sh -c ${ShellEscaper.escape(worker)} sh '
        '${ShellEscaper.escape(to)}';
  }

  /// Runs [command] inside a worktree — the post-create hook (`pnpm install`,
  /// `bundle install`), so a new worktree is ready to work in rather than ready
  /// to configure.
  ///
  /// Returns the raw result so the caller can put it in the Output view; a
  /// non-zero exit throws, because a failed `install` means the worktree is not
  /// actually usable and the user needs to know.
  ///
  /// Runs on [ExecLane.isolated]: the hook operates on a brand-new checkout
  /// nothing else touches, and it can legitimately run for minutes — on the
  /// exclusive lane it acted as a barrier and every background refresh in the
  /// app (auto-fetch, watch-triggered status) stalled until the install
  /// finished.
  Future<SSHCommandResult> runInWorktree(String worktreePath, String command) =>
      _run(
        worktreePath,
        ['sh', '-c', command],
        'Post-create command',
        timeout: defaultHookTimeout,
        lane: ExecLane.isolated,
      );

  static const List<String> _refsFormat = [
    '%(HEAD)',
    '%(refname)',
    '%(objectname)',
    '%(upstream:short)',
    '%(*objectname)', // peeled commit for annotated tags (empty otherwise)
    // Which worktree (if any) has this branch checked out — see
    // [GitRef.worktreePath]. Empty for refs that aren't checked out, and for
    // remotes/tags. Available since git 2.23; older gits emit the literal
    // format string, which parses harmlessly as a non-path and is filtered by
    // the absolute-path check in [parseRefs].
    '%(worktreepath)',
    // Divergence from upstream: `[ahead 2, behind 1]` / `[gone]` / empty —
    // see [GitRef.ahead]/[GitRef.upstreamGone]. Parsed by shape, so an old
    // git echoing the atom reads as "no tracking data".
    '%(upstream:track)',
    // Creation time in epoch seconds — the tags list's newest-first sort key
    // (tagger date for annotated tags, committer date for lightweight ones;
    // see [GitRef.creatorDate]). A pre-2.7 git echoing the atom parses as
    // null via int.tryParse.
    '%(creatordate:unix)',
    // Non-empty (the target refname) for symbolic refs — how [parseRefs]
    // drops alias entries like refs/remotes/origin/HEAD, which are not real
    // branches (checking one out DWIMs the bogus local name "HEAD"; deleting
    // one would target a ref the remote doesn't have).
    '%(symref)',
    '%(authordate:unix)',
    '%(authorname)',
    '%(authoremail)',
    // The subject is deliberately LAST: it is the one field whose content git
    // does not constrain, so a subject containing the separator byte can only
    // spill into extra trailing fields — which [parseRefs] rejoins — instead
    // of shifting the machine fields after it (a shifted fragment once could
    // impersonate a peeled OID).
    '%(contents:subject)',
  ];

  // A plain `git am` and an am-based rebase both create `$d/rebase-apply`, so
  // testing that dir alone mislabels an in-progress mailbox apply as a rebase.
  // They differ by a marker file: `git am` writes `rebase-apply/applying`,
  // while `git rebase` does not — so an `applying` file present means `am`, not
  // rebase. `am` has no PendingOp variant (adding one would break the
  // exhaustive PendingOp switches in the UI), so it falls through to
  // PendingOp.none below — the important thing is that it is no longer
  // reported as a rebase.
  static const String _pendingOpScript =
      'd=\$(git rev-parse --git-dir 2>/dev/null || echo .git); '
      'if [ -f "\$d/rebase-apply/applying" ]; then echo am; '
      'elif [ -d "\$d/rebase-merge" ] || [ -d "\$d/rebase-apply" ]; then echo rebase; '
      'elif [ -f "\$d/MERGE_HEAD" ]; then echo merge; '
      'elif [ -f "\$d/CHERRY_PICK_HEAD" ]; then echo cherry-pick; '
      'elif [ -f "\$d/REVERT_HEAD" ]; then echo revert; '
      'else echo none; fi';

  /// Separates each section's raw stdout in [_fetchSnapshot]'s combined
  /// script. STX (0x02) effectively never appears in porcelain status's
  /// NUL-delimited (`-z`) records, the refs format's unit-separator
  /// (`fieldSep`)-delimited fields, or plain ref/path text, so splitting the
  /// combined stdout on it recovers each section (and, bracketing an exit
  /// code, each section's own success/failure — the combined script's own
  /// exit code is just the last command's, which can't distinguish an
  /// earlier failure). "Effectively": git does not forbid the byte in commit
  /// subjects or file paths, so a collision is *possible* — when the split
  /// doesn't yield exactly the expected sections, [_fetchSnapshot] falls
  /// back to marker-free per-section round trips instead of failing.
  static const String _snapshotSep = '\u0002RMGSNAP\u0002';

  /// Separates the pre/post state fields from the mutation's own stdout in
  /// [_runCaptured]'s combined script — same STX-bracketed reasoning as
  /// [_snapshotSep] (the control byte can't appear in OIDs, ref names, or any
  /// text git prints in these positions).
  static const String _undoSep = '\u0002RMGUNDO\u0002';

  /// In-flight combined fetch per repo, so concurrent callers within the same
  /// tick (e.g. [pendingOp]'s provider `ref.watch`ing [status] and then
  /// immediately calling this itself) share one round trip instead of two.
  final _snapshotInFlight = <String, Future<RepoSnapshot>>{};

  /// Warning handoff from the virtual [refs] seam to [refsWithWarnings].
  /// Entries are removed as soon as the warning-aware caller resumes.
  final _latestRefParseWarnings = <String, List<String>>{};

  /// Fetches [status], [refs], and [pendingOp] together in a single round
  /// trip. These three are invalidated together on nearly every refresh
  /// trigger (watcher ticks, post-mutation refreshes across the app) — this
  /// exists purely to turn what would be three serialized SSH round trips
  /// into one.
  Future<RepoSnapshot> _snapshot(String repoPath) {
    final existing = _snapshotInFlight[repoPath];
    if (existing != null) return existing;
    final future = _fetchSnapshot(repoPath);
    _snapshotInFlight[repoPath] = future;
    // `.ignore()`: `whenComplete` yields a *derived* future that re-propagates
    // a fetch failure, and nothing awaits that derivative — without ignoring
    // it, every failed snapshot also surfaced as a spurious unhandled async
    // error in the zone (the real error still reaches the caller through the
    // returned `future` itself).
    future.whenComplete(() => _snapshotInFlight.remove(repoPath)).ignore();
    return future;
  }

  Future<RepoSnapshot> _fetchSnapshot(String repoPath) async {
    // Fixed NUL columns prevent commit-controlled author/subject bytes from
    // shifting machine fields. The final NUL makes truncated rows detectable.
    final format = '${_refsFormat.join('%00')}%00';
    // `-uall`: list untracked files individually instead of collapsing a
    // wholly-untracked directory to one `dir/` record. Every per-file
    // affordance in the UI assumes real file paths — a collapsed `dir/`
    // row rendered a silently blank diff pane (`git diff --no-index
    // /dev/null dir/` exits 1 with empty stdout, indistinguishable from
    // success — verified against git 2.55), hid the true untracked count,
    // and blinded [structureSignature] to files added inside the
    // directory. The enumeration cost is not new for an ordinary repo: the
    // file-tree pane already runs a full `ls-files --others` for the same set
    // on every shape change.
    //
    // BUT a scoped (dotfiles) repo has its work tree at `$HOME`, where `-uall`
    // forces git to walk the entire home directory every refresh AND overrides
    // the `status.showUntrackedFiles=no` these repos set precisely to suppress
    // that (surfacing hundreds of phantom untracked records). For a scoped repo
    // we drop the forced flag and let the host's own config decide — the
    // dotfiles norm (`=no`) then costs nothing and shows nothing, and a user
    // who wants untracked can opt in via config.
    final untracked = isRepoScoped(repoPath) ? '' : '-uall ';
    final script =
        'git --no-optional-locks status --porcelain=v2 $untracked--branch -z; s1=\$?; '
        "printf '$_snapshotSep%d$_snapshotSep' \"\$s1\"; "
        // `-c i18n.logOutputEncoding=UTF-8`: re-encodes `%(contents:subject)`
        // to UTF-8 for output regardless of the remote's stored commit
        // encoding, so a repo with a legacy `i18n.commitEncoding` (Latin-1,
        // Shift-JIS, …) still yields clean UTF-8 here instead of bytes this
        // app's `Utf8Decoder(allowMalformed: true)` would silently mangle into
        // U+FFFD. Deliberately not `i18n.commitEncoding` — that config tells
        // git what the *stored* bytes actually are, and forcing it to UTF-8
        // would make git misinterpret a genuinely non-UTF-8 commit rather than
        // transcode it.
        "git -c i18n.logOutputEncoding=UTF-8 for-each-ref --format='$format' refs/heads refs/remotes refs/tags; s2=\$?; "
        "printf '$_snapshotSep%d$_snapshotSep' \"\$s2\"; "
        // Configured remotes (`git remote`) — the CONFIG-level truth for
        // "has a remote". Remote-tracking refs cannot provide it for an
        // empty repository (see [RepoSnapshot.remotes]).
        'git remote; s3=\$?; '
        "printf '$_snapshotSep%d$_snapshotSep' \"\$s3\"; "
        '$_pendingOpScript';

    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['sh', '-c', script],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );

    final parts = result.stdout.split(_snapshotSep);
    if (parts.length != 7) {
      // Fewer parts: the script died before printing every marker (not a
      // repo, killed shell). MORE parts: a marker collision — a commit
      // subject or a path that itself contains the marker bytes, which no
      // split can disambiguate. Either way the combined output is
      // unparseable; re-fetch each section as its own round trip, where no
      // in-band marker exists to collide (a genuine failure then surfaces
      // from its own section with a precise error, instead of the old
      // blanket "malformed output" throw that permanently wedged the repo's
      // status pane on adversarial-but-legal content).
      return _fetchSnapshotSeparately(repoPath, format);
    }
    return _assembleSnapshot(
      statusStdout: parts[0],
      statusExit: int.tryParse(parts[1].trim()) ?? 1,
      refsStdout: parts[2],
      refsExit: int.tryParse(parts[3].trim()) ?? 1,
      remotesStdout: parts[4],
      remotesExit: int.tryParse(parts[5].trim()) ?? 1,
      pendingStdout: parts[6],
      stderr: result.stderr,
    );
  }

  /// The marker-free fallback for [_fetchSnapshot]: the same four sections as
  /// individual round trips. Slower (4× the latency), but immune to marker
  /// collisions by construction — each command's stdout arrives on its own
  /// channel. Only ever taken when the combined output failed to split.
  Future<RepoSnapshot> _fetchSnapshotSeparately(
    String repoPath,
    String format,
  ) async {
    final status = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        '--no-optional-locks',
        'status',
        '--porcelain=v2',
        // See [_fetchSnapshot]: forced `-uall` would walk all of `$HOME` and
        // override `status.showUntrackedFiles=no` on a scoped/dotfiles repo.
        if (!isRepoScoped(repoPath)) '-uall',
        '--branch',
        '-z',
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    final refs = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'for-each-ref',
        '--format=$format',
        'refs/heads',
        'refs/remotes',
        'refs/tags',
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    final remotes = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['git', 'remote'],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    final pending = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['sh', '-c', _pendingOpScript],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    return _assembleSnapshot(
      statusStdout: status.stdout,
      statusExit: status.exitCode,
      refsStdout: refs.stdout,
      refsExit: refs.exitCode,
      remotesStdout: remotes.stdout,
      remotesExit: remotes.exitCode,
      pendingStdout: pending.stdout,
      stderr: [status.stderr, refs.stderr].join('\n'),
    );
  }

  /// Turns the four raw snapshot sections into a [RepoSnapshot] — shared by
  /// the combined fast path and the marker-collision fallback.
  Future<RepoSnapshot> _assembleSnapshot({
    required String statusStdout,
    required int statusExit,
    required String refsStdout,
    required int refsExit,
    required String remotesStdout,
    required int remotesExit,
    required String pendingStdout,
    required String stderr,
  }) async {
    if (statusExit != 0) {
      throw GitException(
        'git status failed',
        SSHCommandResult(
          exitCode: statusExit,
          stdout: statusStdout,
          stderr: stderr,
        ),
      );
    }
    if (refsExit != 0) {
      throw GitException(
        'git for-each-ref failed',
        SSHCommandResult(
          exitCode: refsExit,
          stdout: refsStdout,
          stderr: stderr,
        ),
      );
    }

    final status = statusStdout.length > _isolateThreshold
        ? await Isolate.run(() => GitPorcelainParser.parseV2(statusStdout))
        : GitPorcelainParser.parseV2(statusStdout);
    final refsResult = parseRefsDetailed(refsStdout);
    // `git remote` inside a repo effectively cannot fail; a non-zero exit is
    // treated as "no remotes known" rather than failing the whole snapshot —
    // status and refs above are the load-bearing sections.
    final remotes = remotesExit != 0
        ? const <String>[]
        : [
            for (final line in remotesStdout.split('\n'))
              if (line.trim().isNotEmpty) line.trim(),
          ];
    final pendingOp = switch (pendingStdout.trim()) {
      'rebase' => PendingOp.rebase,
      'merge' => PendingOp.merge,
      'cherry-pick' => PendingOp.cherryPick,
      'revert' => PendingOp.revert,
      _ => PendingOp.none,
    };

    return RepoSnapshot(
      status: status,
      refs: refsResult.refs,
      pendingOp: pendingOp,
      remotes: remotes,
      refParseWarnings: refsResult.parseWarnings,
    );
  }

  /// Opt-in per-repo tuning for large working trees (mutates git config).
  /// Enabling turns on fsmonitor plus the complementary untracked cache and
  /// index v4; disabling turns fsmonitor back off (the caches are harmless and
  /// left in place). One combined round trip rather than one `git config` call
  /// per setting.
  /// Object-store footprint via `git count-objects -vH` — one cheap round
  /// trip, fetched on demand for the dashboard's "Measure" action. `-H`
  /// makes git render the sizes human-readable; the UI shows them verbatim.
  Future<RepoFootprint> repoFootprint(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['git', 'count-objects', '-v', '-H'],
      lane: ExecLane.read,
      retries: _readRetries,
    );
    if (!result.isSuccess) {
      throw GitException('git count-objects failed', result);
    }
    final map = <String, String>{};
    for (final line in result.stdout.split('\n')) {
      final idx = line.indexOf(':');
      if (idx > 0) {
        map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
      }
    }
    return RepoFootprint(
      looseObjects: int.tryParse(map['count'] ?? '') ?? 0,
      looseSize: map['size'] ?? '0',
      inPackObjects: int.tryParse(map['in-pack'] ?? '') ?? 0,
      packs: int.tryParse(map['packs'] ?? '') ?? 0,
      packSize: map['size-pack'] ?? '0',
      garbageSize: map['size-garbage'],
    );
  }

  Future<void> setFsmonitor(String repoPath, {required bool enabled}) async {
    await _runVoid(repoPath, [
      'sh',
      '-c',
      _fsmonitorScript(enabled: enabled),
    ], 'git config fsmonitor');
  }

  /// Whether this repo (or global config) enables GPG commit signing.
  /// Magic Git always passes `--no-gpg-sign` on commits (no agent over SSH),
  /// so callers use this for a user-facing disclosure only. Unset/errors → false.
  Future<bool> commitGpgSignEnabled(String repoPath) async {
    // `--get` exits 1 when unset — do not use [_run] (throws on non-zero).
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'config', '--bool', '--get', 'commit.gpgsign'],
      extraEnv: _scopeEnvFor(repoPath),
      lane: ExecLane.read,
      retries: 0,
    );
    final v = result.stdout.trim().toLowerCase();
    return v == 'true' || v == '1' || v == 'yes' || v == 'on';
  }

  /// Resolves and reads `commit.template` on the active executor's host.
  /// Relative paths remain relative to the repository command's working
  /// directory; SSH repositories never consult this Mac's filesystem.
  Future<String?> commitTemplate(String repoPath) async {
    const script =
        'template=\$(git config --path --get commit.template 2>/dev/null); '
        'rc=\$?; [ \$rc -eq 1 ] && exit 0; [ \$rc -eq 0 ] || exit \$rc; '
        '[ -n "\$template" ] || exit 0; '
        'test -r "\$template" || exit 66; cat -- "\$template"';
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['sh', '-c', script],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading commit template failed', result);
    }
    final template = result.stdout.trim();
    return template.isEmpty ? null : template;
  }

  static String _fsmonitorScript({required bool enabled}) {
    if (!enabled) return 'git config core.fsmonitor false';
    // `core.fsmonitor=true` is only honored where git's fsmonitor daemon can
    // actually run — many server builds/platforms reject it outright
    // (`fatal: fsmonitor--daemon not supported on this platform`). Probe
    // first and set `false` on such hosts (also repairing repos where an
    // earlier version of this script enabled it unconditionally), so every
    // subsequent `git status` isn't paying for — or warning about — a
    // monitor that can never exist. untrackedCache/manyFiles are beneficial
    // independently of the daemon and apply either way.
    return "if git fsmonitor--daemon status 2>&1 "
        "| grep -qi 'not supported'; then "
        'git config core.fsmonitor false; '
        'else git config core.fsmonitor true; fi'
        ' && git config core.untrackedCache true'
        ' && git config feature.manyFiles true';
  }

  /// Applies [setFsmonitor] to every repo in [repoPaths] with a **single**
  /// round trip — used at connect time, where each opted-in repo used to cost
  /// its own SSH round trip before the session became usable. Best-effort per
  /// repo: one repo failing (moved, permissions) doesn't stop the others; each
  /// failure is reported on stderr as `fsmonitor setup failed: <path>` and the
  /// command itself always exits 0. Returns the raw result so the caller can
  /// log any reported failures.
  Future<SSHCommandResult> setFsmonitorMany(
    List<String> repoPaths, {
    required bool enabled,
  }) {
    final inner = _fsmonitorScript(enabled: enabled);
    // Subshell per repo so each `cd` is isolated; `|| printf … >&2` keeps the
    // sweep going and surfaces the failed path. Trailing `true` pins exit 0.
    //
    // Each subshell also pins its own scope env: a scoped repo exports its
    // GIT_DIR/GIT_WORK_TREE, an unscoped one clears any inherited overlay.
    // Without this, the funnel repo's auto-injected scope (the _run below is
    // keyed on repoPaths.first) would override every `cd` — GIT_DIR beats
    // cwd discovery — and the whole sweep's `git config` writes would land
    // in that one repo's git-dir.
    final parts = [
      for (final p in repoPaths)
        '(cd ${ShellEscaper.escape(p)} && ${_subshellScopeEnv(p)} && $inner) '
            "|| printf 'fsmonitor setup failed: %s\\n' "
            '${ShellEscaper.escape(p)} >&2',
    ];
    final script = '${parts.join('; ')}; true';
    return _run(repoPaths.first, ['sh', '-c', script], 'git config fsmonitor');
  }

  /// The shell fragment that pins [repoPath]'s scope inside one subshell of a
  /// multi-repo sweep: exports the repo's own GIT_DIR/GIT_WORK_TREE when
  /// scoped, or unsets both so no overlay inherited from the enclosing
  /// command's env can leak into an unscoped repo's git.
  String _subshellScopeEnv(String repoPath) {
    final env = _scopeEnvFor(repoPath);
    // Always clear first: a scoped repo without its own GIT_WORK_TREE must
    // not inherit the funnel repo's either.
    if (env == null) return 'unset GIT_DIR GIT_WORK_TREE';
    final exports = [
      for (final e in env.entries) '${e.key}=${ShellEscaper.escape(e.value)}',
    ].join(' ');
    return 'unset GIT_DIR GIT_WORK_TREE && export $exports';
  }

  /// Commit history for [revision] (default HEAD), most recent first, with
  /// optional filters, ANDed: [grep] (message text), [author], [since]/[until]
  /// (any git date expression), [sha] (a commit-hash prefix), and a path.
  /// [all] walks every ref instead of [revision]; [follow] tracks a single
  /// [path] across renames (file history).
  ///
  /// The two path parameters are different languages, and mixing them up is a
  /// bug either way round:
  ///   * [path] is an **exact** pathspec — one real path, spelled from the repo
  ///     root. It's what file history passes, and what `--follow` requires
  ///     (git rejects `--follow` with anything but a single pathspec).
  ///   * [pathQuery] is a **search term** a user typed. It's compiled by
  ///     [searchPathspecs] into several case-insensitive pathspecs so that a
  ///     bare filename or folder name matches at any depth — which a raw,
  ///     root-rooted pathspec never does.
  ///
  /// [grep] and [author] are likewise user terms, not regexes: they're compiled
  /// by [globToRegExp] so that regex metacharacters (`[WIP]`) match literally
  /// instead of aborting the walk, and `*`/`?` behave as glob wildcards. A
  /// multi-word [grep] becomes one `--grep` per word plus `--all-match`, so it
  /// means "mentions all of these words" rather than "contains this exact
  /// phrase".
  ///
  /// [sha] is resolved against the object database rather than filtered out of
  /// the walked rows, so a hash is found wherever it lives — on an unchecked-out
  /// branch, or far deeper than the current page. The walk is replaced by
  /// `--no-walk` over the resolved commits, so [all] and [revision] no longer
  /// apply; every other filter still narrows the result.
  ///
  /// Always requests `--topo-order`: [CommitGraph.build]'s lane algorithm
  /// requires that a commit never appears before any of its parents. Git's
  /// default is date order, which usually coincides with topological order for
  /// ordinary linear history but can diverge with clock skew, rewritten
  /// cherry-pick dates, or — especially — the multi-branch `--all` view, where
  /// commits from different branches interleave by date rather than ancestry.
  /// Without this, a parent can be emitted before some of its children, which
  /// the lane algorithm has no way to detect; it just falls back to a fresh
  /// lane, producing a visibly wrong graph (broken merge lines, spurious
  /// lanes) for exactly the histories this view exists to visualize.
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async {
    final format = ['%H', '%h', '%an', '%ae', '%aI', '%P', '%s'].join(fieldSep);

    // A `sha:` term names its commits outright, so it replaces the walk. Given
    // a prefix git can't resolve to any object, the answer is "no such commit"
    // — an empty result, not an unfiltered log.
    var noWalk = false;
    var revisions = <String>[];
    if (sha != null && sha.trim().isNotEmpty) {
      final resolved = await resolveShaPrefix(repoPath, sha);
      if (resolved.isEmpty) return const [];
      noWalk = true;
      revisions = resolved;
    } else if (!all) {
      revisions = [revision];
    }

    final grepPatterns = messageGrepPatterns(grep);
    final authorPattern = authorGrepPattern(author);
    final pathspecs = <String>[
      // Exact path (file history) — literal, so `pages/[id].tsx` is ONE
      // file's history, not a glob over its siblings. `--follow` accepts a
      // magic pathspec (verified against git 2.55). [pathQuery] stays as
      // compiled: its wildcards are the point.
      if (path != null && path.isNotEmpty) _literal(path),
      ...searchPathspecs(pathQuery),
    ];

    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        // Re-encodes commit subjects to UTF-8 for output regardless of the
        // remote's stored `i18n.commitEncoding` — see the longer explanation
        // on the `for-each-ref` call in [_fetchSnapshot].
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'log',
        '--topo-order',
        // Suppress any interleaved `gpg:`/signature lines a remote-side
        // `log.showSignature=true` would otherwise inject into the machine-read
        // output and corrupt hash/parent/date parsing.
        '--no-show-signature',
        '--pretty=format:$format$recordSep',
        '--max-count=$maxCount',
        // Drops the first [skip] matches of the *same* walk before counting, so
        // a page can be fetched without re-formatting, re-transferring and
        // re-parsing every commit above it. Git still walks the skipped prefix
        // internally — cheap, and nothing to send over the wire.
        if (skip > 0) '--skip=$skip',
        // The dialect the patterns from [globToRegExp] are written in.
        '--extended-regexp',
        if (grepPatterns.isNotEmpty || authorPattern != null)
          '--regexp-ignore-case',
        for (final pattern in grepPatterns) '--grep=$pattern',
        // Git ORs multiple `--grep`s; the words of one search are an AND.
        if (grepPatterns.length > 1) '--all-match',
        if (authorPattern != null) '--author=$authorPattern',
        if (since != null && since.trim().isNotEmpty) '--since=${since.trim()}',
        if (until != null && until.trim().isNotEmpty) '--until=${until.trim()}',
        if (noMerges) '--no-merges',
        // `--follow` is only valid with exactly one pathspec; git errors out
        // otherwise (and it also rejects `--follow --all`).
        if (follow && !all && pathspecs.length == 1) '--follow',
        if (noWalk) '--no-walk',
        if (all && !noWalk) '--all',
        if (fullHistory && !follow && !noWalk) '--full-history',
        // Everything after this is a revision/pathspec, never an option — so a
        // branch literally named `-p` (or any leading-dash ref) can't be parsed
        // as a git flag.
        '--end-of-options',
        ...revisions,
        if (pathspecs.isNotEmpty) ...['--', ...pathspecs],
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      // An unborn HEAD (a freshly initialized repo with no commits yet) makes
      // `git log` fail fatally — exit 128, `fatal: your current branch 'main'
      // does not have any commits yet` — rather than succeeding with zero
      // rows the way a filtered log with no matches does. Recognize
      // specifically that message (not every exit-128 failure — plenty of
      // other legitimate errors, e.g. an unknown revision, also exit 128) and
      // return an empty history instead of throwing, so the History view's
      // existing "no commits" empty state (rendered for `data([])`) applies
      // automatically with no UI-side special-casing.
      if (result.exitCode == 128 &&
          result.stderr.contains('does not have any commits yet')) {
        return const [];
      }
      throw GitException('git log failed', result);
    }
    final stdout = result.stdout;
    if (stdout.length > _isolateThreshold) {
      return Isolate.run(() => parseGitLog(stdout));
    }
    return parseGitLog(stdout);
  }

  /// A single file's history, following renames, with the path the file bore
  /// at each commit — see [FileHistoryEntry] for why the per-commit path is
  /// load-bearing (a diff scoped to the current name is EMPTY for commits
  /// below a rename, which silently blanked the file-history pane for exactly
  /// the renamed files `--follow` exists to handle).
  ///
  /// Same wire hardening as [log] (separator format, `--no-show-signature`,
  /// UTF-8 re-encoding, isolate-offloaded parse), plus `--name-status` to
  /// carry the per-commit name and `core.quotepath=false` so non-ASCII paths
  /// arrive unquoted (quotes forced by control bytes are undone in
  /// [parseFileHistory]).
  Future<List<FileHistoryEntry>> fileHistory(
    String repoPath,
    String path, {
    int maxCount = 200,
  }) async {
    final format = ['%H', '%h', '%an', '%ae', '%aI', '%P', '%s'].join(fieldSep);
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        '-c',
        'core.quotepath=false',
        'log',
        '--topo-order',
        '--no-show-signature',
        '--pretty=format:$format$recordSep',
        '--max-count=$maxCount',
        // `--follow` requires exactly one pathspec; it accepts a magic
        // pathspec (verified against git 2.55), so the literal form keeps a
        // path like `pages/[id].tsx` meaning one file, not a glob.
        '--follow',
        '--name-status',
        '--end-of-options',
        'HEAD',
        '--',
        _literal(path),
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      // Unborn HEAD — mirror [log]'s handling so the sheet's empty state
      // applies to a freshly initialized repo.
      if (result.exitCode == 128 &&
          result.stderr.contains('does not have any commits yet')) {
        return const [];
      }
      throw GitException('git log (file history) failed', result);
    }
    final stdout = result.stdout;
    if (stdout.length > _isolateThreshold) {
      return Isolate.run(() => parseFileHistory(stdout));
    }
    return parseFileHistory(stdout);
  }

  /// Which of [paths] git ignores — asked in one batch, over stdin, so a burst
  /// of filesystem events costs a single round trip rather than one per path.
  ///
  /// Paths are repo-root-relative and need not exist: a deleted file still has
  /// an answer, which matters because a deletion is exactly the kind of event
  /// this is asked about. A *tracked* file is never reported, even when it
  /// matches an ignore rule — which is the answer we want, since git will
  /// happily report changes to it.
  ///
  /// Exit code 1 means "none of them are ignored". That is an answer, not a
  /// failure, and conflating the two would make every unignored burst look like
  /// a broken git.
  Future<Set<String>> checkIgnore(String repoPath, List<String> paths) async {
    if (paths.isEmpty) return const {};
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      // `-z`: NUL-delimited in both directions. A path may contain any byte a
      // filesystem allows — spaces, quotes, even newlines — except NUL, so it
      // is the only framing a filename cannot forge.
      gitArgs: ['git', 'check-ignore', '-z', '--stdin'],
      stdin: paths.join('\u0000'),
      retries: _readRetries,
      lane: ExecLane.read,
    );
    // Anything other than "some are ignored" (0) or "none are" (1) — a broken
    // repo, a git that won't run — is reported as "nothing is ignored". That
    // fails *open*: the caller refreshes more than it strictly must, which is
    // the pre-existing behaviour, rather than silently ignoring real edits.
    if (result.exitCode != 0) return const {};
    return {
      for (final path in result.stdout.split('\u0000'))
        if (path.isNotEmpty) path,
    };
  }

  /// Expands a commit-hash prefix to the full object names it could mean.
  ///
  /// `git log` has no filter-by-hash-prefix flag, but it doesn't need one: the
  /// object database can be asked directly, and the answer covers the whole
  /// repository rather than whatever the current walk happened to reach.
  ///
  /// Returns every object with the prefix, which includes blobs and trees —
  /// they're left in deliberately. `git log --no-walk` ignores a non-commit
  /// object rather than failing on it, so passing them through costs nothing
  /// and saves a round trip spent asking `cat-file` for types we'd only use to
  /// discard rows git already discards.
  ///
  /// Empty for anything git can't disambiguate ([isResolvableShaPrefix]) — a
  /// non-hex term, or a prefix too short to name an object — and empty for a
  /// prefix that matches nothing. Callers read that as "no such commit".
  Future<List<String>> resolveShaPrefix(String repoPath, String sha) async {
    final prefix = sha.trim().toLowerCase();
    if (!isResolvableShaPrefix(prefix)) return const [];

    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['git', 'rev-parse', '--disambiguate=$prefix'],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    // A prefix naming nothing is an ordinary "no results", not an error worth
    // failing the whole History list over.
    if (!result.isSuccess) return const [];
    return [
      for (final line in result.stdout.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  /// HEAD's reflog — the Recovery sheet's raw material. Same wire format and
  /// hardening as [log] (separator fields, `--no-show-signature`, UTF-8
  /// re-encoding, isolate-offloaded parse). `--date=relative` makes `%gd`
  /// render as `HEAD@{2 minutes ago}` for display; recovery actions use the
  /// full hash, never the selector, so reflog-index shifting is harmless.
  Future<List<ReflogEntry>> reflog(
    String repoPath, {
    int maxCount = 200,
  }) async {
    final format = ['%H', '%h', '%gd', '%gs', '%s'].join(fieldSep);
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'reflog',
        '--no-show-signature',
        '--date=relative',
        '--format=$format$recordSep',
        '--max-count=$maxCount',
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      // A freshly initialized repo has no reflog to walk — mirror [log]'s
      // unborn-HEAD handling so the sheet's empty state applies.
      if (result.exitCode == 128 &&
          (result.stderr.contains('does not have any commits yet') ||
              result.stderr.contains('no such ref'))) {
        return const [];
      }
      throw GitException('git reflog failed', result);
    }
    final stdout = result.stdout;
    if (stdout.length > _isolateThreshold) {
      return Isolate.run(() => parseReflog(stdout));
    }
    return parseReflog(stdout);
  }

  /// Unified diff for a single file. [staged] selects the index-vs-HEAD diff
  /// (`--cached`) rather than the worktree-vs-index diff. [ignoreWhitespace]
  /// adds `-w` (hide whitespace-only changes); [context] overrides the number of
  /// surrounding context lines (`-U<n>`) for the diff viewer's expand-context.
  Future<String> diffFile(
    String repoPath, {
    required String path,
    required bool staged,
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'diff',
        '--no-color',
        if (staged) '--cached',
        if (ignoreWhitespace) '-w',
        if (context != null) '-U$context',
        '--',
        _literal(path),
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git diff failed', result);
    }
    return result.stdout;
  }

  /// Diff across a ref range for a merge-request preview — typically
  /// `target...source` (what the source branch adds since it forked from the
  /// target). [ignoreWhitespace]/[context] mirror [diffFile].
  Future<String> diffRange(
    String repoPath,
    String range, {
    bool ignoreWhitespace = false,
    int? context,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'diff',
        '--no-color',
        if (ignoreWhitespace) '-w',
        if (context != null) '-U$context',
        '--end-of-options',
        range,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git diff (range) failed', result);
    }
    return result.stdout;
  }

  /// Shows a new (untracked) file's contents as an all-additions diff against
  /// an empty file. `git diff --no-index` exits 1 when the inputs differ (which
  /// is always, here) — that is success, so only a higher code is a real error.
  Future<String> diffUntracked(String repoPath, String path) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'diff',
        '--no-index',
        '--no-color',
        '--',
        '/dev/null',
        path,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    // `--no-index` exits 1 when the inputs differ (always, here) — that's
    // success. Any other code, including the executor's -1 sentinel for a
    // killed/unresolved channel, is a real failure and must not be presented
    // as a diff.
    if (result.exitCode != 0 && result.exitCode != 1) {
      throw GitException('git diff (untracked) failed', result);
    }
    // Exit 1 with an EMPTY diff is a failure wearing success's exit code:
    // a genuine "inputs differ" always prints something (a text diff, or the
    // "Binary files … differ" line), so nothing on stdout means the diff
    // itself errored — e.g. `error: Could not access '<path>'` for a path
    // that vanished between status landing and this read (exit 1 either way,
    // verified against git 2.55). Rendering it as an empty diff showed a
    // silently blank pane; surface the error instead.
    if (result.exitCode == 1 &&
        result.stdout.isEmpty &&
        result.stderr.trim().isNotEmpty) {
      throw GitException('git diff (untracked) failed', result);
    }
    return result.stdout;
  }

  /// Full patch for a single commit (`git show`). When [path] is given, scopes
  /// the diff to that file only — used by the file-history view, where
  /// otherwise selecting a commit would fetch (and show) every file it
  /// touched, not just the one file whose history is being inspected.
  ///
  /// [context] overrides the surrounding context lines (`-U<n>`), the same knob
  /// [diffFile]/[diffRange] take. Worth having: at git's default of 3, a hunk
  /// routinely ends mid-expression, which reads as a truncated diff rather than
  /// as the end of the patch.
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        // See the `for-each-ref` call in [_fetchSnapshot] for why only
        // `logOutputEncoding` (not `commitEncoding`) is forced to UTF-8.
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'show',
        '--no-color',
        '--no-show-signature',
        if (context != null) '-U$context',
        '--end-of-options',
        hash,
        if (path != null && path.isNotEmpty) ...['--', _literal(path)],
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git show failed', result);
    }
    return result.stdout;
  }

  /// Line-by-line authorship for [path] (`git blame`) at [rev] (default the
  /// working copy). Uses `--line-porcelain` for a stable, easily-parsed format;
  /// large files are parsed in a background isolate.
  Future<List<BlameLine>> blame(
    String repoPath,
    String path, {
    String? rev,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        // See the `for-each-ref` call in [_fetchSnapshot] for why only
        // `logOutputEncoding` (not `commitEncoding`) is forced to UTF-8; blame's
        // `summary` header re-encodes the same way `log`/`show` do.
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'blame',
        '--line-porcelain',
        '--end-of-options',
        ?rev,
        // Plain path, NOT [_literal]: blame takes exactly one real path, not
        // a pathspec — no glob matching happens, and `:(literal)` is rejected
        // with "no such path" (verified against git 2.55).
        '--',
        path,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git blame failed', result);
    }
    final stdout = result.stdout;
    if (stdout.length > _isolateThreshold) {
      return Isolate.run(() => parseBlame(stdout));
    }
    return parseBlame(stdout);
  }

  /// The full working-tree contents of [path], read straight off disk (`cat`)
  /// rather than through a git object — so it reflects exactly what is on disk
  /// right now (tracked or not, staged or not), which is what a file viewer
  /// wants to show. Works identically local and over SSH: the executor runs
  /// `cat` in the repo and decodes stdout as UTF-8 with malformed bytes
  /// replaced, so a *binary* file comes back as mangled text — callers are
  /// expected to classify the result and refuse to render non-text (see
  /// `FileContent.classify`). Output past the executor's hard cap surfaces as
  /// a failure instead of ballooning memory. The `--` guards a [path] that
  /// begins with `-` from being read as a `cat` flag. (Sibling of
  /// [conflictFile], which reads the same way but is scoped to a conflicted
  /// file.)
  Future<String> readFile(String repoPath, String path) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['cat', '--', path],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading file failed', result);
    }
    return result.stdout;
  }

  /// The contents of [path] **as of [rev]** (`git show <rev>:<path>`) — the
  /// blob, not the worktree file [readFile] returns.
  ///
  /// This is what the diff viewer's context expansion reads: to show the lines
  /// around a hunk, it needs the file exactly as that commit left it. The
  /// `:`-joined form is a revision, not two arguments, so [path] must be
  /// repo-relative and `--end-of-options` guards a leading `-`.
  Future<String> showBlob(String repoPath, String rev, String path) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['git', 'show', '--no-color', '--end-of-options', '$rev:$path'],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading file at revision failed', result);
    }
    return result.stdout;
  }

  /// Binary-safe, size-bounded sibling of [showBlob] for image review.
  ///
  /// The blob size is checked on the host before base64 encoding begins, so an
  /// oversized object never crosses SSH or enters the executor's output
  /// buffer. The object spec is shell-escaped as one value and bytes travel on
  /// stdout, never argv.
  Future<String> showBlobBase64(
    String repoPath,
    String revision,
    String path, {
    int maxBytes = 12 * 1024 * 1024,
  }) async {
    final spec = ShellEscaper.escape('$revision:$path');
    final script =
        'size=\$(git cat-file -s -- $spec) || exit \$?; '
        'case "\$size" in ""|*[!0-9]*) exit 66;; esac; '
        '[ "\$size" -le $maxBytes ] || { '
        'echo "image exceeds review byte budget" >&2; exit 75; }; '
        'git cat-file blob -- $spec | base64 | tr -d \'\\r\\n\'';
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['sh', '-c', script],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading image blob failed', result);
    }
    return result.stdout;
  }

  /// Many [showBlob]s in one remote round-trip via `git cat-file --batch`.
  ///
  /// On batch failure, falls back to sequential [showBlob] (fail-open on perf).
  /// Worktree files still use [readFile] — cat-file is object-db only.
  ///
  /// **Deliberately unconsumed by the UI today** (evaluated, not an
  /// oversight): every current blob reader requests exactly one blob at a
  /// time — the diff expanders fetch lazily per click by design, and the
  /// conflict view reads the worktree file. This is the call for the first
  /// feature that genuinely needs a burst (an "expand all", multi-file
  /// prefetch, or bulk export); wiring it into the lazy paths would just
  /// re-litigate their recorded bandwidth decision. Note the UTF-8 round trip
  /// limits it to text blobs — a binary blob in the batch trips the parser
  /// and falls back to sequential (correct, slower).
  Future<Map<BlobKey, String>> showBlobsBatch(
    String repoPath,
    List<BlobKey> keys,
  ) async {
    if (keys.isEmpty) return {};
    final batch = GitCatFileBatch(_executor);
    final bytes = await batch.showBlobsBatch(
      repoPath,
      keys,
      extraEnv: _scopeEnvFor(repoPath),
      showOne: showBlob,
    );
    return {
      for (final e in bytes.entries)
        e.key: utf8.decode(e.value, allowMalformed: true),
    };
  }

  /// The raw bytes of [path], base64-encoded, for content that isn't text —
  /// images the viewer renders (`Image.memory` after decoding). Piped through
  /// `base64` (reading the file via a shell redirection, which works the same
  /// with GNU and BSD `base64`) so binary bytes survive the executor's UTF-8
  /// stdout decoding intact. The wrapping newlines GNU `base64` inserts are
  /// stripped **remote-side** with `tr -d '\r\n'`, so the caller can
  /// `base64.decode` the result directly instead of allocating a second
  /// full-size whitespace-stripped copy of the (already ~1.37×-inflated) string
  /// on the client. Oversized output trips the executor's hard cap and surfaces
  /// as a failure rather than spiking memory.
  Future<String> readFileBase64(String repoPath, String path) async {
    // A pipeline's exit status is its LAST command's, so `base64 < missing |
    // tr` exits 0 with empty output — the read failure would silently become
    // "" and render as a corrupt-image state instead of an error. Check
    // readability up front and fail the script with a real message + nonzero
    // exit before the pipeline runs.
    final q = ShellEscaper.escape(path);
    final script =
        'test -r $q || { echo "cannot read (missing or unreadable):" $q >&2; '
        "exit 66; }; base64 < $q | tr -d '\\r\\n'";
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', script],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading file bytes failed', result);
    }
    return result.stdout;
  }

  /// Bounded worktree byte read for two-sided image review. Unlike the general
  /// viewer endpoint, this checks size before encoding so holding both sides is
  /// predictably bounded.
  Future<String> readFileBase64Bounded(
    String repoPath,
    String path, {
    int maxBytes = 12 * 1024 * 1024,
  }) async {
    final q = ShellEscaper.escape(path);
    final script =
        'test -r $q || { echo "cannot read (missing or unreadable):" $q >&2; '
        'exit 66; }; size=\$(wc -c < $q) || exit \$?; '
        'case "\$size" in ""|*[!0-9]*) exit 66;; esac; '
        '[ "\$size" -le $maxBytes ] || { '
        'echo "image exceeds review byte budget" >&2; exit 75; }; '
        'base64 < $q | tr -d \'\\r\\n\'';
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', script],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading image bytes failed', result);
    }
    return result.stdout;
  }

  // ---- File tree -----------------------------------------------------------

  /// Lists the working tree for the file-view pane. Returns the non-ignored
  /// files (tracked + untracked, one `ls-files` round trip) and the ignored
  /// entries — the latter collapsing wholly-ignored directories to a single
  /// `dir/` path (via `--directory`) so a huge ignored tree never loads
  /// eagerly. Large output is split in a background isolate.
  Future<({List<String> files, List<String> ignored})> listWorkingTree(
    String repoPath,
  ) async {
    // One round trip instead of two: `&&` so a failure of the first ls-files
    // (rare — repoPath is validated at connect time) short-circuits before
    // the marker or the second call, which `_run` then reports correctly via
    // the combined script's own (now meaningful) exit code.
    const script =
        'git ls-files -z --cached --others --exclude-standard && '
        "printf '$_snapshotSep' && "
        'git ls-files -z --others --ignored --exclude-standard --directory';
    final result = await _run(
      repoPath,
      ['sh', '-c', script],
      'git ls-files',
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    final parts = result.stdout.split(_snapshotSep);
    final files = await _splitPaths(parts.isNotEmpty ? parts[0] : '');
    final ignored = await _splitPaths(parts.length > 1 ? parts[1] : '');
    return (files: files, ignored: ignored);
  }

  Future<List<String>> _splitPaths(String stdout) {
    if (stdout.length > _isolateThreshold) {
      return Isolate.run(() => splitNulPaths(stdout));
    }
    return Future.value(splitNulPaths(stdout));
  }

  /// Lists the immediate children of a collapsed ignored directory for lazy
  /// expansion. Uses a one-level filesystem listing (`ls -Ap`, dirs suffixed
  /// with `/`) since ignored content isn't in git's index; every child is
  /// itself ignored, and subdirectories stay lazily expandable.
  Future<List<RepoNode>> listIgnoredChildren(
    String repoPath,
    String dir,
  ) async {
    final res = await _run(
      repoPath,
      ['ls', '-Ap', '--', dir],
      'ls',
      retries: _readRetries,
      lane: ExecLane.read,
    );
    final nodes = <RepoNode>[];
    for (final line in res.stdout.split('\n')) {
      if (line.isEmpty) continue;
      final isDir = line.endsWith('/');
      final name = isDir ? line.substring(0, line.length - 1) : line;
      if (name.isEmpty || name == '.' || name == '..') continue;
      nodes.add(
        RepoNode(
          name: name,
          path: '$dir/$name',
          isDir: isDir,
          ignored: true,
          lazy: isDir,
        ),
      );
    }
    nodes.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return nodes;
  }

  // ---- Mutations -----------------------------------------------------------
  // All run through the serialized queue, so an index-touching write never
  // races a concurrent read. Each throws [GitException] on non-zero exit.

  /// Stages a path (`git add`).
  /// Wraps an exact path in `:(literal)` pathspec magic.
  ///
  /// Every path handed to a pathspec slot in this file names EXACTLY one file
  /// the UI showed the user — but a bare pathspec is a glob-active pattern:
  /// `*`, `?` and `[…]` all match, so `pages/[id].tsx` (a routing filename on
  /// half the JS frameworks) also matches `pages/i.tsx`, and a discard aimed
  /// at the one file destroys another file's edits — verified against git
  /// 2.55. A leading `:` is worse still: git reads it as pathspec magic and
  /// the file can't be named at all. `:(literal)` switches both off.
  ///
  /// Applies to every command that takes a *pathspec* (add, restore, clean,
  /// checkout, diff, show, blame, log). It must NOT be used where git expects
  /// a plain path or a real file (`diff --no-index`, `rm`, `cat`), and not
  /// where the caller's input is deliberately a pattern ([log]'s search
  /// pathspecs, [copyIgnoredFiles]' globs).
  static String _literal(String path) => ':(literal)$path';

  Future<void> stage(String repoPath, String path) =>
      _runVoid(repoPath, ['git', 'add', '--', _literal(path)], 'git add');

  /// Stages every path in [paths] with a single `git add` invocation —
  /// the multi-select bulk equivalent of [stage].
  Future<void> stageMany(String repoPath, List<String> paths) => _runVoid(
    repoPath,
    ['git', 'add', '--', ...paths.map(_literal)],
    'git add',
  );

  /// Applies a unified-diff [patch] via `git apply`, reading it from stdin (so it
  /// never touches argv). [cached] targets the index (staging); [reverse] applies
  /// it backwards (unstaging, or discarding a worktree hunk). Used for hunk-level
  /// staging — never retried, since applying twice would corrupt the tree.
  Future<void> applyPatch(
    String repoPath,
    String patch, {
    required bool cached,
    required bool reverse,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'apply',
        if (cached) '--cached',
        if (reverse) '-R',
        '--recount',
        '--whitespace=nowarn',
        '-',
      ],
      stdin: patch,
    );
    if (!result.isSuccess) {
      throw GitException('git apply failed', result);
    }
  }

  /// Applies a structurally validated line/range patch to the index. Kept as a
  /// distinct endpoint so line staging cannot silently acquire retry or
  /// worktree semantics if the general hunk endpoint evolves.
  Future<void> applySelectionPatch(
    String repoPath,
    String patch, {
    required bool reverse,
  }) => applyPatch(repoPath, patch, cached: true, reverse: reverse);

  /// Discards a single worktree hunk by reverse-applying [patch] — the
  /// hunk-scoped sibling of [discard], with the same flavor-A snapshot taken
  /// in the same invocation so ⌘Z brings the pre-discard content back. Plain
  /// [applyPatch] deliberately records nothing (staging moves content between
  /// index and worktree, destroying neither); a worktree discard is the one
  /// apply that destroys, so it is the one that snapshots.
  ///
  /// [path] is the file the hunk belongs to. Undo restores that file from
  /// the snapshot whole — the same granularity every other path-scoped undo
  /// uses, and the honest one: the hunk's surroundings may have changed since,
  /// and a textual re-apply could land in the wrong place silently.
  Future<void> discardHunk(
    String repoPath,
    String patch, {
    required String path,
  }) async {
    final refName = _newSnapshotRef();
    await _runCaptured(
      repoPath,
      ['git', 'apply', '-R', '--recount', '--whitespace=nowarn', '-'],
      'git apply',
      stdin: patch,
      extraCaptures: [_snapshotCaptureA(refName)],
      record: (c) => c.extras[0].isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.discardPaths,
              description: 'Discard of a hunk in $path',
              snapshotOid: c.extras[0],
              paths: [path],
            ),
    );
  }

  /// Destructive line/range sibling of [applySelectionPatch]. It reuses the
  /// atomic snapshot + reverse-apply transaction and therefore records an
  /// ordinary path-scoped undo entry before changing the worktree.
  Future<void> discardSelectionPatch(
    String repoPath,
    String patch, {
    required String path,
  }) => discardHunk(repoPath, patch, path: path);

  /// Stages everything (`git add -A`).
  Future<void> stageAll(String repoPath) =>
      _runVoid(repoPath, ['git', 'add', '-A'], 'git add -A');

  /// Unstages everything, leaving every working-tree change intact — the
  /// mirror of [stageAll]. A bare `git reset` rather than `restore --staged
  /// :/`: they are equivalent on a normal HEAD, but only reset also works on
  /// an unborn one (first commit being assembled), where restore fails with
  /// "could not resolve 'HEAD'" — verified against git 2.55.
  Future<void> unstageAll(String repoPath) =>
      _runVoid(repoPath, ['git', 'reset', '-q'], 'git reset');

  /// Unstages a path, leaving the working-tree change intact
  /// (`git restore --staged`).
  Future<void> unstage(String repoPath, String path) => _runVoid(repoPath, [
    'git',
    'restore',
    '--staged',
    '--',
    _literal(path),
  ], 'git restore');

  /// Unstages every path in [paths] with a single invocation — the
  /// multi-select bulk equivalent of [unstage].
  Future<void> unstageMany(String repoPath, List<String> paths) => _runVoid(
    repoPath,
    ['git', 'restore', '--staged', '--', ...paths.map(_literal)],
    'git restore',
  );

  /// Commits the staged changes.
  ///
  /// If [message] is non-empty it is committed with `-m`. If it is null/empty,
  /// git runs with no message and `GIT_EDITOR=true`, so a `prepare-commit-msg`
  /// hook (e.g. an AI generator) writes the message and the empty "editor"
  /// accepts it non-interactively. `--no-gpg-sign` avoids a failure on repos
  /// with `commit.gpgsign=true` (no GPG agent over the SSH exec channel).
  Future<void> commit(String repoPath, {String? message}) async {
    final args = ['git', ..._idArgs, 'commit', '--no-gpg-sign'];
    if (message != null && message.trim().isNotEmpty) {
      args.addAll(['-m', message]);
    }
    // A prepare-commit-msg hook may invoke a slow AI generator — allow generous
    // headroom so a legitimately slow commit isn't killed as if it hung.
    await _runCaptured(
      repoPath,
      args,
      'git commit',
      timeout: commitTimeout,
      // The very first commit on an unborn branch has no pre-state to reset
      // back to — not undoable.
      record: (c) => c.preHead.isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.commit,
              description: 'Commit',
            ),
    );
  }

  /// Runs the `prepare-commit-msg` hook against a scratch message file and
  /// returns the message it produces, so the UI can preview (and let the user
  /// edit or accept) an auto-generated message *before* committing. Returns null
  /// when no hook is installed or it wrote nothing.
  ///
  /// Uses a throwaway file under the git dir — never `COMMIT_EDITMSG` — so it
  /// can't disturb an in-progress commit. `mktemp` gives it a unique,
  /// unpredictable name created atomically with owner-only permissions: a
  /// fixed filename here would let another local user (or a second, racing
  /// invocation of this same call) pre-plant a symlink or a file at that path
  /// before the hook writes to it. The hook may invoke a slow AI generator, so
  /// this gets the commit timeout.
  Future<String?> generateCommitMessage(String repoPath) async {
    // Exit 3 signals "no hook" so we can fall back to manual entry. The hook's
    // own stdout/stderr are discarded; only the message file content is emitted.
    const script =
        // Prefer core.hooksPath; otherwise resolve the hooks dir via
        // `git rev-parse --git-path hooks` (respecting core.hooksPath first) so
        // a linked worktree/submodule — where `.git` is a file — still finds it.
        'hp=\$(git config --get core.hooksPath 2>/dev/null); '
        '[ -n "\$hp" ] || hp=\$(git rev-parse --git-path hooks 2>/dev/null || echo .git/hooks); '
        'hook="\$hp/prepare-commit-msg"; '
        '[ -x "\$hook" ] || exit 3; '
        'dir=\$(git rev-parse --git-dir 2>/dev/null || echo .git); '
        'tmp=\$(mktemp "\$dir/MAGICGIT_MSG_PREVIEW.XXXXXX") || exit 1; '
        '"\$hook" "\$tmp" </dev/null >/dev/null 2>&1 || true; '
        'sed -e /^#/d "\$tmp"; '
        'rm -f "\$tmp"';
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['sh', '-c', script],
      timeout: commitTimeout,
    );
    if (result.exitCode == 3) return null; // no prepare-commit-msg hook
    if (!result.isSuccess) {
      throw GitException('generating commit message failed', result);
    }
    final msg = result.stdout.trim();
    return msg.isEmpty ? null : msg;
  }

  /// Checks out a branch or ref (`git checkout`). `--end-of-options` stops a
  /// [ref] that happens to start with `-` (a branch named e.g. `-d`) from
  /// being parsed as a flag — plain `--` isn't safe here since checkout gives
  /// it pathspec-separator meaning, not just "end of options".
  Future<void> checkout(String repoPath, String ref) async {
    await _runCaptured(
      repoPath,
      ['git', 'checkout', '--end-of-options', ref],
      'git checkout',
      // From an unborn branch there is nothing checked out to return to.
      record: (c) => c.preHead.isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.checkout,
              description: 'Checkout of $ref',
            ),
    );
  }

  /// Creates a local branch [localName] tracking [remoteRef] (e.g.
  /// `origin/feature`) and checks it out — the EXPLICIT spelling of what a
  /// bare `git checkout <localName>` only achieves by DWIM guesswork.
  ///
  /// DWIM silently does the wrong thing exactly when [localName] already
  /// resolves as another ref: a tag of the same name makes `git checkout`
  /// detach HEAD onto the tag instead of creating the tracking branch, and
  /// two remotes carrying the branch make it ambiguous (a hard error). Naming
  /// the upstream outright (`switch -c … --track <remote>/<branch>`) removes
  /// the guesswork. Callers use this only when no local branch of the name
  /// exists yet; when one does, a plain [checkout] switches to it.
  Future<void> checkoutTrackingBranch(
    String repoPath, {
    required String localName,
    required String remoteRef,
  }) async {
    await _runCaptured(
      repoPath,
      // `--create <name>` consumes [localName] as its value verbatim (like the
      // `-b` in [createBranch]) — so no `--end-of-options` is needed or valid
      // here, and a leading-dash [localName] is already rejected by git's ref
      // format. [remoteRef] is `--track`'s positional start-point (always
      // `<remote>/<branch>`, never flag-shaped).
      ['git', 'switch', '--create', localName, '--track', remoteRef],
      'git switch --track',
      record: (c) => c.preHead.isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.checkout,
              description: 'Checkout tracking branch $localName',
            ),
    );
  }

  /// Local branches fully merged into the current HEAD (`git branch --merged`)
  /// — one cheap read used only for a HEAD-relative informational badge.
  /// This is **not** a base-relative or "safe to delete" signal; Review uses
  /// [branchReviewSummaries] for comparison against an explicit base.
  /// Returns short names (the current branch, which is trivially merged into
  /// itself, is included — callers filter it by [GitRef.isHead]). Throws like
  /// any read on failure; the provider swallows it so a badge never breaks the
  /// list.
  Future<Set<String>> mergedBranchNames(String repoPath) async {
    final result = await _run(
      repoPath,
      ['git', 'branch', '--merged', '--format=%(refname:short)'],
      'git branch --merged',
      lane: ExecLane.read,
    );
    return {
      for (final line in result.stdout.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    };
  }

  /// Symbolic target of `refs/remotes/<remote>/HEAD`, or null when the remote
  /// has no advertised HEAD symref. The ref is one argv element, never shell
  /// interpolation.
  Future<String?> remoteHead(String repoPath, String remote) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['git', 'symbolic-ref', '--quiet', 'refs/remotes/$remote/HEAD'],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    final target = result.stdout.trim();
    if (result.exitCode == 1 && target.isEmpty) return null;
    if (!result.isSuccess ||
        !target.startsWith('refs/remotes/$remote/') ||
        target == 'refs/remotes/$remote/HEAD') {
      throw GitException('Could not resolve remote HEAD', result);
    }
    return target;
  }

  /// Phase 7: base-relative Review summary batch size. Sequential batches of
  /// this many tips per host invocation; never client-side per-branch SSH.
  /// Tuned 2026-08 for the 500-ref fixture (≤ ceil(n/100) host calls).
  static const int branchReviewBatchSize = 100;

  /// Phase 7: per-batch host timeout for [branchReviewSummaries].
  static const Duration branchReviewBatchTimeout = Duration(seconds: 60);
  static const String _branchReviewFieldSep = '\u001f';

  /// Base-relative divergence for local branch tips. Ref names never enter the
  /// host script; rows join back through captured ordinal + immutable OID.
  Future<BranchReviewBatchResult> branchReviewSummaries(
    String repoPath, {
    required String baseOid,
    required List<({String refName, String oid})> branches,
  }) async {
    if (!isFullGitOid(baseOid)) {
      throw ArgumentError.value(baseOid, 'baseOid', 'must be a full Git OID');
    }
    for (final branch in branches) {
      if (!isFullGitOid(branch.oid)) {
        throw ArgumentError.value(
          branch.oid,
          'branches',
          'branch OIDs must be full Git OIDs',
        );
      }
    }

    final summaries = <String, BranchReviewSummary>{};
    final failures = <String, BranchReviewFailure>{};
    for (
      var start = 0;
      start < branches.length;
      start += branchReviewBatchSize
    ) {
      final end = (start + branchReviewBatchSize).clamp(0, branches.length);
      final batch = branches.sublist(start, end);
      final parsed = await _branchReviewBatch(repoPath, baseOid, batch);
      summaries.addAll(parsed.summariesByRefName);
      failures.addAll(parsed.failuresByRefName);
    }
    return BranchReviewBatchResult(
      summariesByRefName: summaries,
      failuresByRefName: failures,
    );
  }

  Future<BranchReviewBatchResult> _branchReviewBatch(
    String repoPath,
    String baseOid,
    List<({String refName, String oid})> branches,
  ) async {
    const script = r'''
base=$1
shift
ordinal=0
for oid in "$@"; do
  counts=$(git rev-list --left-right --count "$base...$oid")
  status=$?
  behind=
  ahead=
  if [ "$status" -eq 0 ]; then
    set -- $counts
    behind=${1-}
    ahead=${2-}
  fi
  printf '%s\037%s\037%s\037%s\037%s\000' \
    "$ordinal" "$oid" "$status" "$behind" "$ahead"
  ordinal=$((ordinal + 1))
done
''';
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: {...?_scopeEnvFor(repoPath), 'LC_ALL': 'C'},
      gitArgs: [
        'sh',
        '-c',
        script,
        'branch-review',
        baseOid,
        ...branches.map((branch) => branch.oid),
      ],
      timeout: branchReviewBatchTimeout,
      retries: 0,
      lane: ExecLane.read,
    );
    if (!result.isSuccess) {
      throw GitException('Branch review summary failed', result);
    }
    return _parseBranchReviewBatch(baseOid, branches, result.stdout);
  }

  BranchReviewBatchResult _parseBranchReviewBatch(
    String baseOid,
    List<({String refName, String oid})> branches,
    String raw,
  ) {
    final summaries = <String, BranchReviewSummary>{};
    final failures = <String, BranchReviewFailure>{};
    final seen = <int>{};

    void fail(int ordinal, String code) {
      if (ordinal < 0 || ordinal >= branches.length) return;
      final branch = branches[ordinal];
      failures[branch.refName] = BranchReviewFailure(
        refName: branch.refName,
        branchOid: branch.oid,
        reasonCode: code,
      );
      summaries.remove(branch.refName);
    }

    for (final record in raw.split('\u0000')) {
      if (record.isEmpty) continue;
      final fields = record.split(_branchReviewFieldSep);
      final ordinal = fields.isEmpty ? null : int.tryParse(fields[0]);
      if (ordinal == null || ordinal < 0 || ordinal >= branches.length) {
        continue;
      }
      if (!seen.add(ordinal)) {
        fail(ordinal, 'duplicateRecord');
        continue;
      }
      if (fields.length != 5) {
        fail(ordinal, 'malformedRecord');
        continue;
      }
      final branch = branches[ordinal];
      if (fields[1] != branch.oid) {
        fail(ordinal, 'oidMismatch');
        continue;
      }
      final status = int.tryParse(fields[2]);
      if (status == null) {
        fail(ordinal, 'malformedStatus');
        continue;
      }
      if (status != 0) {
        fail(ordinal, 'revListFailed');
        continue;
      }
      final behind = int.tryParse(fields[3]);
      final ahead = int.tryParse(fields[4]);
      if (behind == null || behind < 0 || ahead == null || ahead < 0) {
        fail(ordinal, 'malformedCounts');
        continue;
      }
      summaries[branch.refName] = BranchReviewSummary(
        refName: branch.refName,
        shortName: branch.refName.replaceFirst('refs/heads/', ''),
        branchOid: branch.oid,
        baseOid: baseOid,
        aheadOfBase: ahead,
        behindBase: behind,
      );
    }
    for (var ordinal = 0; ordinal < branches.length; ordinal++) {
      if (!seen.contains(ordinal)) fail(ordinal, 'missingRecord');
    }
    return BranchReviewBatchResult(
      summariesByRefName: summaries,
      failuresByRefName: failures,
    );
  }

  /// Section markers for [branchComparisonMetadata]'s combined host script.
  /// Same STX-bracketed style as [_snapshotSep]: paths may contain almost any
  /// byte except NUL, so a collision falls back to separate invocations.
  static const String _comparisonSep = '\u0002RMGCMP\u0002';

  /// Maximum files listed in comparison metadata before [truncated] is set.
  static const int branchComparisonMaxFiles = kBranchComparisonMaxFiles;

  /// Three-dot comparison stats for [baseOid]...[branchOid]: merge base,
  /// per-file name-status + numstat, aggregates. Unrelated histories return
  /// [ComparisonAncestry.unrelated] without running the three-dot diff.
  Future<BranchComparisonMetadata> branchComparisonMetadata(
    String repoPath, {
    required String baseOid,
    required String branchOid,
    int maxFiles = branchComparisonMaxFiles,
  }) async {
    if (!isFullGitOid(baseOid)) {
      throw ArgumentError.value(baseOid, 'baseOid', 'must be a full Git OID');
    }
    if (!isFullGitOid(branchOid)) {
      throw ArgumentError.value(
        branchOid,
        'branchOid',
        'must be a full Git OID',
      );
    }

    final mb = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['git', 'merge-base', '--end-of-options', baseOid, branchOid],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    final mbOut = mb.stdout.trim();
    if (mb.exitCode == 1 && mbOut.isEmpty) {
      return BranchComparisonMetadata.unrelated(
        baseOid: baseOid,
        branchOid: branchOid,
      );
    }
    if (!mb.isSuccess || !isFullGitOid(mbOut)) {
      throw GitException('git merge-base failed', mb);
    }
    final mergeBaseOid = mbOut;

    // Combined name-status + numstat with section markers. On framing failure,
    // fall back to two separate marker-free reads.
    const rangeSep = '...';
    final range = '$baseOid$rangeSep$branchOid';
    const sep = _comparisonSep;
    final combined = await _executor.execute(
      repoPath: repoPath,
      extraEnv: {...?_scopeEnvFor(repoPath), 'LC_ALL': 'C'},
      gitArgs: [
        'sh',
        '-c',
        r'''
base=$1; branch=$2; sep=$3
printf '%s' "$sep"
printf 'NS\n'
git diff --name-status -z --find-renames --end-of-options "$base...$branch"
ns=$?
printf '%s' "$sep"
printf 'NU\n'
git diff --numstat -z --find-renames --end-of-options "$base...$branch"
nu=$?
printf '%s' "$sep"
printf 'EC\n%d %d\n' "$ns" "$nu"
''',
        'branch-cmp',
        baseOid,
        branchOid,
        sep,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!combined.isSuccess) {
      throw GitException('branch comparison metadata failed', combined);
    }

    late String nameStatus;
    late String numstat;
    final parts = combined.stdout.split(sep);
    // Expect: [prefix?] NS…, NU…, EC…
    final bodies = [
      for (final p in parts)
        if (p.startsWith('NS\n') ||
            p.startsWith('NU\n') ||
            p.startsWith('EC\n'))
          p,
    ];
    if (bodies.length == 3 &&
        bodies[0].startsWith('NS\n') &&
        bodies[1].startsWith('NU\n') &&
        bodies[2].startsWith('EC\n')) {
      nameStatus = bodies[0].substring(3);
      numstat = bodies[1].substring(3);
      final codes = bodies[2].substring(3).trim().split(RegExp(r'\s+'));
      final ns = int.tryParse(codes.isNotEmpty ? codes[0] : '');
      final nu = int.tryParse(codes.length > 1 ? codes[1] : '');
      // git diff exits 0 even when there are changes; non-zero is real failure.
      if (ns != 0 || nu != 0) {
        final separate = await _branchComparisonMetadataSeparate(
          repoPath,
          range,
        );
        nameStatus = separate.$1;
        numstat = separate.$2;
      }
    } else {
      final separate = await _branchComparisonMetadataSeparate(repoPath, range);
      nameStatus = separate.$1;
      numstat = separate.$2;
    }

    if (nameStatus.length + numstat.length > _isolateThreshold) {
      return Isolate.run(
        () => assembleComparisonMetadata(
          baseOid: baseOid,
          branchOid: branchOid,
          mergeBaseOid: mergeBaseOid,
          nameStatusZ: nameStatus,
          numstatZ: numstat,
          maxFiles: maxFiles,
        ),
      );
    }
    return assembleComparisonMetadata(
      baseOid: baseOid,
      branchOid: branchOid,
      mergeBaseOid: mergeBaseOid,
      nameStatusZ: nameStatus,
      numstatZ: numstat,
      maxFiles: maxFiles,
    );
  }

  Future<(String, String)> _branchComparisonMetadataSeparate(
    String repoPath,
    String range,
  ) async {
    final ns = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'diff',
        '--name-status',
        '-z',
        '--find-renames',
        '--end-of-options',
        range,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!ns.isSuccess) {
      throw GitException('git diff --name-status failed', ns);
    }
    final nu = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'diff',
        '--numstat',
        '-z',
        '--find-renames',
        '--end-of-options',
        range,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!nu.isSuccess) {
      throw GitException('git diff --numstat failed', nu);
    }
    return (ns.stdout, nu.stdout);
  }

  /// Per-repo chain so only one [mergeTreePreview] runs at a time for a given
  /// path (Phase 3 concurrency gate). Independent repos proceed in parallel.
  /// Each entry's completer is completed when that invocation finishes; the
  /// next waiter awaits it before starting.
  static final Map<String, Completer<void>> _mergeTreeGates = {};

  /// Local conflict prediction via modern `git merge-tree --write-tree`.
  ///
  /// Does **not** touch HEAD, refs, the index, or the worktree. Git may still
  /// write unreachable tree objects into the object database (expected; object
  /// count may grow). Requires Git ≥ 2.38 — callers must gate capability first.
  ///
  /// [baseOid] is the branch being merged *into*; [branchOid] is the tip being
  /// merged. Unrelated histories are detected with `merge-base` and return
  /// [MergePreviewState.unrelated] without invoking merge-tree.
  Future<BranchMergePreview> mergeTreePreview(
    String repoPath, {
    required String baseOid,
    required String branchOid,
  }) async {
    if (!isFullGitOid(baseOid)) {
      throw ArgumentError.value(baseOid, 'baseOid', 'must be a full Git OID');
    }
    if (!isFullGitOid(branchOid)) {
      throw ArgumentError.value(
        branchOid,
        'branchOid',
        'must be a full Git OID',
      );
    }

    final previous = _mergeTreeGates[repoPath];
    final mine = Completer<void>();
    _mergeTreeGates[repoPath] = mine;
    if (previous != null) {
      await previous.future;
    }
    try {
      return await _mergeTreePreviewUnlocked(
        repoPath,
        baseOid: baseOid,
        branchOid: branchOid,
      );
    } finally {
      mine.complete();
      if (identical(_mergeTreeGates[repoPath], mine)) {
        _mergeTreeGates.remove(repoPath);
      }
    }
  }

  Future<BranchMergePreview> _mergeTreePreviewUnlocked(
    String repoPath, {
    required String baseOid,
    required String branchOid,
  }) async {
    final mb = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['git', 'merge-base', '--end-of-options', baseOid, branchOid],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    final mbOut = mb.stdout.trim();
    if (mb.exitCode == 1 && mbOut.isEmpty) {
      return BranchMergePreview.unrelated();
    }
    if (!mb.isSuccess || !isFullGitOid(mbOut)) {
      throw GitException('git merge-base failed', mb);
    }

    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'merge-tree',
        '--write-tree',
        '--name-only',
        '-z',
        '--no-messages',
        '--end-of-options',
        baseOid,
        branchOid,
      ],
      retries: 0, // prediction must not auto-retry loops
      lane: ExecLane.read,
    );
    if (result.exitCode != 0 && result.exitCode != 1) {
      throw GitException('git merge-tree failed', result);
    }
    try {
      return parseMergeTreeOutput(
        exitCode: result.exitCode,
        stdout: result.stdout,
      );
    } on FormatException catch (e) {
      throw GitException('git merge-tree output malformed: $e', result);
    }
  }

  /// Creates a branch, optionally checking it out.
  ///
  /// The checkout form deliberately has no `--end-of-options` before [name]:
  /// `-b` consumes its next token verbatim as the branch name, so the guard
  /// itself would *become* the name (`fatal: a branch '--end-of-options'
  /// cannot be created`) — and a leading-dash [name] is already safe, since
  /// git rejects it as an invalid ref format rather than parsing it as a
  /// flag. The plain `git branch` form takes [name] positionally and keeps
  /// the guard.
  Future<void> createBranch(
    String repoPath,
    String name, {
    bool checkout = true,
  }) => _createBranchCaptured(
    repoPath,
    checkout
        ? ['git', 'checkout', '-b', name]
        : ['git', 'branch', '--end-of-options', name],
    name: name,
    checkedOut: checkout,
    startPoint: null,
  );

  /// Shared undo capture for [createBranch]/[branchFrom]: undo deletes the
  /// created branch (validating its tip hasn't moved since creation) and,
  /// when the creation checked it out, returns to the previous branch first.
  ///
  /// The created tip is known without a post-mutation capture: it's HEAD
  /// after a checkout creation, and the (pre-resolved) start point — or the
  /// unchanged pre-op HEAD — otherwise.
  Future<void> _createBranchCaptured(
    String repoPath,
    List<String> mutation, {
    required String name,
    required bool checkedOut,
    required String? startPoint,
  }) async {
    await _runCaptured(
      repoPath,
      mutation,
      'git branch',
      extraCaptures: [
        if (startPoint != null)
          'git rev-parse -q --verify '
              '${ShellEscaper.escape('$startPoint^{commit}')}',
      ],
      record: (c) {
        final createdOid = checkedOut
            ? c.postHead
            : (startPoint != null ? c.extras[0] : c.preHead);
        return createdOid.isEmpty
            ? null
            : c.toRecord(
                repoPath: repoPath,
                kind: UndoOpKind.createBranch,
                description: 'Creation of branch $name',
                refName: name,
                deletedOid: createdOid,
              );
      },
    );
  }

  /// Deletes a local branch. [force] uses `-D` (discard unmerged commits).
  /// Undo recreates the branch at its captured tip; upstream/tracking config
  /// is not restored.
  Future<void> deleteBranch(
    String repoPath,
    String name, {
    bool force = false,
  }) async {
    await _runCaptured(
      repoPath,
      ['git', 'branch', force ? '-D' : '-d', '--end-of-options', name],
      'git branch -d',
      extraCaptures: [
        'git rev-parse -q --verify ${ShellEscaper.escape('refs/heads/$name')}',
      ],
      record: (c) => c.extras[0].isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.deleteBranch,
              description: 'Deletion of branch $name',
              refName: name,
              deletedOid: c.extras[0],
            ),
    );
  }

  /// Moves a local branch tip to [targetOid] (`git branch -f`). Undo restores
  /// the previous tip. Used by DnD E1 (branch label → commit).
  Future<void> moveBranch(
    String repoPath,
    String name,
    String targetOid,
  ) async {
    await _runCaptured(
      repoPath,
      ['git', 'branch', '-f', '--end-of-options', name, targetOid],
      'git branch -f',
      extraCaptures: [
        'git rev-parse -q --verify ${ShellEscaper.escape('refs/heads/$name')}',
      ],
      record: (c) => c.extras[0].isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.deleteBranch,
              description: 'Move branch $name',
              refName: name,
              deletedOid: c.extras[0],
            ),
    );
  }

  /// OID-pinned base-safe local branch delete for Review bulk cleanup.
  ///
  /// Does **not** force-delete a non-ancestor. Expected decisions (moved,
  /// notMerged, checkedOut, missing) return [BaseDeleteResult] with exit 0;
  /// unexpected transport/Git failures throw [GitException]. An undo record is
  /// created only when this invocation actually deleted the tip.
  Future<BaseDeleteResult> deleteBranchMergedIntoBase(
    String repoPath, {
    required String branchName,
    required String expectedBranchOid,
    required String baseOid,
  }) async {
    if (branchName.isEmpty ||
        branchName.contains(RegExp(r'[\s~^:?*\[\\]')) ||
        branchName.contains('..') ||
        branchName.startsWith('-')) {
      throw ArgumentError.value(
        branchName,
        'branchName',
        'invalid local branch name',
      );
    }
    if (!isFullGitOid(expectedBranchOid)) {
      throw ArgumentError.value(
        expectedBranchOid,
        'expectedBranchOid',
        'must be a full Git OID',
      );
    }
    if (!isFullGitOid(baseOid)) {
      throw ArgumentError.value(baseOid, 'baseOid', 'must be a full Git OID');
    }

    final fullRef = 'refs/heads/$branchName';
    final refQ = ShellEscaper.escape(fullRef);
    final oidQ = ShellEscaper.escape(expectedBranchOid);
    final baseQ = ShellEscaper.escape(baseOid);

    // Subshell so `exit` does not abort _runCaptured's post-capture prologue.
    // Status tokens on stdout; exit 0 for all expected decisions.
    final script =
        '('
        'set +e; '
        'ref=$refQ; '
        'want=$oidQ; '
        'base=$baseQ; '
        'tip=\$(git rev-parse -q --verify "\$ref^{commit}" 2>/dev/null || true); '
        'if [ -z "\$tip" ]; then printf "missing\\n"; exit 0; fi; '
        'if [ "\$tip" != "\$want" ]; then printf "moved\\n"; exit 0; fi; '
        'held=\$(git for-each-ref --format="%(worktreepath)" --count=1 -- "\$ref" 2>/dev/null || true); '
        'if [ -n "\$held" ]; then printf "checkedOut\\n"; exit 0; fi; '
        'git merge-base --is-ancestor "\$want" "\$base" >/dev/null 2>&1; '
        'anc=\$?; '
        'if [ "\$anc" -ne 0 ]; then printf "notMerged\\n"; exit 0; fi; '
        'git update-ref -d "\$ref" "\$want" >/dev/null 2>&1; '
        'if [ \$? -ne 0 ]; then printf "moved\\n"; exit 0; fi; '
        'printf "deleted\\n"; '
        'exit 0'
        ')';

    final tipCapture =
        'git rev-parse -q --verify ${ShellEscaper.escape('$fullRef^{commit}')} 2>/dev/null || true';

    final result = await _runCaptured(
      repoPath,
      const [],
      'base-safe delete $branchName',
      mutationScript: script,
      extraCaptures: [tipCapture],
      postCaptures: [tipCapture],
      record: (c) {
        // Only journal when pre-tip matched the expected OID and post is gone.
        final pre = c.extras.isNotEmpty ? c.extras[0].trim() : '';
        final post = c.postExtras.isNotEmpty ? c.postExtras[0].trim() : '';
        if (pre != expectedBranchOid || post.isNotEmpty) return null;
        return c.toRecord(
          repoPath: repoPath,
          kind: UndoOpKind.deleteBranch,
          description: 'Deletion of branch $branchName',
          refName: branchName,
          deletedOid: expectedBranchOid,
        );
      },
    );

    final token = result.stdout
        .trim()
        .split('\n')
        .lastWhere((l) => l.isNotEmpty, orElse: () => '');
    // record() does not expose mutation stdout; re-parse token from cleaned out.
    final status = parseBaseDeleteStatusToken(token);
    // Only journal on deleted — record callback already enforced OID match.
    // If status is deleted but record was skipped (race), still report deleted.
    return BaseDeleteResult(
      branchName: branchName,
      status: status,
      deletedOid: status == BaseDeleteStatus.deleted ? expectedBranchOid : null,
    );
  }

  /// Renames a local branch (`git branch -m`). git carries the reflog and
  /// upstream config across, and updates the HEAD of any worktree that has
  /// the branch checked out — so this is safe for the current branch and for
  /// one held elsewhere alike. Not journaled: nothing is destroyed, and
  /// renaming back IS the undo.
  Future<void> renameBranch(String repoPath, String oldName, String newName) =>
      _runVoid(repoPath, [
        'git',
        'branch',
        '-m',
        '--end-of-options',
        oldName,
        newName,
      ], 'git branch -m');

  /// Points [branch]'s upstream at [upstream] (e.g. `origin/main`) —
  /// `git branch --set-upstream-to`. Pure config (`branch.<name>.remote` /
  /// `.merge`): nothing is destroyed, so not journaled — setting it back IS
  /// the undo. The `=` form keeps a leading-dash [upstream] out of option
  /// position; `--end-of-options` guards the branch positional.
  Future<void> setUpstream(String repoPath, String branch, String upstream) =>
      _runVoid(repoPath, [
        'git',
        'branch',
        '--set-upstream-to=$upstream',
        '--end-of-options',
        branch,
      ], 'git branch --set-upstream-to');

  /// Removes [branch]'s upstream config (`git branch --unset-upstream`) —
  /// the counterpart of [setUpstream], same not-journaled reasoning.
  Future<void> unsetUpstream(String repoPath, String branch) => _runVoid(
    repoPath,
    ['git', 'branch', '--unset-upstream', '--end-of-options', branch],
    'git branch --unset-upstream',
  );

  /// Deletes [branch] on [remote] (`git push --delete`) — the remote sibling
  /// of [deleteBranch]. Deliberately NOT journaled: the commits may exist
  /// nowhere but the remote, and resurrecting a remote ref is a push the
  /// user must own — the caller's confirm dialog is the guard.
  Future<SSHCommandResult> deleteRemoteBranch(
    String repoPath,
    String remote,
    String branch,
  ) async {
    final auth = await _forgeAuthArgs(repoPath, remote: remote);
    return _run(
      repoPath,
      ['git', ...auth, 'push', '--delete', '--end-of-options', remote, branch],
      'git push --delete',
      timeout: _networkCeiling,
      activityIdle: networkTimeout,
      // Sync lane, like every push: updates the remote and the local tracking
      // ref, never the index/worktree.
      lane: ExecLane.sync,
    );
  }

  /// Discards working-tree changes to a path (`git restore`). Undoable via a
  /// pre-op snapshot — see [_discardCaptured].
  Future<void> discard(String repoPath, String path) =>
      _discardCaptured(repoPath, [path]);

  /// Discards working-tree changes to every path in [paths] with a single
  /// invocation — the multi-select bulk equivalent of [discard].
  Future<void> discardMany(String repoPath, List<String> paths) =>
      _discardCaptured(repoPath, paths);

  /// A flavor-A snapshot (worktree + index trees) is taken in the same shell
  /// invocation, immediately before the restore destroys the content; undo
  /// restores exactly [paths] from it. An empty snapshot field (unborn HEAD,
  /// conflicted index — `stash create` refused) means the discard proceeds
  /// without a ⌘Z net, as before this feature existed.
  Future<void> _discardCaptured(String repoPath, List<String> paths) async {
    final refName = _newSnapshotRef();
    await _runCaptured(
      repoPath,
      ['git', 'restore', '--', ...paths.map(_literal)],
      'git restore',
      extraCaptures: [_snapshotCaptureA(refName)],
      record: (c) => c.extras[0].isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.discardPaths,
              description: paths.length == 1
                  ? 'Discard of ${paths.single}'
                  : 'Discard of ${paths.length} files',
              snapshotOid: c.extras[0],
              paths: paths,
            ),
    );
  }

  /// Removes a single untracked file from the working tree. Deliberately
  /// scoped to exactly [path] (`git clean -f --`, not a blanket `-fd` sweep):
  /// `git clean` already refuses to touch anything git tracks, so this can
  /// only ever delete the one untracked file the caller asked for. `--`
  /// (rather than `--end-of-options`) matches how every other path argument
  /// in this file is hardened against a leading `-` — see [discard]/[stage].
  /// Undoable via a flavor-B snapshot — see [_removeCaptured].
  Future<void> removeUntrackedFile(String repoPath, String path) =>
      _removeCaptured(
        repoPath,
        ['git', 'clean', '-f', '--', _literal(path)],
        [path],
      );

  /// Removes every untracked path in [paths] with a single invocation — the
  /// multi-select bulk equivalent of [removeUntrackedFile]. Same scoping
  /// rationale: `git clean` still refuses to touch anything tracked, so this
  /// can only ever delete the untracked files the caller named.
  Future<void> removeUntrackedFilesMany(String repoPath, List<String> paths) =>
      _removeCaptured(repoPath, [
        'git',
        'clean',
        '-f',
        '--',
        ...paths.map(_literal),
      ], paths);

  /// Untracked (and ignored) content is invisible to `stash create`, so
  /// deletions snapshot the doomed [paths] with flavor B — a temp-index
  /// plumbing commit holding exactly those files' on-disk bytes — before the
  /// mutation removes them. Undo restores them; they come back untracked,
  /// as they were.
  Future<void> _removeCaptured(
    String repoPath,
    List<String> mutation,
    List<String> paths,
  ) async {
    final refName = _newSnapshotRef();
    await _runCaptured(
      repoPath,
      mutation,
      mutation.first == 'rm' ? 'rm' : 'git clean',
      extraCaptures: [_snapshotCaptureB(refName, paths)],
      record: (c) => c.extras[0].isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.removeFilePaths,
              description: paths.length == 1
                  ? 'Deletion of ${paths.single}'
                  : 'Deletion of ${paths.length} files',
              snapshotOid: c.extras[0],
              paths: paths,
            ),
    );
  }

  /// Permanently deletes [path] from the working tree with `rm -f`, regardless
  /// of whether git tracks it. Unlike [removeUntrackedFile] (`git clean`, which
  /// refuses to touch anything tracked), this is the file-tree pane's generic
  /// delete: that pane lists every file — tracked, untracked, and ignored — so
  /// its delete has to work on all of them. For a tracked file this removes the
  /// working-tree copy (git then reports it as deleted; the committed history
  /// still holds it, recoverable via `git restore`); for an untracked or
  /// ignored file it is gone for good. `-f` so a read-only or already-missing
  /// file doesn't error out. `--` guards a leading-`-` path, matching how every
  /// other path argument in this file is hardened.
  Future<void> deleteFile(String repoPath, String path) =>
      _removeCaptured(repoPath, ['rm', '-f', '--', path], [path]);

  /// Discards a staged path's changes entirely — both the index and working
  /// tree are reset to HEAD's content for [path]. For a path with no HEAD
  /// counterpart (a newly `git add`ed file that was never committed),
  /// `--source=HEAD` has nothing to restore *to*, so git instead removes it
  /// from both the index and the working tree — exactly "undo the staged
  /// add" for that case, with no special-casing needed here. Undoable via a
  /// flavor-A snapshot — see [_discardStagedCaptured].
  Future<void> discardStaged(String repoPath, String path) =>
      _discardStagedCaptured(repoPath, [path]);

  /// Discards staged changes to every path in [paths] with a single
  /// invocation — the multi-select bulk equivalent of [discardStaged]. Same
  /// "no HEAD counterpart" handling applies per-path.
  Future<void> discardStagedMany(String repoPath, List<String> paths) =>
      _discardStagedCaptured(repoPath, paths);

  /// Same flavor-A snapshot as [_discardCaptured]; the staged variant's undo
  /// additionally restores the index from the snapshot's index tree
  /// (`<snap>^2`), so a never-committed staged file round-trips too.
  Future<void> _discardStagedCaptured(
    String repoPath,
    List<String> paths,
  ) async {
    final refName = _newSnapshotRef();
    await _runCaptured(
      repoPath,
      [
        'git',
        'restore',
        '--staged',
        '--worktree',
        '--source=HEAD',
        '--',
        ...paths.map(_literal),
      ],
      'git restore',
      extraCaptures: [_snapshotCaptureA(refName)],
      record: (c) => c.extras[0].isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.discardStagedPaths,
              description: paths.length == 1
                  ? 'Staged discard of ${paths.single}'
                  : 'Staged discard of ${paths.length} files',
              snapshotOid: c.extras[0],
              paths: paths,
            ),
    );
  }

  /// Appends [path] as a new ignore pattern to the repo root's `.gitignore`,
  /// creating the file if it doesn't exist. Not a git subcommand — this app
  /// has no separate remote-vs-local file-editing path, so it's a small shell
  /// script run through the same executor as every other command here, which
  /// keeps it working identically for a local repo and an SSH one (whose
  /// `.gitignore` lives on the remote host, not this machine). A no-op if
  /// [path] (exact line match) is already present, so ignoring the same file
  /// twice doesn't duplicate the line.
  Future<void> addToGitignore(String repoPath, String path) =>
      _runVoid(repoPath, [
        'sh',
        '-c',
        _gitignoreAppendScript([path]),
      ], 'git ignore');

  /// Appends every path in [paths] to `.gitignore` with a single invocation —
  /// the multi-select bulk equivalent of [addToGitignore]. Each path is still
  /// deduped independently, same as the single-file version.
  Future<void> addToGitignoreMany(String repoPath, List<String> paths) =>
      _runVoid(repoPath, [
        'sh',
        '-c',
        _gitignoreAppendScript(paths),
      ], 'git ignore');

  static String _gitignoreAppendScript(List<String> paths) {
    final lines = paths
        .map(ShellEscaper.escape)
        .map((q) => 'grep -qxF -- $q "\$f" || printf \'%s\\n\' $q >> "\$f"')
        .join('; ');
    // A hand-edited .gitignore often lacks a trailing newline; appending onto
    // that would concatenate the new pattern into the last existing line,
    // corrupting both. `tail -c 1` is POSIX (BSD + GNU); the command
    // substitution strips a trailing newline, so a non-empty result means the
    // last byte isn't one — normalize before appending.
    return 'f=.gitignore; touch "\$f"; '
        '[ -s "\$f" ] && [ -n "\$(tail -c 1 "\$f")" ] && printf \'\\n\' >> "\$f"; '
        '$lines';
  }

  // ---- History actions -----------------------------------------------------

  /// Applies [hash] onto the current branch. For a merge commit, [mainline]
  /// selects which parent's changes to keep (1-based).
  Future<SSHCommandResult> cherryPick(
    String repoPath,
    String hash, {
    int? mainline,
  }) {
    final refName = _newSnapshotRef();
    return _runCaptured(
      repoPath,
      [
        'git',
        ..._idArgs,
        'cherry-pick',
        if (mainline != null) ...['-m', '$mainline'],
        '--end-of-options',
        hash,
      ],
      'git cherry-pick',
      // Clean completions only — a conflict throws and records nothing (the
      // pending-op abort owns it). Undo is `reset --hard` back, so unrelated
      // uncommitted changes are snapshotted like a hard reset's.
      extraCaptures: [_snapshotCaptureA(refName)],
      record: (c) => c.preHead.isEmpty || c.preHead == c.postHead
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.resetHard,
              description: 'Cherry-pick',
              snapshotOid: c.extras[0],
            ),
    );
  }

  /// Aborts an in-progress cherry-pick, restoring the pre-pick state.
  Future<void> cherryPickAbort(String repoPath) => _runVoid(repoPath, [
    'git',
    'cherry-pick',
    '--abort',
  ], 'git cherry-pick --abort');

  /// Creates a commit that undoes [hash]. For a merge commit, [mainline]
  /// selects the parent to revert against (1-based).
  Future<SSHCommandResult> revert(
    String repoPath,
    String hash, {
    int? mainline,
  }) {
    final refName = _newSnapshotRef();
    return _runCaptured(
      repoPath,
      [
        'git',
        ..._idArgs,
        'revert',
        '--no-edit',
        if (mainline != null) ...['-m', '$mainline'],
        '--end-of-options',
        hash,
      ],
      'git revert',
      // Same shape as cherry-pick: clean completions only, hard-reset back.
      extraCaptures: [_snapshotCaptureA(refName)],
      record: (c) => c.preHead.isEmpty || c.preHead == c.postHead
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.resetHard,
              description: 'Revert',
              snapshotOid: c.extras[0],
            ),
    );
  }

  /// Aborts an in-progress revert.
  Future<void> revertAbort(String repoPath) =>
      _runVoid(repoPath, ['git', 'revert', '--abort'], 'git revert --abort');

  /// Moves HEAD (and, per [mode], the index/worktree) to [hash].
  Future<void> reset(
    String repoPath,
    String hash, {
    required ResetMode mode,
  }) async {
    final args = [
      'git',
      'reset',
      switch (mode) {
        ResetMode.soft => '--soft',
        ResetMode.mixed => '--mixed',
        ResetMode.hard => '--hard',
      },
      '--end-of-options',
      hash,
    ];
    switch (mode) {
      case ResetMode.soft:
        await _runCaptured(
          repoPath,
          args,
          'git reset',
          record: (c) => c.preHead.isEmpty
              ? null
              : c.toRecord(
                  repoPath: repoPath,
                  kind: UndoOpKind.resetSoft,
                  description: 'Soft reset',
                ),
        );
      case ResetMode.mixed:
        await _runCaptured(
          repoPath,
          args,
          'git reset',
          // The pre-reset index as a tree, so undo can restore exactly what
          // was staged. `write-tree` fails on an unmerged (conflicted) index
          // — the empty capture degrades the undo to soft-only.
          extraCaptures: ['git write-tree 2>/dev/null'],
          record: (c) => c.preHead.isEmpty
              ? null
              : c.toRecord(
                  repoPath: repoPath,
                  kind: UndoOpKind.resetMixed,
                  description: 'Mixed reset',
                  preIndexTree: c.extras[0],
                ),
        );
      case ResetMode.hard:
        // Destroys uncommitted content, so a flavor-A snapshot is taken
        // first. An empty snapshot usually means the tree was clean — the
        // plain `reset --hard` back is then already exact — so the record is
        // kept either way (unlike the discard kinds, where an empty snapshot
        // means there is nothing to restore from).
        final refName = _newSnapshotRef();
        await _runCaptured(
          repoPath,
          args,
          'git reset',
          extraCaptures: [_snapshotCaptureA(refName)],
          record: (c) => c.preHead.isEmpty
              ? null
              : c.toRecord(
                  repoPath: repoPath,
                  kind: UndoOpKind.resetHard,
                  description: 'Hard reset',
                  snapshotOid: c.extras[0],
                ),
        );
    }
  }

  /// Creates a branch named [name] rooted at [startPoint], optionally checking
  /// it out. Same `-b`-consumes-the-name reasoning as [createBranch]; the
  /// checkout form's `--end-of-options` guards the positional [startPoint].
  Future<void> branchFrom(
    String repoPath,
    String name,
    String startPoint, {
    bool checkout = true,
  }) => _createBranchCaptured(
    repoPath,
    checkout
        ? ['git', 'checkout', '-b', name, '--end-of-options', startPoint]
        : ['git', 'branch', '--end-of-options', name, startPoint],
    name: name,
    checkedOut: checkout,
    startPoint: startPoint,
  );

  /// Amends the current HEAD commit. With a [message] it rewrites the subject
  /// (`-m`); without one it keeps the existing message (`--no-edit`). Picks up
  /// whatever is currently staged.
  Future<void> amendCommit(String repoPath, {String? message}) async {
    final hasMsg = message != null && message.trim().isNotEmpty;
    await _runCaptured(
      repoPath,
      [
        'git',
        ..._idArgs,
        'commit',
        '--amend',
        '--no-gpg-sign',
        if (hasMsg) ...['-m', message] else '--no-edit',
      ],
      'git commit --amend',
      timeout: commitTimeout,
      // preHead is the pre-amend commit; undo's `reset --soft` restores it
      // with the amendment's content left staged — the exact pre-amend state.
      record: (c) => c.preHead.isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.amend,
              description: 'Amend',
            ),
    );
  }

  // ---- Conflict resolution -------------------------------------------------

  /// The conflicted working-tree file, with merge markers. Read directly (not
  /// through git) since the marked-up file is not a git object.
  Future<String> conflictFile(String repoPath, String path) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['cat', '--', path],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading conflicted file failed', result);
    }
    return result.stdout;
  }

  /// Resolves a conflict by taking one side wholesale, then staging it.
  /// [useOurs] selects `--ours` (the current branch) vs `--theirs` (incoming).
  Future<void> resolveConflict(
    String repoPath,
    String path, {
    required bool useOurs,
  }) async {
    await _runVoid(repoPath, [
      'git',
      'checkout',
      useOurs ? '--ours' : '--theirs',
      '--',
      _literal(path),
    ], 'git checkout --ours/--theirs');
    await _runVoid(repoPath, ['git', 'add', '--', _literal(path)], 'git add');
  }

  /// Resolves every conflicted path in [paths] the same way as
  /// [resolveConflict], but with 2 invocations total (one `checkout`, one
  /// `add` covering every path) instead of 2 per file — the multi-select
  /// bulk equivalent.
  Future<void> resolveConflictMany(
    String repoPath,
    List<String> paths, {
    required bool useOurs,
  }) async {
    await _runVoid(repoPath, [
      'git',
      'checkout',
      useOurs ? '--ours' : '--theirs',
      '--',
      ...paths.map(_literal),
    ], 'git checkout --ours/--theirs');
    await _runVoid(repoPath, [
      'git',
      'add',
      '--',
      ...paths.map(_literal),
    ], 'git add');
  }

  /// Aborts an in-progress merge (`git merge --abort`).
  Future<void> mergeAbort(String repoPath) =>
      _runVoid(repoPath, ['git', 'merge', '--abort'], 'git merge --abort');

  /// Merges [branch] into the current branch. [mode] picks the strategy
  /// ([MergeMode.noFf] always creates a merge commit; [MergeMode.ffOnly] refuses
  /// anything but a fast-forward; [MergeMode.squash] stages the combined change
  /// without committing). Throws on conflicts — the working tree is left with
  /// markers and [pendingOp] reports [PendingOp.merge] so the UI can offer abort.
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
  }) {
    final args = [
      'git',
      ..._idArgs,
      'merge',
      '--no-edit',
      if (mode == MergeMode.noFf) '--no-ff',
      if (mode == MergeMode.ffOnly) '--ff-only',
      if (mode == MergeMode.squash) '--squash',
      '--end-of-options',
      branch,
    ];
    // A squash merge doesn't move HEAD (postHead == preHead), so the undo
    // validation would be meaningless — not undoable; discard the staged
    // result by hand. Conflicted merges throw (rc != 0) and record nothing:
    // the pending-op banner's abort owns that path.
    if (mode == MergeMode.squash) {
      return _run(repoPath, args, 'git merge');
    }
    final refName = _newSnapshotRef();
    return _runCaptured(
      repoPath,
      args,
      'git merge',
      // Undo is `reset --hard` back — which would also destroy any
      // uncommitted-but-unrelated changes the merge allowed through, so
      // they're snapshotted like a hard reset's.
      extraCaptures: [_snapshotCaptureA(refName)],
      record: (c) => c.preHead.isEmpty || c.preHead == c.postHead
          ? null // nothing moved (e.g. --ff-only already up to date)
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.resetHard,
              description: 'Merge of $branch',
              snapshotOid: c.extras[0],
            ),
    );
  }

  // ---- Rebase --------------------------------------------------------------

  /// Runs an interactive rebase of the commits after [onto] (an ancestor commit
  /// or ref) on the current branch, applying [steps] as the todo list. Driven
  /// headlessly: the plan is piped in on stdin and `GIT_SEQUENCE_EDITOR` swaps
  /// it in for git's generated todo, while `GIT_EDITOR=true` accepts squashed
  /// commit messages non-interactively. Dropped commits are simply omitted from
  /// [steps]. Throws on conflicts (working tree left with markers; [pendingOp]
  /// reports [PendingOp.rebase]).
  Future<SSHCommandResult> rebaseInteractive(
    String repoPath,
    String onto,
    List<RebaseStep> steps,
  ) async {
    final todo = steps
        .where((s) => s.action != RebaseAction.drop)
        .map((s) => '${_rebaseWord(s.action)} ${s.hash}')
        .join('\n');
    // Write our plan (piped in on stdin) to a temp file, then point the sequence
    // editor at a `cp` of that file over git's generated todo. The outer shell
    // expands $tmp into the env value so git's editor subshell sees the literal
    // path. No `set -e` — we capture git's exit code even on a conflict, clean
    // up, then propagate it. One shell invocation.
    //
    // Runs as a subshell inside [_runCaptured]'s wrapper so the pre-rebase
    // HEAD is captured atomically (making a *completed* rebase undoable via
    // `reset --hard` back) — the subshell keeps its internal `exit` from
    // killing the wrapper before the post-state prints. A conflicted rebase
    // exits non-zero and records nothing; abort/continue own that path. No
    // snapshot: `rebase -i` refuses to start on a dirty tree anyway.
    final idFlags = _idFlagsForShell;
    final ontoQ = ShellEscaper.escape(onto);
    // `--end-of-options` stops an [onto] value that starts with `-` from
    // being parsed as a flag to `rebase -i`, same reasoning as [checkout].
    final script =
        '(tmp=\$(mktemp) || exit 1; cat > "\$tmp"; '
        'GIT_SEQUENCE_EDITOR="cp \\"\$tmp\\"" GIT_EDITOR=true '
        'git${idFlags.isEmpty ? '' : ' $idFlags'} rebase -i --end-of-options $ontoQ; '
        'rc=\$?; rm -f "\$tmp"; exit \$rc)';
    return _runCaptured(
      repoPath,
      const [],
      'git rebase -i',
      mutationScript: script,
      stdin: todo,
      timeout: commitTimeout,
      record: (c) => c.preHead.isEmpty || c.preHead == c.postHead
          ? null // no-op rebase (nothing changed)
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.resetHard,
              description: 'Interactive rebase',
            ),
    );
  }

  /// Rebases the current branch onto [upstream] (a branch, tag or commit) — a
  /// plain, non-interactive `git rebase`, the operation a drag-a-branch-onto-a-
  /// commit gesture performs. Replays the current branch's commits since its
  /// merge-base with [upstream] on top of [upstream].
  ///
  /// Operates on the *current* branch (like [rebaseInteractive]) rather than
  /// taking a `<branch>` argument, so undo stays sound: a completed rebase is
  /// reversed with `reset --hard` back to the pre-rebase HEAD, which is only
  /// meaningful when HEAD didn't jump to a different branch first. A conflicted
  /// rebase exits non-zero, records nothing, and leaves the tree with markers
  /// for [pendingOp]/abort to own. Refuses to start on a dirty tree (git's own
  /// guard). `core.editor=true` accepts any non-interactive editor prompt (e.g.
  /// a rebased merge commit's message) without hanging.
  Future<SSHCommandResult> rebaseOnto(String repoPath, String upstream) {
    final args = [
      'git',
      '-c',
      'core.editor=true',
      ..._idArgs,
      'rebase',
      // `--end-of-options` stops an [upstream] beginning with `-` from being
      // parsed as a flag — same reasoning as [checkout] / [rebaseInteractive].
      '--end-of-options',
      upstream,
    ];
    return _runCaptured(
      repoPath,
      args,
      'git rebase',
      record: (c) => c.preHead.isEmpty || c.preHead == c.postHead
          ? null // no-op rebase (already up to date)
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.resetHard,
              description: 'Rebase onto $upstream',
            ),
    );
  }

  /// Continues a paused rebase after conflicts are resolved and staged. Uses a
  /// no-op editor so any squashed-message prompt is accepted non-interactively.
  Future<SSHCommandResult> rebaseContinue(String repoPath) => _run(
    repoPath,
    ['git', '-c', 'core.editor=true', ..._idArgs, 'rebase', '--continue'],
    'git rebase --continue',
    timeout: commitTimeout,
  );

  /// `--continue` for a paused merge — commits with the prepared MERGE_MSG
  /// (`core.editor=true` accepts it non-interactively, same as
  /// [rebaseContinue]). 0009 M14: merge/cherry-pick/revert used to have no
  /// continue at all.
  Future<SSHCommandResult> mergeContinue(String repoPath) => _run(
    repoPath,
    ['git', '-c', 'core.editor=true', ..._idArgs, 'merge', '--continue'],
    'git merge --continue',
    timeout: commitTimeout,
  );

  /// `--continue` for a paused cherry-pick (see [mergeContinue]).
  Future<SSHCommandResult> cherryPickContinue(String repoPath) => _run(
    repoPath,
    ['git', '-c', 'core.editor=true', ..._idArgs, 'cherry-pick', '--continue'],
    'git cherry-pick --continue',
    timeout: commitTimeout,
  );

  /// The message git prepared for a paused operation: merge, cherry-pick, and
  /// revert all stage theirs in `MERGE_MSG`; a conflicted rebase keeps the
  /// replayed commit's message in `rebase-merge/message`. Null when neither
  /// file exists (no pending op, or a step without a prepared message).
  /// Comment lines are stripped the way `git commit` itself would strip them.
  Future<String?> pendingCommitMessage(String repoPath) async {
    // --git-path resolves linked-worktree/submodule layouts; checking both
    // candidates in one round-trip keeps this a single exec like
    // [commitTemplate]'s script (dash-clean, no bashisms).
    const script =
        'for f in MERGE_MSG rebase-merge/message; do '
        'p=\$(git rev-parse --git-path "\$f") || exit \$?; '
        'if [ -r "\$p" ]; then cat -- "\$p"; exit 0; fi; '
        'done; exit 0';
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: ['sh', '-c', script],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('reading pending commit message failed', result);
    }
    final message = result.stdout
        .split('\n')
        .where((line) => !line.startsWith('#'))
        .join('\n')
        .trim();
    return message.isEmpty ? null : message;
  }

  /// `--continue` for a paused revert (see [mergeContinue]).
  Future<SSHCommandResult> revertContinue(String repoPath) => _run(
    repoPath,
    ['git', '-c', 'core.editor=true', ..._idArgs, 'revert', '--continue'],
    'git revert --continue',
    timeout: commitTimeout,
  );

  /// Aborts an in-progress rebase, restoring the pre-rebase branch state.
  Future<void> rebaseAbort(String repoPath) =>
      _runVoid(repoPath, ['git', 'rebase', '--abort'], 'git rebase --abort');

  static String _rebaseWord(RebaseAction a) => switch (a) {
    RebaseAction.pick => 'pick',
    RebaseAction.squash => 'squash',
    RebaseAction.fixup => 'fixup',
    RebaseAction.drop => 'drop', // never emitted (filtered out)
  };

  /// Identity `-c` overrides rendered for embedding in a shell command string
  /// (each token shell-quoted). Empty when no identity is configured.
  String get _idFlagsForShell => _idArgs.map(ShellEscaper.escape).join(' ');

  // ---- Remote sync ---------------------------------------------------------

  /// `-c credential.helper=…` so HTTPS forge remotes authenticate via the
  /// matching CLI store (`gh` / `glab`) for a single network command — see
  /// [forgeGitAuthConfigArgs]. Looks up [remote]'s URL (default `origin`);
  /// returns empty when the remote is missing or not a known forge so custom
  /// remotes keep the host's ordinary helpers. Never throws.
  Future<List<String>> _forgeAuthArgs(
    String repoPath, {
    String remote = 'origin',
  }) async {
    try {
      final result = await _executor.execute(
        repoPath: repoPath,
        extraEnv: _scopeEnvFor(repoPath),
        gitArgs: ['git', 'remote', 'get-url', remote],
        timeout: const Duration(seconds: 15),
        lane: ExecLane.read,
        retries: 0,
      );
      if (!result.isSuccess) return const [];
      return forgeGitAuthConfigArgs(
        forgeFromRemoteUrl(result.stdout.trim()),
        ghPath: _executor.resolvedBinaryPath('gh'),
        glabPath: _executor.resolvedBinaryPath('glab'),
      );
    } catch (_) {
      return const [];
    }
  }

  /// The remote a remote-less `git pull`/`git push` will actually target: the
  /// current branch's configured upstream remote, falling back to `origin`
  /// when there is none (detached/unborn HEAD, no upstream configured).
  ///
  /// Exists for [_forgeAuthArgs]: those commands follow the *tracked*
  /// upstream, so hardcoding `origin` meant a branch tracking a remote named
  /// anything else got no forge credential helper (`get-url origin` fails →
  /// empty args) and HTTPS auth failed exactly where the origin-named case
  /// succeeded.
  Future<String> _upstreamRemote(String repoPath) async {
    try {
      final result = await _executor.execute(
        repoPath: repoPath,
        extraEnv: _scopeEnvFor(repoPath),
        gitArgs: [
          'sh',
          '-c',
          // The $(…) output is data — the shell never re-expands command
          // substitution results, so a branch name containing quotes or `$`
          // cannot inject here.
          'git config --get '
              r'"branch.$(git symbolic-ref --short -q HEAD).remote"',
        ],
        timeout: const Duration(seconds: 15),
        lane: ExecLane.read,
        retries: 0,
      );
      final r = result.stdout.trim();
      // `.` names the local repository itself (a branch tracking a local
      // branch) — no network remote, nothing to authenticate.
      if (result.isSuccess && r.isNotEmpty && r != '.') return r;
    } catch (_) {
      // Fall through — auth degradation, never a blocked pull/push.
    }
    return 'origin';
  }

  /// Fetches all remotes and prunes deleted refs. Returns the command result so
  /// callers can surface its output. Sync lane: a fetch touches refs and the
  /// network but never the index/worktree, so reads keep flowing while a slow
  /// fetch (up to [networkTimeout]) runs — but only one sync op at a time, so
  /// an auto-fetch can never race a manual fetch on ref locks.
  ///
  /// Installs both forge CLI credential helpers for the duration of the
  /// command ([forgeGitAuthConfigArgsAll]) because `--all` may touch remotes
  /// of either forge.
  Future<SSHCommandResult> fetch(String repoPath, {bool background = false}) =>
      _run(
        repoPath,
        [
          'git',
          ...forgeGitAuthConfigArgsAll(
            ghPath: _executor.resolvedBinaryPath('gh'),
            glabPath: _executor.resolvedBinaryPath('glab'),
          ),
          'fetch',
          '--all',
          '--prune',
        ],
        'git fetch',
        timeout: _networkCeiling,
        activityIdle: networkTimeout,
        lane: ExecLane.sync,
        visibility: background
            ? OperationVisibility.background
            : OperationVisibility.normal,
      );

  /// Pulls upstream work. Defaults to fast-forward-only (never creates a
  /// surprise merge commit); [mode] can request a rebase or an explicit merge,
  /// and [remote]/[branch] override the tracked upstream.
  Future<SSHCommandResult> pull(
    String repoPath, {
    PullMode mode = PullMode.ffOnly,
    String? remote,
    String? branch,
  }) async {
    // No explicit remote → git follows the tracked upstream, so the auth
    // lookup must too (see [_upstreamRemote]).
    final auth = await _forgeAuthArgs(
      repoPath,
      remote: remote ?? await _upstreamRemote(repoPath),
    );
    return _run(
      repoPath,
      [
        'git',
        ...auth,
        'pull',
        switch (mode) {
          PullMode.ffOnly => '--ff-only',
          PullMode.rebase => '--rebase',
          PullMode.merge => '--no-rebase',
        },
        if (remote != null) '--end-of-options',
        ?remote,
        if (remote != null && branch != null) branch,
      ],
      'git pull',
      timeout: _networkCeiling,
      activityIdle: networkTimeout,
      // Exclusive: pull can rewrite the index/worktree (merge/rebase), so it
      // must never overlap concurrent reads or mutations.
    );
  }

  /// Pushes the current branch. HTTPS GitHub/GitLab remotes authenticate via
  /// the matching forge CLI credential helper for this command (see
  /// [forgeGitAuthConfigArgs]); SSH and non-forge remotes use the host's
  /// ordinary credentials. [force] selects `--force-with-lease` or the blunt
  /// `--force`; [setUpstream] adds `-u`; [followTags] pushes annotated tags
  /// reachable from the pushed commits. [remote]/[branch] target a specific
  /// ref.
  Future<SSHCommandResult> push(
    String repoPath, {
    String? remote,
    String? branch,
    bool setUpstream = false,
    PushForce force = PushForce.none,
    bool followTags = false,
  }) async {
    // No explicit remote → git follows the tracked upstream (or push.default),
    // so the auth lookup must too (see [_upstreamRemote]).
    final auth = await _forgeAuthArgs(
      repoPath,
      remote: remote ?? await _upstreamRemote(repoPath),
    );
    return _run(
      repoPath,
      [
        'git',
        ...auth,
        'push',
        if (force == PushForce.withLease) '--force-with-lease',
        if (force == PushForce.force) '--force',
        if (setUpstream) '-u',
        if (followTags) '--follow-tags',
        if (remote != null) '--end-of-options',
        ?remote,
        if (remote != null && branch != null) branch,
      ],
      'git push',
      timeout: _networkCeiling,
      activityIdle: networkTimeout,
      // Sync lane: push updates the remote (and local tracking refs) but never
      // the index/worktree — safe alongside reads, exclusive among sync ops.
      lane: ExecLane.sync,
    );
  }

  // ---- Tags ----------------------------------------------------------------

  /// Creates a tag at [ref] (default HEAD). When [message] is non-empty the tag
  /// is annotated (`-a -m`), otherwise it's lightweight. An annotated tag is a
  /// real git object requiring an author identity, so it gets [_idArgs] like
  /// every other object-creating command; a lightweight tag is just a ref and
  /// doesn't need one, but including it unconditionally is harmless.
  ///
  /// Journaled: undo deletes the tag, validating it still points at the
  /// captured OID. The OID is a post-mutation capture because an annotated
  /// tag's object doesn't exist until the tag does.
  Future<void> createTag(
    String repoPath,
    String name, {
    String? message,
    String ref = 'HEAD',
  }) async {
    await _runCaptured(
      repoPath,
      [
        'git',
        ..._idArgs,
        'tag',
        if (message != null && message.isNotEmpty) ...['-a', '-m', message],
        '--end-of-options',
        name,
        ref,
      ],
      'git tag',
      postCaptures: [
        'git rev-parse -q --verify ${ShellEscaper.escape('refs/tags/$name')}',
      ],
      record: (c) => c.postExtras[0].isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.createTag,
              description: 'Creation of tag $name',
              refName: name,
              deletedOid: c.postExtras[0],
            ),
    );
  }

  /// Deletes a local tag. The captured OID is the tag *object* for an
  /// annotated tag (deliberately not peeled), so undo restores it
  /// byte-identical via `update-ref`.
  Future<void> deleteTag(String repoPath, String name) async {
    await _runCaptured(
      repoPath,
      ['git', 'tag', '-d', '--end-of-options', name],
      'git tag -d',
      extraCaptures: [
        'git rev-parse -q --verify ${ShellEscaper.escape('refs/tags/$name')}',
      ],
      record: (c) => c.extras[0].isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.deleteTag,
              description: 'Deletion of tag $name',
              refName: name,
              deletedOid: c.extras[0],
            ),
    );
  }

  /// Pushes a single tag to [remote].
  Future<SSHCommandResult> pushTag(
    String repoPath,
    String name, {
    String remote = 'origin',
  }) => pushTags(repoPath, [name], remote: remote);

  /// Pushes every tag in [names] to [remote] in a single invocation, so the
  /// "push N local-only tags" affordance costs one round trip. Deliberately
  /// explicit refspecs rather than `--tags`: a local tag that DIFFERS from
  /// the remote's would poison a `--tags` batch with its rejection, while an
  /// explicit list touches exactly the tags asked for.
  Future<SSHCommandResult> pushTags(
    String repoPath,
    List<String> names, {
    String remote = 'origin',
  }) async {
    if (names.isEmpty) {
      // Without refspecs the argv degenerates to a plain `git push <remote>`
      // — a default branch push nobody asked for. Safe by construction.
      throw ArgumentError.value(names, 'names', 'must not be empty');
    }
    final auth = await _forgeAuthArgs(repoPath, remote: remote);
    return _run(
      repoPath,
      [
        'git',
        ...auth,
        'push',
        '--end-of-options',
        remote,
        for (final n in names) 'refs/tags/$n',
      ],
      'git push tag',
      timeout: _networkCeiling,
      activityIdle: networkTimeout,
      lane: ExecLane.sync,
    );
  }

  /// Deletes the tag on [remote] (`git push --delete`) — the remote sibling
  /// of [deleteTag]. The full `refs/tags/` refname disambiguates from a
  /// branch of the same name. Deliberately NOT journaled, like
  /// [deleteRemoteBranch]: resurrecting a remote ref is a push the user must
  /// own — the caller's confirm dialog is the guard.
  Future<SSHCommandResult> deleteRemoteTag(
    String repoPath,
    String remote,
    String name,
  ) async {
    final auth = await _forgeAuthArgs(repoPath, remote: remote);
    return _run(
      repoPath,
      [
        'git',
        ...auth,
        'push',
        '--delete',
        '--end-of-options',
        remote,
        'refs/tags/$name',
      ],
      'git push --delete',
      timeout: _networkCeiling,
      activityIdle: networkTimeout,
      lane: ExecLane.sync,
    );
  }

  /// The tags currently on [remote], as `{shortName: oid}` — the remote-side
  /// truth for "is this local tag on the remote yet?".
  ///
  /// The oid kept is the UNPEELED value (`^{}` peel lines are skipped): for
  /// an annotated tag that's the tag *object*, exactly what [GitRef.oid]
  /// holds locally — and unpeeled inequality is precisely what predicts a
  /// push rejection, since git refuses whenever the ref itself would move,
  /// even when both sides peel to the same commit.
  ///
  /// Returns null when the remote can't be reached (offline, auth failure) —
  /// callers must render "unknown", never an error. Network op: sync lane
  /// like fetch/push, no retries (a dead host shouldn't be hammered by a
  /// passive indicator), [networkTimeout].
  Future<Map<String, String>?> lsRemoteTags(
    String repoPath, {
    String remote = 'origin',
  }) async {
    final SSHCommandResult result;
    try {
      final auth = await _forgeAuthArgs(repoPath, remote: remote);
      result = await _run(
        repoPath,
        ['git', ...auth, 'ls-remote', '--tags', '--end-of-options', remote],
        'git ls-remote',
        timeout: _networkCeiling,
        activityIdle: networkTimeout,
        lane: ExecLane.sync,
      );
    } catch (_) {
      // GitException (non-zero exit) or a transport failure alike: the
      // answer is "unknown", by contract — the caller shows no badges.
      return null;
    }
    final tags = <String, String>{};
    for (final line in result.stdout.split('\n')) {
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final oid = line.substring(0, tab).trim();
      final refName = line.substring(tab + 1).trim();
      if (!refName.startsWith('refs/tags/') || refName.endsWith('^{}')) {
        continue;
      }
      if (oid.isEmpty) continue;
      tags[refName.substring('refs/tags/'.length)] = oid;
    }
    return tags;
  }

  /// The SHA [rev] resolves to, or null if it doesn't exist (e.g. no upstream
  /// is configured, or HEAD is detached). Never throws for a missing rev, so
  /// callers can probe `@{upstream}` safely.
  Future<String?> revParse(String repoPath, String rev) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'rev-parse',
        '--verify',
        '--quiet',
        '--end-of-options',
        rev,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    final out = result.stdout.trim();
    return out.isEmpty ? null : out;
  }

  /// The name-status of every file changed across [range] (e.g. `old..new`),
  /// one `git diff --name-status` line per file — used to report what a
  /// push/pull/sync moved.
  Future<List<String>> changedFiles(String repoPath, String range) async {
    final result = await _run(
      repoPath,
      [
        'git',
        // Print non-ASCII paths literally (UTF-8) rather than C-quoting them, so
        // the display list isn't cluttered with `\NNN` octal escapes.
        '-c',
        'core.quotepath=false',
        'diff',
        '--name-status',
        '--end-of-options',
        range,
      ],
      'git diff --name-status',
      retries: _readRetries,
      lane: ExecLane.read,
    );
    return result.stdout.split('\n').where((l) => l.trim().isNotEmpty).toList();
  }

  // ---- Stash ---------------------------------------------------------------

  /// Stashes the working tree. [includeUntracked] adds `--include-untracked`
  /// so new (unadded) files are stashed too. `git stash push` creates real
  /// commit objects under the hood, so it needs [_idArgs] like every other
  /// object-creating command — without it, a host with no git identity
  /// configured fails to stash even though ordinary commits succeed.
  ///
  /// [paths], when non-empty, scopes the stash to those pathspecs (a *partial*
  /// stash — e.g. the drag-selected-files-onto-Stashes gesture). They go after
  /// `--` so a path that looks like a flag can't be misread as one, and each is
  /// wrapped in [_literal]: these are exact paths the UI showed, and a bare
  /// pathspec glob-matches (`pages/[id].tsx` would also stash `pages/i.tsx`'s
  /// changes) while a leading `:` is read as pathspec magic.
  Future<SSHCommandResult> stashPush(
    String repoPath, {
    String? message,
    bool includeUntracked = false,
    List<String> paths = const [],
  }) => _run(repoPath, [
    'git',
    ..._idArgs,
    'stash',
    'push',
    if (includeUntracked) '--include-untracked',
    if (message != null && message.isNotEmpty) ...['-m', message],
    if (paths.isNotEmpty) ...['--', ...paths.map(_literal)],
  ], 'git stash push');

  /// The stale-index guard both destructive stash ops run behind, and why:
  ///
  /// `pop` and `drop` can only address a stash positionally (`stash@{n}` — a
  /// raw OID is "not a stash reference" to either, verified against git
  /// 2.55), but positions shift under ANY concurrent push or drop: an
  /// auto-stash from a branch switch, another worktree's panel, a terminal.
  /// An unguarded `stash@{n}` would then destroy a DIFFERENT stash than the
  /// one the user clicked. So the mutation runs in the same shell invocation
  /// as a check that `stash@{n}` still resolves to the OID the UI rendered —
  /// atomically, since the exclusive lane serializes the whole script. Exit
  /// 42 (the same stale convention the undo scripts use) becomes
  /// [StashStaleException], and nothing has been touched.
  ///
  /// (`apply` and `show` don't need this: they accept the OID itself.)
  static String _stashGuardedScript(
    String selector,
    String expectedOid,
    String subcommand,
  ) {
    final sel = ShellEscaper.escape(selector);
    final oid = ShellEscaper.escape(expectedOid);
    // Subshell, so the guard's `exit 42` leaves _runCaptured's outer script
    // (which must still print its post-state fields) intact.
    return '( [ "\$(git rev-parse -q --verify $sel)" = $oid ] || exit 42; '
        'git stash $subcommand $sel )';
  }

  /// Rethrows the guard's exit 42 as [StashStaleException]; anything else is
  /// the mutation's own failure and stays a [GitException].
  static Never _rethrowStale(GitException e) {
    if (e.result.exitCode == 42) throw const StashStaleException();
    throw e;
  }

  /// Applies and drops `stash@{index}` — after verifying atomically that it
  /// is still the entry the user aimed at ([expectedOid], see
  /// [_stashGuardedScript]). Undo-captured like [stashDrop]: a clean pop
  /// deletes the entry, and while the applied changes stay in the worktree,
  /// the stash itself would otherwise be unrecoverable.
  Future<SSHCommandResult> stashPop(
    String repoPath,
    int index, {
    required String expectedOid,
    bool restoreIndex = false,
  }) async {
    final selector = ShellEscaper.escape('stash@{$index}');
    // A clean pop = apply + drop, and undoing it must reverse BOTH: re-store
    // the entry (like drop) AND un-apply the changes it just merged into the
    // tree. The old undo did only the first, leaving the popped changes
    // duplicated in the working tree. So capture a flavor-A snapshot of the
    // pre-pop worktree+index (extraCaptures run before the mutation) to reset
    // back to, plus the post-pop worktree tree (a postCapture) as the undo's
    // "nothing changed since" guard. See [UndoOpKind.stashPop].
    final refName = _newSnapshotRef();
    try {
      return await _runCaptured(
        repoPath,
        const [], // unused — mutationScript below
        'git stash pop',
        mutationScript: _stashGuardedScript(
          'stash@{$index}',
          expectedOid,
          // `--index` also reinstates the staged/unstaged split the stash
          // recorded (opt-in — it fails where a plain pop would succeed if the
          // index can't be cleanly restored).
          restoreIndex ? 'pop --index' : 'pop',
        ),
        extraCaptures: [
          'git log -1 --format=%s $selector 2>/dev/null', // extras[0]: subject
          _snapshotCaptureA(refName), // extras[1]: pre-pop snapshot S
        ],
        postCaptures: [_worktreeTreeCapture], // postExtras[0]: post-pop tree Pt
        record: (c) => c.toRecord(
          repoPath: repoPath,
          kind: UndoOpKind.stashPop,
          description: 'Stash pop',
          deletedOid: expectedOid,
          stashSubject: c.extras[0],
          snapshotOid: c.extras[1],
          worktreeTree: c.postExtras[0],
        ),
      );
    } on GitException catch (e) {
      _rethrowStale(e);
    }
  }

  /// Applies a stash without dropping it. Addressed by [oid], not index — an
  /// OID names the same stash no matter how the list has shifted since it
  /// was rendered, so apply needs no staleness guard at all.
  ///
  /// [restoreIndex] adds `--index` so the stash's staged/unstaged split is
  /// reinstated too (opt-in: it fails, restoring nothing, when the index can't
  /// be cleanly reapplied — e.g. the same paths are already staged).
  Future<SSHCommandResult> stashApply(
    String repoPath,
    String oid, {
    bool restoreIndex = false,
  }) => _run(repoPath, [
    'git',
    'stash',
    'apply',
    if (restoreIndex) '--index',
    '--end-of-options',
    oid,
  ], 'git stash apply');

  Future<SSHCommandResult> stashDrop(
    String repoPath,
    int index, {
    required String expectedOid,
  }) async {
    // Capture the doomed stash commit's subject before the drop, so undo can
    // `stash store` it back (the commit stays in the object DB until gc
    // prunes unreachables — weeks, by default). The OID is already known and
    // verified by the guard.
    final selector = ShellEscaper.escape('stash@{$index}');
    try {
      return await _runCaptured(
        repoPath,
        const [], // unused — mutationScript below
        'git stash drop',
        mutationScript: _stashGuardedScript(
          'stash@{$index}',
          expectedOid,
          'drop',
        ),
        extraCaptures: ['git log -1 --format=%s $selector 2>/dev/null'],
        record: (c) => c.toRecord(
          repoPath: repoPath,
          kind: UndoOpKind.stashDrop,
          description: 'Stash drop',
          deletedOid: expectedOid,
          stashSubject: c.extras[0],
        ),
      );
    } on GitException catch (e) {
      _rethrowStale(e);
    }
  }

  /// Recovers a stash onto a fresh branch: `git stash branch <name> stash@{n}`
  /// creates [branchName] at the commit the stash was based on, checks it out,
  /// applies the stash there (so it cannot conflict — the base matches), and
  /// drops the stash once applied. The escape hatch for a stash that won't
  /// apply cleanly to the current branch.
  ///
  /// Guarded and undoable like [stashPop]: the positional `stash@{n}` is
  /// verified against [expectedOid] first ([StashStaleException] otherwise),
  /// and the same pre-op snapshot + post-op worktree tree are captured so undo
  /// can check the old branch back out, re-apply the snapshot, delete the
  /// created branch, and re-store the entry. See [UndoOpKind.stashBranch].
  Future<SSHCommandResult> stashBranch(
    String repoPath,
    String branchName, {
    required int index,
    required String expectedOid,
  }) async {
    final refName = _newSnapshotRef();
    final sel = ShellEscaper.escape('stash@{$index}');
    final oid = ShellEscaper.escape(expectedOid);
    final name = ShellEscaper.escape(branchName);
    // Same stale guard as pop/drop, but `stash branch` puts the branch name
    // between the subcommand and the selector, so it can't reuse
    // [_stashGuardedScript]. [branchName] is check-ref-format-validated by the
    // UI before it gets here, and shell-escaped here.
    final mutationScript =
        '( [ "\$(git rev-parse -q --verify $sel)" = $oid ] || exit 42; '
        'git stash branch $name $sel )';
    try {
      return await _runCaptured(
        repoPath,
        const [], // unused — mutationScript below
        'git stash branch',
        mutationScript: mutationScript,
        extraCaptures: [
          'git log -1 --format=%s $sel 2>/dev/null', // extras[0]: subject
          _snapshotCaptureA(refName), // extras[1]: pre-op snapshot S
        ],
        postCaptures: [_worktreeTreeCapture], // postExtras[0]: post-op tree Pt
        record: (c) => c.toRecord(
          repoPath: repoPath,
          kind: UndoOpKind.stashBranch,
          description: 'Stash branch $branchName',
          refName: branchName,
          deletedOid: expectedOid,
          stashSubject: c.extras[0],
          snapshotOid: c.extras[1],
          worktreeTree: c.postExtras[0],
        ),
      );
    } on GitException catch (e) {
      _rethrowStale(e);
    }
  }

  /// Drops every stash (`git stash clear`). Undoable: every stash commit's
  /// OID and subject are captured first, so undo can `stash store` them all
  /// back in their original order.
  Future<SSHCommandResult> stashClear(String repoPath) => _runCaptured(
    repoPath,
    ['git', 'stash', 'clear'],
    'git stash clear',
    extraCaptures: [
      // One `<oid> <subject>` line per stash, newest first (reflog order).
      // Multi-line output is fine inside a single capture field — the
      // sentinel, not the newline, delimits fields.
      "git log -g --format='%H %gs' refs/stash 2>/dev/null",
    ],
    record: (c) {
      final entries = c.extras[0]
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      return entries.isEmpty
          ? null
          : c.toRecord(
              repoPath: repoPath,
              kind: UndoOpKind.stashClear,
              description: entries.length == 1
                  ? 'Clearing of 1 stash'
                  : 'Clearing of ${entries.length} stashes',
              stashEntries: entries,
            );
    },
  );

  /// The full patch a stash holds (`git stash show -p`), for previewing its
  /// contents. Read-only. Addressed by [oid] (see [stashApply]).
  ///
  /// `--include-untracked`: a stash made with `-u` keeps its untracked files
  /// in a third parent that the plain form silently omits — the preview would
  /// then show less than apply/pop will actually restore (verified against
  /// git 2.55; the flag exists since 2.32).
  Future<String> stashShow(String repoPath, String oid) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'stash',
        'show',
        '-p',
        '--include-untracked',
        '--no-color',
        '--end-of-options',
        oid,
      ],
      retries: _readRetries,
      lane: ExecLane.read,
      compress: true,
    );
    if (!result.isSuccess) {
      throw GitException('git stash show failed', result);
    }
    return result.stdout;
  }

  /// Lists stashes (`git stash list`), carrying each stash's OID (its stable
  /// identity — see [GitStash.oid]) and relative age.
  Future<List<GitStash>> stashList(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'stash',
        'list',
        // %gs (the reflog subject) is free text and goes LAST: a stray field
        // separator inside it then only over-splits the trailing field, which
        // we rejoin, instead of shoving the %cr date out of position. Same
        // reasoning that puts the commit subject last in parseRefs.
        '--format=%gd$fieldSep%H$fieldSep%cr$fieldSep%gs',
      ],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!result.isSuccess) {
      throw GitException('git stash list failed', result);
    }
    final stashes = <GitStash>[];
    for (final line in result.stdout.split('\n')) {
      if (line.trim().isEmpty) continue;
      final f = line.split(fieldSep);
      if (f.length < 4) continue;
      // %gd is like "stash@{0}"; extract the index.
      final match = RegExp(r'stash@\{(\d+)\}').firstMatch(f[0]);
      final index = match != null ? int.parse(match.group(1)!) : stashes.length;
      // Rejoin any separator-driven over-split of the trailing message, then
      // strip residual separator bytes from the display fields (as parseRefs
      // and parseGitLog do).
      final desc = _stripSeps(
        f.length > 4 ? f.sublist(3).join(fieldSep) : f[3],
      );
      // %gs is like "WIP on main: <subject>" or "On main: <message>".
      final branchMatch = RegExp(r'(?:WIP on|On) ([^:]+):').firstMatch(desc);
      stashes.add(
        GitStash(
          index: index,
          oid: f[1],
          branch: branchMatch?.group(1) ?? '',
          message: desc,
          relativeDate: _stripSeps(f[2]).trim(),
        ),
      );
    }
    return stashes;
  }

  // ---- Undo capture & execution --------------------------------------------

  /// Namespace of the hidden refs that anchor pre-destroy snapshots. A ref
  /// (rather than `git stash store`) keeps the snapshot commit gc-alive
  /// without polluting the stash list that [stashList]/the Stash panel — and
  /// every other git tool on the host — would show. Ref names embed the
  /// app-side creation epoch (`<epochSeconds>-<seq>`) so expiry never has to
  /// parse dates on the remote.
  static const String snapshotRefPrefix = 'refs/magic-git/snapshots/';

  /// Snapshots older than this are pruned opportunistically each time a new
  /// one is taken. Consumed snapshots are deliberately left in place until
  /// then — an undone undo is still recoverable from the Recovery sheet.
  static const Duration snapshotExpiry = Duration(days: 7);

  /// Disambiguates snapshots taken within the same second.
  int _snapshotSeq = 0;

  /// Fixed identity for snapshot objects: `stash create` and `commit-tree`
  /// both make real commit objects and refuse without one, and a host with no
  /// git identity must still get its safety net. Env (not `-c`) so it also
  /// covers the commits `stash create` makes internally; overriding a real
  /// configured identity is harmless — snapshots are app-internal.
  static const String _snapshotIdEnv =
      'GIT_AUTHOR_NAME=magic-git GIT_AUTHOR_EMAIL=snapshot@magic-git '
      'GIT_COMMITTER_NAME=magic-git GIT_COMMITTER_EMAIL=snapshot@magic-git';

  String _newSnapshotRef() =>
      '$snapshotRefPrefix'
      '${DateTime.now().millisecondsSinceEpoch ~/ 1000}-${++_snapshotSeq}';

  /// Deletes expired snapshot refs. Piggybacked onto every snapshot capture —
  /// all-local ref operations, so the cost inside an already-running script
  /// is negligible. Refs whose name doesn't parse as an epoch are left alone.
  String get _snapshotPruneScript {
    final cutoff =
        DateTime.now().subtract(snapshotExpiry).millisecondsSinceEpoch ~/ 1000;
    // The leading `(` on the case pattern is load-bearing: this whole loop
    // runs inside the capture's `x0=$(…)`, and an unbalanced `)` in a case
    // pattern would otherwise terminate that command substitution early
    // (POSIX allows the optional open paren for exactly this).
    return "git for-each-ref 'refs/magic-git/snapshots' --format='%(refname)' "
        '| while read -r r; do e=\${r##*/}; e=\${e%%-*}; '
        "case \"\$e\" in (''|*[!0-9]*) continue;; esac; "
        '[ "\$e" -lt $cutoff ] && git update-ref -d "\$r"; done';
  }

  /// Flavor A snapshot (tracked-content destroys: discard, discardStaged,
  /// reset --hard): `git stash create` captures the full worktree tree plus
  /// the index tree (`<snap>^2`) without touching the stash list, then the
  /// commit is anchored under [snapshotRefPrefix]. Emits the snapshot OID as
  /// the capture field — empty when there was nothing to capture (clean
  /// tree) or the create failed (unborn HEAD, conflicted index); either way
  /// the mutation still runs. Runs as a [_runCaptured] extra, i.e. *before*
  /// the mutation destroys anything.
  String _snapshotCaptureA(String refName) =>
      'snap=\$($_snapshotIdEnv git stash create 2>/dev/null); '
      'if [ -n "\$snap" ]; then '
      'git update-ref ${ShellEscaper.escape(refName)} "\$snap" '
      '&& printf %s "\$snap"; fi; '
      '$_snapshotPruneScript';

  /// Flavor B snapshot (untracked/ignored destroys: clean, rm): `stash
  /// create` cannot see untracked files, so this builds a commit holding
  /// exactly the doomed [paths] via a throwaway index — `add -f` (captures
  /// ignored files too) into a fresh `GIT_INDEX_FILE`, `write-tree`,
  /// `commit-tree`. Parented on HEAD when it exists (`$pre` is already set by
  /// the [_runCaptured] prologue this runs inside). The `$$`-suffixed temp
  /// index can't collide: mutations are serialized on the exclusive lane.
  String _snapshotCaptureB(String refName, List<String> paths) {
    final pathArgs = paths
        .map((p) => ShellEscaper.escape(_literal(p)))
        .join(' ');
    return 'idx="\$(git rev-parse --git-dir)/magicgit-snapidx.\$\$"; '
        'rm -f "\$idx"; '
        'GIT_INDEX_FILE="\$idx" git add -f -- $pathArgs 2>/dev/null && '
        't=\$(GIT_INDEX_FILE="\$idx" git write-tree 2>/dev/null) && '
        'c=\$($_snapshotIdEnv git commit-tree "\$t" \${pre:+-p "\$pre"} '
        '-m ${ShellEscaper.escape('magic-git snapshot')} 2>/dev/null) && '
        'git update-ref ${ShellEscaper.escape(refName)} "\$c" '
        '&& printf %s "\$c"; '
        'rm -f "\$idx"; '
        '$_snapshotPruneScript';
  }

  /// The full worktree tree OID *as it stands now* — `git stash create`'s
  /// `^{tree}` (index and unstaged content folded into one tree), or HEAD's
  /// tree when the worktree is clean and `stash create` captures nothing.
  /// Content-addressed and date-free, so two evaluations over identical content
  /// compare equal: the basis of the [UndoOpKind.stashPop] guard. Emitted as a
  /// [_runCaptured] postCapture (taken AFTER the pop applied) and recomputed at
  /// undo time to detect any edit made since.
  static const String _worktreeTreeCapture =
      'wt=\$($_snapshotIdEnv git stash create 2>/dev/null); '
      'if [ -n "\$wt" ]; then git rev-parse "\$wt^{tree}"; '
      'else git rev-parse -q --verify HEAD^{tree} 2>/dev/null; fi';

  /// Lists the anchored snapshots — the Recovery sheet's "Snapshots"
  /// section. Newest first (ref names embed the creation epoch).
  Future<List<SnapshotRef>> snapshotRefs(String repoPath) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      extraEnv: _scopeEnvFor(repoPath),
      gitArgs: [
        'git',
        'for-each-ref',
        '--sort=-refname',
        '--format=%(refname)$fieldSep%(objectname)$fieldSep%(subject)'
            '$fieldSep%(creatordate:relative)',
        'refs/magic-git/snapshots',
      ],
      retries: _readRetries,
      lane: ExecLane.read,
    );
    if (!result.isSuccess) {
      throw GitException('listing snapshots failed', result);
    }
    final snapshots = <SnapshotRef>[];
    for (final line in result.stdout.split('\n')) {
      if (line.trim().isEmpty) continue;
      final f = line.split(fieldSep);
      if (f.length < 4) continue;
      snapshots.add(
        SnapshotRef(
          refName: f[0],
          oid: f[1],
          subject: _stripSeps(f[2]),
          relativeDate: f[3].trim(),
        ),
      );
    }
    return snapshots;
  }

  /// Restores a snapshot's content into the working tree. Flavor A (a
  /// `stash create` commit) applies like a stash — it merges the captured
  /// changes back and can conflict like any stash apply. Flavor B (a
  /// temp-index commit holding exactly the deleted files) restores every
  /// path in its tree; `:/` scopes the pathspec to the repo root regardless
  /// of any prefix, and paths absent from the source tree are untouched.
  Future<void> restoreSnapshot(String repoPath, SnapshotRef snapshot) =>
      _runVoid(
        repoPath,
        snapshot.isUntrackedSnapshot
            ? [
                'git',
                'restore',
                '--source=${snapshot.oid}',
                '--worktree',
                '--',
                ':/',
              ]
            : ['git', 'stash', 'apply', snapshot.oid],
        snapshot.isUntrackedSnapshot ? 'git restore' : 'git stash apply',
      );

  /// Deletes a snapshot's anchor ref; the objects become unreachable and gc
  /// reaps them eventually.
  Future<void> deleteSnapshot(String repoPath, SnapshotRef snapshot) =>
      _runVoid(repoPath, [
        'git',
        'update-ref',
        '-d',
        snapshot.refName,
      ], 'git update-ref -d');

  /// Runs an undoable mutation with its pre/post repo state captured
  /// *atomically* in the same shell invocation: the script prints
  /// [_undoSep]-delimited fields (HEAD OID + checked-out branch shortname,
  /// plus any [extraCaptures], each a shell command whose output becomes one
  /// field) before the mutation, runs the mutation, prints the post fields,
  /// and exits with the mutation's own status. Capturing in-script — rather
  /// than with a separate `rev-parse` round trip — costs nothing over SSH and
  /// cannot race another mutation, because the exclusive lane serializes the
  /// whole script.
  ///
  /// On exit 0, [record] builds the journal entry from the capture (returning
  /// null skips recording — e.g. an unborn-HEAD first commit) and it is
  /// delivered via [onUndoRecord]. Either way callers observe exactly what
  /// the plain argv form produced: the returned/thrown result carries only
  /// the mutation's own stdout, with the capture fields stripped. Output that
  /// doesn't parse (a fake test executor, a script that died before the first
  /// printf) degrades to "no record" rather than an error.
  Future<SSHCommandResult> _runCaptured(
    String repoPath,
    List<String> mutation,
    String label, {
    required UndoRecord? Function(UndoCapture capture) record,
    List<String> extraCaptures = const [],
    // Like [extraCaptures], but taken AFTER the mutation — for values that
    // only exist once it ran (e.g. a created annotated tag's object OID,
    // which is a brand-new object no pre-op command can name).
    List<String> postCaptures = const [],
    Duration? timeout,
    String? stdin,
    // A raw shell snippet to run as the mutation instead of [mutation]'s
    // argv — for operations that are already scripts (rebaseInteractive).
    // Must be safe to follow with `; rc=$?` (i.e. a subshell or simple
    // command list that never `exit`s the outer shell).
    String? mutationScript,
  }) async {
    final mut = mutationScript ?? mutation.map(ShellEscaper.escape).join(' ');
    final assigns = StringBuffer();
    final printfArgs = StringBuffer();
    var fmt = '$_undoSep%s$_undoSep%s$_undoSep';
    for (var i = 0; i < extraCaptures.length; i++) {
      assigns.write('x$i=\$(${extraCaptures[i]}); ');
      fmt += '%s$_undoSep';
      printfArgs.write(' "\$x$i"');
    }
    final postAssigns = StringBuffer();
    final postPrintfArgs = StringBuffer();
    var postFmt = '$_undoSep%s$_undoSep%s$_undoSep';
    for (var i = 0; i < postCaptures.length; i++) {
      postAssigns.write('y$i=\$(${postCaptures[i]}); ');
      postFmt += '%s$_undoSep';
      postPrintfArgs.write(' "\$y$i"');
    }
    // No `set -e`: `-q --verify` legitimately fails on an unborn HEAD and
    // `symbolic-ref` on a detached one — both yield empty fields the record
    // builders understand. The mutation's own exit code is preserved via $rc.
    final script =
        'pre=\$(git rev-parse -q --verify HEAD); '
        'preref=\$(git symbolic-ref -q --short HEAD); '
        '$assigns'
        "printf '$fmt' \"\$pre\" \"\$preref\"$printfArgs; "
        '$mut; rc=\$?; '
        'post=\$(git rev-parse -q --verify HEAD); '
        'postref=\$(git symbolic-ref -q --short HEAD); '
        '$postAssigns'
        "printf '$postFmt' \"\$post\" \"\$postref\"$postPrintfArgs; "
        'exit \$rc';

    final operation = OperationDescriptor(
      id: OperationId.next(),
      repositoryPath: repoPath,
      label: label,
      kind: OperationKind.gitMutation,
      lane: ExecLane.exclusive,
    );
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: ['sh', '-c', script],
      extraEnv: _scopeEnvFor(repoPath),
      timeout: timeout ?? SSHCommandExecutor.defaultTimeout,
      stdin: stdin,
      operation: operation,
    );

    // Expected shape: '' pre preref extras… mutOut post postref postExtras…
    // '' — the leading/trailing separators bracket the whole stream, so the
    // count is deterministic and the mutation's own stdout is exactly one
    // segment.
    final n = extraCaptures.length;
    final m = postCaptures.length;
    final parts = result.stdout.split(_undoSep);
    UndoCapture? capture;
    var mutationStdout = result.stdout;
    if (parts.length == 7 + n + m) {
      mutationStdout = parts[3 + n];
      capture = UndoCapture(
        preHead: parts[1],
        preRef: parts[2],
        extras: parts.sublist(3, 3 + n),
        postHead: parts[4 + n],
        postRef: parts[5 + n],
        postExtras: parts.sublist(6 + n, 6 + n + m),
      );
    }
    final cleaned = SSHCommandResult(
      exitCode: result.exitCode,
      stdout: mutationStdout,
      stderr: result.stderr,
      operationId: result.operationId,
    );
    if (!cleaned.isSuccess) {
      // argv[0] is `sh` here, but a missing git still surfaces as the
      // mutation's own 127 — same message as [_run].
      if (cleaned.exitCode == 127) {
        throw GitException(_gitNotFoundMessage, cleaned);
      }
      throw GitException('$label failed', cleaned);
    }
    if (capture != null && onUndoRecord != null) {
      final entry = record(capture);
      if (entry != null) {
        onUndoRecord!(entry);
        final id = operation.id;
        if (id != null && onOperationEvent != null) {
          onOperationEvent!(
            OperationEvent(
              id: id,
              descriptor: operation,
              phase: OperationPhase.succeeded,
              occurredAt: DateTime.now(),
              undoable: true,
            ),
          );
        }
      }
    }
    return cleaned;
  }

  /// Executes [record]'s undo as one atomic validate-then-execute script on
  /// the exclusive lane. The script re-checks the repo is still in the
  /// recorded post-op state before moving anything: exit 42 surfaces as
  /// [UndoStaleException] (something else changed the repo — discard the
  /// record); exit 43 as [UndoDirtyException] (the working tree changed where
  /// this undo would write — confirm with the user, then retry with [force],
  /// which strips only that guard; state validation always runs).
  Future<void> undoExecute(UndoRecord record, {bool force = false}) async {
    final result = await _executor.execute(
      repoPath: record.repoPath,
      extraEnv: _scopeEnvFor(record.repoPath),
      gitArgs: [
        'sh',
        '-c',
        _undoScript(record, force: force),
      ],
    );
    if (result.exitCode == 42) throw UndoStaleException(record);
    if (result.exitCode == 43) throw UndoDirtyException(record);
    if (!result.isSuccess) {
      if (result.exitCode == 127) {
        throw GitException(_gitNotFoundMessage, result);
      }
      throw GitException('undoing ${record.description} failed', result);
    }
  }

  /// Replays the only mutation class that passes the Redo feasibility gate: a
  /// tag ref create/delete. `update-ref` validates [RedoRecord.expectedOid] and
  /// applies [RedoRecord.replayOid] in one ref transaction, so an external
  /// process that changes the tag wins cleanly and this attempt becomes stale.
  Future<void> redoExecute(RedoRecord record) async {
    const esc = ShellEscaper.escape;
    final command = record.replayOid.isEmpty
        ? 'git update-ref -d ${esc(record.refName)} '
              '${esc(record.expectedOid)}'
        : 'git update-ref ${esc(record.refName)} ${esc(record.replayOid)} '
              '${esc(record.expectedOid)}';
    final result = await _executor.execute(
      repoPath: record.repoPath,
      extraEnv: _scopeEnvFor(record.repoPath),
      gitArgs: ['sh', '-c', '$command || exit 42'],
    );
    if (result.exitCode == 42) throw RedoStaleException(record);
    if (!result.isSuccess) {
      if (result.exitCode == 127) {
        throw GitException(_gitNotFoundMessage, result);
      }
      throw GitException('redoing ${record.description} failed', result);
    }
  }

  /// The validate+execute script for one journal entry. Every captured value
  /// is shell-escaped on embedding even though it came from git's own output —
  /// defense in depth, and it makes empty-string comparisons well-formed.
  //
  // [force] strips only the worktree-overwrite guards (exit 43) used by the
  // snapshot-restoring kinds; none of the current kinds carry one yet, but
  // the parameter is plumbed now so the controller's confirm-and-retry flow
  // doesn't change shape when they land.
  String _undoScript(UndoRecord r, {required bool force}) {
    const esc = ShellEscaper.escape;
    // HEAD and the checked-out branch must both still match the recorded
    // post-op state — an empty postRef (detached) compares against
    // symbolic-ref's empty failure output, so the same check covers both.
    final headGuard =
        '[ "\$(git rev-parse -q --verify HEAD)" = ${esc(r.postHead)} ] || exit 42; '
        '[ "\$(git symbolic-ref -q --short HEAD)" = ${esc(r.postRef)} ] || exit 42; ';
    switch (r.kind) {
      case UndoOpKind.commit:
      case UndoOpKind.amend:
      case UndoOpKind.resetSoft:
        // `reset --soft` back: the index still holds the committed/amended
        // content, so this restores the exact pre-op staged state without
        // touching the working tree.
        return '${headGuard}git reset --soft ${esc(r.preHead)}';
      case UndoOpKind.resetMixed:
        // Restore the pre-reset index from its captured tree; a degraded
        // capture (conflicted index at reset time) falls back to soft-only.
        final readTree = r.preIndexTree.isEmpty
            ? ''
            : ' && git read-tree ${esc(r.preIndexTree)}';
        return '${headGuard}git reset --soft ${esc(r.preHead)}$readTree';
      case UndoOpKind.checkout:
        // git itself refuses if the working tree would lose changes — that
        // surfaces as a plain GitException, same as a manual checkout would.
        final back = r.preRef.isNotEmpty
            ? 'git checkout --end-of-options ${esc(r.preRef)}'
            : 'git checkout --detach ${esc(r.preHead)}';
        return '$headGuard$back';
      case UndoOpKind.deleteBranch:
        // Only the target ref is validated (not HEAD): recreating a still-
        // absent branch at its old tip is safe no matter where HEAD went.
        return 'git rev-parse -q --verify ${esc('refs/heads/${r.refName}')} >/dev/null && exit 42; '
            'git branch --end-of-options ${esc(r.refName)} ${esc(r.deletedOid)}';
      case UndoOpKind.deleteTag:
        // `update-ref` rather than `git tag`: the captured OID is the tag
        // *object* for an annotated tag, so it comes back byte-identical
        // (message, tagger, signature) instead of as a new lightweight tag.
        return 'git rev-parse -q --verify ${esc('refs/tags/${r.refName}')} >/dev/null && exit 42; '
            'git update-ref ${esc('refs/tags/${r.refName}')} ${esc(r.deletedOid)}';
      case UndoOpKind.createTag:
        // The created tag must still point where creation left it (the tag
        // *object* for an annotated tag — a re-tag with a different message
        // counts as moved). No HEAD guard: creation touched only the tag
        // ref. A copy pushed to a remote since is deliberately untouched.
        return '[ "\$(git rev-parse -q --verify ${esc('refs/tags/${r.refName}')})" '
            '= ${esc(r.deletedOid)} ] || exit 42; '
            'git tag -d --end-of-options ${esc(r.refName)}';
      case UndoOpKind.stashDrop:
        // Always additive (lands at stash@{0}), so no validation to fail.
        // `stash store` writes a stash reflog entry — an object-creating
        // command, so it carries the identity flags like stashPush.
        final subject = r.stashSubject.isEmpty
            ? 'Restored stash'
            : r.stashSubject;
        final id = _idFlagsForShell;
        return 'git${id.isEmpty ? '' : ' $id'} stash store -m ${esc(subject)} ${esc(r.deletedOid)}';
      case UndoOpKind.stashPop:
        // Reverse a clean pop: reset the tree to the captured HEAD (dropping
        // the applied changes), re-apply the pre-pop snapshot's uncommitted
        // content (empty snapshot ⇒ the pre-pop tree was clean, so the bare
        // reset is already exact), then re-store the entry. headGuard already
        // pins HEAD == postHead (a pop never moves HEAD).
        final id = _idFlagsForShell;
        final subject = r.stashSubject.isEmpty
            ? 'Restored stash'
            : r.stashSubject;
        final store =
            'git${id.isEmpty ? '' : ' $id'} stash store '
            '-m ${esc(subject)} ${esc(r.deletedOid)}';
        final reapply = r.snapshotOid.isEmpty
            ? ''
            : ' && git stash apply --index ${esc(r.snapshotOid)}';
        // A popped tree is dirty by design, so the clean-tree guard the other
        // snapshot undos use would always trip. Instead refuse (exit 43) if the
        // live worktree tree no longer equals the post-pop tree we recorded —
        // any edit since the pop is work the reset --hard would eat. Skipped
        // when forced, or when the capture degraded to '' (nothing to compare).
        final treeGuard = (force || r.worktreeTree.isEmpty)
            ? ''
            : 'wt=\$($_snapshotIdEnv git stash create 2>/dev/null); '
                  'cur=\$(if [ -n "\$wt" ]; then git rev-parse "\$wt^{tree}"; '
                  'else git rev-parse -q --verify HEAD^{tree} 2>/dev/null; fi); '
                  '[ "\$cur" = ${esc(r.worktreeTree)} ] || exit 43; ';
        return '$headGuard$treeGuard'
            'git reset --hard ${esc(r.postHead)}$reapply && $store';
      case UndoOpKind.stashBranch:
        // Reverse create-branch + checkout + apply + drop. headGuard already
        // pins that HEAD is still the created branch at its tip (a commit made
        // on it since ⇒ exit 42, stale). Force the original branch back out
        // (the applied changes get re-stashed), re-apply the pre-op snapshot so
        // an unrelated pre-op change survives, delete the created branch, and
        // re-store the entry. Same worktree-equality guard as stashPop.
        final id = _idFlagsForShell;
        final subject = r.stashSubject.isEmpty
            ? 'Restored stash'
            : r.stashSubject;
        final back = r.preRef.isNotEmpty
            ? 'git checkout -f --end-of-options ${esc(r.preRef)}'
            : 'git checkout -f --detach ${esc(r.preHead)}';
        final reapply = r.snapshotOid.isEmpty
            ? ''
            : ' && git stash apply --index ${esc(r.snapshotOid)}';
        final store =
            'git${id.isEmpty ? '' : ' $id'} stash store '
            '-m ${esc(subject)} ${esc(r.deletedOid)}';
        final treeGuard = (force || r.worktreeTree.isEmpty)
            ? ''
            : 'wt=\$($_snapshotIdEnv git stash create 2>/dev/null); '
                  'cur=\$(if [ -n "\$wt" ]; then git rev-parse "\$wt^{tree}"; '
                  'else git rev-parse -q --verify HEAD^{tree} 2>/dev/null; fi); '
                  '[ "\$cur" = ${esc(r.worktreeTree)} ] || exit 43; ';
        return '$headGuard$treeGuard$back$reapply '
            '&& git branch -D --end-of-options ${esc(r.refName)} && $store';
      case UndoOpKind.createBranch:
        // The created branch must still point where creation left it —
        // commits made on it since must not be silently discarded.
        final tipGuard =
            '[ "\$(git rev-parse -q --verify ${esc('refs/heads/${r.refName}')})" '
            '= ${esc(r.deletedOid)} ] || exit 42; ';
        final deleteBranch = 'git branch -D --end-of-options ${esc(r.refName)}';
        if (r.postRef != r.refName) {
          // Creation didn't check the branch out — just delete it.
          return '$tipGuard$deleteBranch';
        }
        // Creation switched to it: verify we're still on it, go back, then
        // delete. git itself refuses the checkout if the tree is dirty.
        final back = r.preRef.isNotEmpty
            ? 'git checkout --end-of-options ${esc(r.preRef)}'
            : 'git checkout --detach ${esc(r.preHead)}';
        return '$tipGuard'
            '[ "\$(git symbolic-ref -q --short HEAD)" = ${esc(r.postRef)} ] '
            '|| exit 42; '
            '$back && $deleteBranch';
      case UndoOpKind.stashClear:
        // Re-store every cleared stash, oldest first, so the newest ends up
        // back at stash@{0}. Always additive — no validation to fail.
        final id = _idFlagsForShell;
        final prefix = 'git${id.isEmpty ? '' : ' $id'}';
        final stores = <String>[];
        for (final entry in r.stashEntries.reversed) {
          final space = entry.indexOf(' ');
          final oid = space < 0 ? entry : entry.substring(0, space);
          final subject = space < 0
              ? 'Restored stash'
              : entry.substring(space + 1);
          stores.add('$prefix stash store -m ${esc(subject)} ${esc(oid)}');
        }
        return stores.join(' && ');
      case UndoOpKind.resetHard:
        // Anything in the tree now appeared *after* the reset (which left it
        // matching its target) — moving back would overwrite it: exit 43.
        final dirtyGuard = force
            ? ''
            : '[ -z "\$(git status --porcelain)" ] || exit 43; ';
        // `--index` restores staged-vs-unstaged exactly; a clean tree at
        // reset time captured nothing, and the bare reset back is exact.
        final apply = r.snapshotOid.isEmpty
            ? ''
            : ' && git stash apply --index ${esc(r.snapshotOid)}';
        return '$headGuard$dirtyGuard'
            'git reset --hard ${esc(r.preHead)}$apply';
      case UndoOpKind.discardPaths:
      case UndoOpKind.removeFilePaths:
      case UndoOpKind.discardStagedPaths:
        // Path-scoped restore from the snapshot — deliberately no HEAD
        // guard: where the branch has moved since doesn't change what "bring
        // those files back" means. Only the affected paths are guarded: any
        // change under them since the destroy (an edit, a recreated file)
        // would be overwritten — exit 43 unless the user confirmed.
        // `:(literal)`: same exact-path hardening as the mutations that
        // recorded these paths — see [_literal].
        final pathArgs = r.paths.map((p) => esc(_literal(p))).join(' ');
        final dirtyGuard = force
            ? ''
            : '[ -z "\$(git status --porcelain -- $pathArgs)" ] || exit 43; ';
        final restoreIndex = r.kind == UndoOpKind.discardStagedPaths
            ? 'git restore --source=${esc('${r.snapshotOid}^2')} --staged '
                  '-- $pathArgs && '
            : '';
        return '$dirtyGuard$restoreIndex'
            'git restore --source=${esc(r.snapshotOid)} --worktree '
            '-- $pathArgs';
    }
  }

  /// Runs a command through the executor's lane scheduler and returns its
  /// result, throwing [GitException] on a non-zero exit. [lane] defaults to
  /// exclusive — the safe choice for a mutation; read-only callers pass
  /// [ExecLane.read] (and fetch/push pass [ExecLane.sync]) so they overlap.
  Future<SSHCommandResult> _run(
    String repoPath,
    List<String> gitArgs,
    String label, {
    Duration? timeout,
    String? stdin,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    Duration? activityIdle,
    OperationVisibility visibility = OperationVisibility.normal,
  }) async {
    final result = await _executor.execute(
      repoPath: repoPath,
      gitArgs: gitArgs,
      extraEnv: _scopeEnvFor(repoPath),
      timeout: timeout ?? SSHCommandExecutor.defaultTimeout,
      stdin: stdin,
      retries: retries,
      lane: lane,
      compress: compress,
      activityIdle: activityIdle,
      operation: lane == ExecLane.read
          ? null
          : OperationDescriptor(
              repositoryPath: repoPath,
              label: label,
              kind: lane == ExecLane.sync
                  ? OperationKind.synchronization
                  : OperationKind.gitMutation,
              lane: lane,
              visibility: visibility,
            ),
    );
    if (!result.isSuccess) {
      // 127 means git itself wasn't found (argv[0] is always `git` here), not
      // that this particular command failed — say so clearly.
      if (result.exitCode == 127) {
        throw GitException(_gitNotFoundMessage, result);
      }
      throw GitException('$label failed', result);
    }
    return result;
  }

  Future<void> _runVoid(
    String repoPath,
    List<String> gitArgs,
    String label, {
    Duration? timeout,
  }) async {
    await _run(repoPath, gitArgs, label, timeout: timeout);
  }
}
