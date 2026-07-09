import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../exec/local_command_executor.dart';
import '../forge/forge.dart';
import '../git/git_service.dart';
import '../git/local_watch_service.dart';
import '../git/remote_watch_service.dart';
import '../git/repo_tree.dart';
import '../git/watch_event.dart';
import '../github/gh_service.dart';
import '../github/models.dart';
import '../gitlab/glab_service.dart';
import '../gitlab/models.dart';
import '../local/security_scoped_bookmark.dart';
import '../output/output_log.dart';
import '../settings/app_settings.dart';
import '../settings/install_service.dart';
import '../ssh/command_formatter.dart';
import '../ssh/environment_probe.dart';
import '../ssh/host_key_prompt.dart';
import '../ssh/ssh_client_manager.dart';
import '../ssh/ssh_command_executor.dart';
import '../storage/connection_store.dart';
import '../storage/known_hosts_store.dart';
import '../storage/local_repo_store.dart';
import '../storage/saved_connection.dart';
import '../storage/saved_local_repo.dart';
import '../utils/git_porcelain_parser.dart';
import 'keep_alive_lru.dart';

/// Persists the main window's last position/size across launches, using the
/// same `SharedPreferences` key-naming/read-write convention as
/// [AppSettingsNotifier] (`app_settings.dart`). Not modeled as a Riverpod
/// provider: [load] is read directly by `main()` before the widget tree (and
/// any provider container) exists, and [save] is called directly from
/// [AppShell.onWindowClose] (`features/app_shell.dart`) right before the
/// window actually closes — there's no reactive UI state here, just a
/// one-shot read on startup and a one-shot write on shutdown.
class WindowBoundsStore {
  static const _xKey = 'windowBoundsX';
  static const _yKey = 'windowBoundsY';
  static const _widthKey = 'windowBoundsWidth';
  static const _heightKey = 'windowBoundsHeight';

  /// The app's minimum window size — enforced live via `windowManager`
  /// ([kMinWindowSize] in main.dart) and reused here as the floor below which a
  /// persisted size is treated as degenerate (corrupted storage, or bounds
  /// captured from an since-unplugged external monitor) rather than trusted.
  ///
  /// Sits comfortably above every in-app floating window's own minimum (the
  /// file viewer's 420×260, the diff pop-out's 420×280), so those never end up
  /// wider/taller than the app window — which is what let their size clamps hit
  /// the degenerate `lower > upper` case and the viewer title bar overflow.
  static const double minWidth = 640;
  static const double minHeight = 480;

  /// The persisted bounds as (x, y, width, height), or null when nothing is
  /// stored yet (first launch) or the stored size fails the sanity floor
  /// above.
  static Future<(double, double, double, double)?> load() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return null; // storage unavailable — fall back to the hardcoded default
    }
    final x = prefs.getDouble(_xKey);
    final y = prefs.getDouble(_yKey);
    final width = prefs.getDouble(_widthKey);
    final height = prefs.getDouble(_heightKey);
    if (x == null || y == null || width == null || height == null) {
      return null;
    }
    if (width < minWidth || height < minHeight) return null;
    return (x, y, width, height);
  }

  /// Persists the window's current bounds. Best-effort: a failure to persist
  /// (e.g. storage unavailable) just means the next launch falls back to the
  /// hardcoded default, not a crash — this runs during window teardown, where
  /// there's nothing meaningful to surface a failure to anyway.
  static Future<void> save(
    double x,
    double y,
    double width,
    double height,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_xKey, x);
      await prefs.setDouble(_yKey, y);
      await prefs.setDouble(_widthKey, width);
      await prefs.setDouble(_heightKey, height);
    } catch (_) {
      // Nothing to recover from during shutdown; next launch just re-centers.
    }
  }
}

/// Single long-lived SSH connection manager. dartssh2 multiplexes all git/glab
/// channels over this one authenticated client, so it is held for the app's
/// lifetime and torn down on dispose.
final sshClientManagerProvider = Provider<SSHClientManager>((ref) {
  final manager = SSHClientManager();
  ref.onDispose(manager.disconnect);
  return manager;
});

/// Serialized command executor over the shared SSH connection.
final executorProvider = Provider<SSHCommandExecutor>((ref) {
  return SSHCommandExecutor(ref.watch(sshClientManagerProvider));
});

/// Serialized command executor for a repo on this machine's own filesystem —
/// no SSH, no shell string, just `Process.start` directly. Stateless enough
/// to be a single app-lifetime instance, same as [executorProvider].
final localExecutorProvider = Provider<LocalCommandExecutor>((ref) {
  return LocalCommandExecutor();
});

/// The [CommandExecutor] backing the *active* session, chosen by
/// [ConnectionState.backend]. [GitService]/[GlabService] depend on this
/// rather than [executorProvider] directly, so they work unchanged against
/// either transport.
final activeExecutorProvider = Provider<CommandExecutor>((ref) {
  final backend = ref.watch(connectionProvider.select((c) => c.backend));
  // Exhaustive switch (no default): adding a third ConnectionBackend becomes a
  // compile error here rather than silently routing every command to the SSH
  // executor.
  return switch (backend) {
    ConnectionBackend.local => ref.watch(localExecutorProvider),
    ConnectionBackend.ssh => ref.watch(executorProvider),
  };
});

final gitServiceProvider = Provider<GitService>((ref) {
  // Select only the four fields GitService actually consumes. GitService has no
  // `==` and watching the whole AppSettings object would rebuild it — and
  // invalidate every provider that reads it (status/log/refs + all cached
  // diffs/blame, each a fresh SSH round-trip) — on *any* settings mutation,
  // including ones that don't affect git reads (autoFetchMinutes, pushFollowTags,
  // binaryOverrides, …).
  final (commitTimeout, networkTimeout, committerName, committerEmail) = ref
      .watch(
        appSettingsProvider.select(
          (s) => (
            s.commitTimeout,
            s.networkTimeout,
            s.committerName,
            s.committerEmail,
          ),
        ),
      );
  return GitService(
    ref.watch(activeExecutorProvider),
    commitTimeout: commitTimeout,
    networkTimeout: networkTimeout,
    committerName: committerName,
    committerEmail: committerEmail,
  );
});

final glabServiceProvider = Provider<GlabService>((ref) {
  return GlabService(ref.watch(activeExecutorProvider));
});

/// GitHub counterpart to [glabServiceProvider]; same executor seam, so it works
/// over both SSH and local backends unchanged.
final ghServiceProvider = Provider<GhService>((ref) {
  return GhService(ref.watch(activeExecutorProvider));
});

final installServiceProvider = Provider<InstallService>((ref) {
  return InstallService(ref.watch(activeExecutorProvider));
});

final remoteWatchServiceProvider = Provider<RemoteWatchService>((ref) {
  return RemoteWatchService(ref.watch(executorProvider));
});

/// Native-filesystem-event equivalent of [remoteWatchServiceProvider] for a
/// local repo — no SSH-spawned `fswatch`/`inotifywait`, just `dart:io`'s
/// `Directory.watch()`.
final localWatchServiceProvider = Provider<LocalWatchService>((ref) {
  return LocalWatchService();
});

/// Persists connection profiles (metadata + Keychain secret).
final connectionStoreProvider = Provider<ConnectionStore>((ref) {
  return ConnectionStore();
});

/// Persists the SSH host key trusted for each host the app has connected to.
final knownHostsStoreProvider = Provider<KnownHostsStore>((ref) {
  return KnownHostsStore();
});

/// Persists bookmarked local repos (no Keychain — a local repo has no
/// credentials).
final localRepoStoreProvider = Provider<LocalRepoStore>((ref) {
  return LocalRepoStore();
});

/// The list of saved local repos, mirroring [savedConnectionsProvider] for
/// the local backend.
final savedLocalReposProvider = FutureProvider<List<SavedLocalRepo>>((
  ref,
) async {
  try {
    return await ref.watch(localRepoStoreProvider).list();
  } catch (e) {
    ref
        .read(outputLogProvider.notifier)
        .logError('load saved local repos', e.toString());
    rethrow;
  }
});

/// The list of saved connection profiles.
///
/// `ConnectionStore.list()` already degrades a corrupt JSON decode to `[]`
/// internally, but its outer `SharedPreferences.getInstance()` call is
/// unguarded — if *that* throws (e.g. a platform-binding failure), this
/// provider becomes a genuine `AsyncError`. Every consumer today reads it via
/// `.value ?? const []`, which renders that identically to "no saved
/// connections" with zero indication anything went wrong. Log it here before
/// rethrowing so the failure is at least discoverable in the output log, even
/// though the UI still falls back to an empty list.
final savedConnectionsProvider = FutureProvider<List<SavedConnection>>((ref) async {
  try {
    return await ref.watch(connectionStoreProvider).list();
  } catch (e) {
    ref
        .read(outputLogProvider.notifier)
        .logError('load saved connections', e.toString());
    rethrow;
  }
});

/// A landing-page "recent workspace" — either a saved SSH [RecentConnection]
/// or a saved [RecentLocalRepo]. Unifies the two separate stores
/// ([savedConnectionsProvider] and [savedLocalReposProvider]) so the landing
/// card's recents menu offers both transports in one recency-ordered list.
sealed class RecentWorkspace {
  const RecentWorkspace();
  String get displayName;
  DateTime? get lastConnectedAt;
}

class RecentConnection extends RecentWorkspace {
  final SavedConnection connection;
  const RecentConnection(this.connection);
  @override
  String get displayName => connection.displayName;
  @override
  DateTime? get lastConnectedAt => connection.lastConnectedAt;
}

class RecentLocalRepo extends RecentWorkspace {
  final SavedLocalRepo repo;
  const RecentLocalRepo(this.repo);
  @override
  String get displayName => repo.displayName;
  @override
  DateTime? get lastConnectedAt => repo.lastConnectedAt;
}

/// The most-recently-used workspaces (up to 3), newest first — the landing
/// page's "Recent Workspaces" list, merging saved SSH connections and saved
/// local repos. Sorted by `lastConnectedAt` (never-used entries sort last,
/// keeping their stored order; on a tie, connections precede local repos since
/// they're appended first below).
final recentWorkspacesProvider = Provider<List<RecentWorkspace>>((ref) {
  final conns = ref.watch(savedConnectionsProvider).value ?? const [];
  final locals = ref.watch(savedLocalReposProvider).value ?? const [];
  final all = <RecentWorkspace>[
    for (final c in conns) RecentConnection(c),
    for (final r in locals) RecentLocalRepo(r),
  ];
  // Pair each entry with its original index so the sort is stable: `List.sort`
  // isn't guaranteed stable, and the comparator returns "equal" for entries
  // with matching (or both-null) timestamps — without the index tiebreaker,
  // never-used entries could reorder arbitrarily.
  final indexed = [for (var i = 0; i < all.length; i++) (i, all[i])]
    ..sort((a, b) {
      final at = a.$2.lastConnectedAt;
      final bt = b.$2.lastConnectedAt;
      if (at != null && bt != null) {
        final byTime = bt.compareTo(at);
        if (byTime != 0) return byTime;
      } else if (at == null && bt != null) {
        return 1; // never-used sorts after used
      } else if (at != null && bt == null) {
        return -1;
      }
      return a.$1.compareTo(b.$1); // stable: preserve original stored order
    });
  return [for (final e in indexed.take(3)) e.$2];
});

enum ConnectionPhase { disconnected, connecting, connected, error, lost }

/// Which transport the active/most-recent connection uses. A [local] session
/// never populates [ConnectionState.host]/`reconnectAttempt`/`reconnecting`/
/// `hostKeyPrompt` — those fields exist purely to serve SSH's failure modes
/// (a network drop, a changed host key) that a local filesystem repo has no
/// equivalent of.
enum ConnectionBackend { ssh, local }

class ConnectionState {
  final ConnectionPhase phase;
  final ConnectionBackend backend;
  final String? error;
  final String? repoPath; // Active repo
  final List<String> repoPaths; // Known repos on the connected host
  final String? connectionId; // Active saved-connection id (null = ad-hoc)
  final String? connectionLabel; // Display label of the active connection
  final String? host; // Host of the active connection (ssh backend only)
  /// Non-fatal warning shown after connect (e.g. GitLab token login failed).
  final String? warning;

  /// While auto-reconnecting after a drop, the 1-based attempt number (0 when
  /// not auto-reconnecting). Drives the "Reconnecting… (attempt N)" UI.
  final int reconnectAttempt;

  /// True from the moment a live connection drops until it either reconnects or
  /// the user cancels. Stays true across the transient `connecting` sub-phase of
  /// each retry, so the reconnecting popup doesn't flicker between attempts.
  final bool reconnecting;

  /// Non-null while awaiting an explicit human decision on a host key that no
  /// longer matches the one this app previously trusted for this host — set
  /// mid-`connect()`/`reconnect()` (see [ConnectionController._verifyHostKey])
  /// and takes UI priority over [reconnecting] since it can occur mid-retry too.
  final HostKeyPrompt? hostKeyPrompt;

  const ConnectionState({
    this.phase = ConnectionPhase.disconnected,
    this.backend = ConnectionBackend.ssh,
    this.error,
    this.repoPath,
    this.repoPaths = const [],
    this.connectionId,
    this.connectionLabel,
    this.host,
    this.warning,
    this.reconnectAttempt = 0,
    this.reconnecting = false,
    this.hostKeyPrompt,
  });

  bool get isConnected => phase == ConnectionPhase.connected;
  bool get isConnecting => phase == ConnectionPhase.connecting;
  bool get isLost => phase == ConnectionPhase.lost;
  bool get isLocal => backend == ConnectionBackend.local;

  ConnectionState copyWith({
    ConnectionPhase? phase,
    ConnectionBackend? backend,
    String? error,
    String? repoPath,
    List<String>? repoPaths,
    String? connectionId,
    String? connectionLabel,
    String? host,
    String? warning,
    bool clearWarning = false,
    int? reconnectAttempt,
    bool? reconnecting,
    HostKeyPrompt? hostKeyPrompt,
    bool clearHostKeyPrompt = false,
  }) {
    return ConnectionState(
      phase: phase ?? this.phase,
      backend: backend ?? this.backend,
      error: error ?? this.error,
      repoPath: repoPath ?? this.repoPath,
      repoPaths: repoPaths ?? this.repoPaths,
      connectionId: connectionId ?? this.connectionId,
      connectionLabel: connectionLabel ?? this.connectionLabel,
      host: host ?? this.host,
      warning: clearWarning ? null : (warning ?? this.warning),
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      reconnecting: reconnecting ?? this.reconnecting,
      hostKeyPrompt: clearHostKeyPrompt
          ? null
          : (hostKeyPrompt ?? this.hostKeyPrompt),
    );
  }
}

/// Owns the connect/disconnect lifecycle and the active connection + repo.
class ConnectionController extends Notifier<ConnectionState> {
  /// Monotonic attempt counter. Each connect/disconnect bumps it; a slow
  /// connect that resolves after a newer connect or a disconnect finds the
  /// counter changed and drops its terminal state instead of clobbering the
  /// current one (a "New connection" or "Disconnect" issued mid-connect must
  /// win). Mirrors the generation token in [SSHClientManager] so the superseded
  /// SSH client is torn down there too.
  int _attempt = 0;

  // Last connect *attempt's* arguments, retained so a dropped connection can be
  // re-established in one click with the same profile/repo. NOT "last
  // successful" — these are overwritten unconditionally at the top of every
  // `connect()` call, before success is known, so mid-attempt they can briefly
  // hold a profile/repo that hasn't (and may never) actually connect. This is
  // safe today only because the "Reconnect" UI that reads them is gated
  // strictly to `phase == ConnectionPhase.lost`, a phase that's exited the
  // instant any new `connect()` starts — so nothing ever reconnects using a
  // still-in-flight or failed attempt's values. A future reader of these
  // fields elsewhere must not assume they only ever reflect a successful
  // connect.
  SSHConnectionProfile? _lastProfile;
  String? _lastRepoPath;
  String? _lastGitlabToken;
  String? _lastGithubToken;
  String? _lastConnectionId;
  String? _lastConnectionLabel;
  List<String>? _lastRepoPaths;
  List<String> _lastFsmonitorPaths = const [];

  /// Resolved by [acceptHostKeyChange]/[rejectHostKeyChange] — the only way
  /// [_verifyHostKey] ever returns while a mismatch prompt is showing. Null
  /// whenever no prompt is currently awaiting a decision.
  Completer<bool>? _hostKeyDecision;

  /// The attempt token of the [connect] call whose host-key mismatch prompt the
  /// user most recently rejected, so the generic `catch` below can tell "the
  /// user deliberately declined *this* attempt" apart from every other
  /// connection failure — worth a clean, quiet disconnect rather than a scary
  /// error message or (if this was a reconnect attempt) resuming the
  /// auto-reconnect loop. Keyed by attempt token rather than a shared bool:
  /// with overlapping connects a rejection on a superseded attempt would
  /// otherwise leak into a newer attempt's catch and misclassify its genuine
  /// failure as a clean cancel.
  int? _hostKeyCancelledAttempt;

  @override
  ConnectionState build() => const ConnectionState();

  /// The [SSHClientManager.connect] `onVerifyHostKey` callback: trusts a host
  /// on first use, silently accepts a key that matches what was already
  /// trusted, and — for anything else — pauses on an explicit human decision
  /// via [ConnectionState.hostKeyPrompt] rather than ever silently accepting
  /// or rejecting a changed key.
  Future<bool> _verifyHostKey(
    int attempt,
    String host,
    int port,
    String type,
    Uint8List fingerprintBytes,
  ) async {
    final fingerprint = utf8.decode(fingerprintBytes);
    final store = ref.read(knownHostsStoreProvider);
    final existing = await store.lookup(host, port);
    if (existing == null) {
      // Trust on first use — record the key so a later change is detectable.
      await store.remember(
        host,
        port,
        KnownHostEntry(keyType: type, fingerprint: fingerprint),
      );
      return true;
    }
    if (existing.keyType == type && existing.fingerprint == fingerprint) {
      // Already trusted this exact key; skip the disk write so every
      // connect/reconnect isn't a needless known-hosts rewrite.
      return true;
    }

    final decision = Completer<bool>();
    _hostKeyDecision = decision;
    state = state.copyWith(
      hostKeyPrompt: HostKeyPrompt(
        host: host,
        port: port,
        previousKeyType: existing.keyType,
        previousFingerprint: existing.fingerprint,
        newKeyType: type,
        newFingerprint: fingerprint,
      ),
    );
    final accepted = await decision.future;
    _hostKeyDecision = null;
    state = state.copyWith(clearHostKeyPrompt: true);
    if (accepted) {
      await store.remember(
        host,
        port,
        KnownHostEntry(keyType: type, fingerprint: fingerprint),
      );
    } else {
      _hostKeyCancelledAttempt = attempt;
    }
    return accepted;
  }

  /// "Refresh Key and Continue" — trusts the newly presented key and lets the
  /// in-progress connection attempt proceed. Guarded by [isCompleted]: unlike
  /// `_hostKeyDecision` being nulled (which only happens asynchronously, inside
  /// `_verifyHostKey`'s continuation after its future resolves), a duplicate or
  /// re-entrant call within the same synchronous tick could otherwise complete
  /// an already-completed `Completer` and throw an uncaught `StateError`.
  void acceptHostKeyChange() {
    if (!(_hostKeyDecision?.isCompleted ?? true)) {
      _hostKeyDecision!.complete(true);
    }
  }

  /// "Cancel Connection" — rejects the new key; the connection attempt aborts.
  /// See [acceptHostKeyChange] for why this guards [isCompleted].
  void rejectHostKeyChange() {
    if (!(_hostKeyDecision?.isCompleted ?? true)) {
      _hostKeyDecision!.complete(false);
    }
  }

  /// Invalidates every repo-scoped provider so a fresh session never serves the
  /// previous connection's cached branch/files/log/refs/GitLab data even if a
  /// repo path collides across hosts. Every family provider keyed by a bare
  /// `String repoPath` (or a tuple starting with one) needs to be listed here —
  /// `ref.invalidate(someFamilyProvider)` (no argument) invalidates *every*
  /// keyed instance of that family at once, not just one repoPath. Previously
  /// this covered only 5 of the ~20 repo-scoped families; the rest (file/commit
  /// diffs, blame, conflict view, file history, the repo tree, the watcher, and
  /// every GitLab panel) relied on autoDispose tearing them down via view
  /// unmount timing during the connecting/lost phase — real, but incidental,
  /// not a guarantee.
  void _invalidateRepoState() {
    ref.invalidate(statusProvider);
    ref.invalidate(pendingOpProvider);
    ref.invalidate(logProvider);
    ref.invalidate(logSearchProvider);
    ref.invalidate(refsProvider);
    ref.invalidate(stashesProvider);
    ref.invalidate(stashDiffProvider);
    ref.invalidate(prepareCommitMsgHookProvider);
    ref.invalidate(repoStructureProvider);
    ref.invalidate(repoStatusOverlayProvider);
    ref.invalidate(repoWatchProvider);
    ref.invalidate(fileLogProvider);
    ref.invalidate(blameProvider);
    ref.invalidate(fileDiffProvider);
    ref.invalidate(commitDiffProvider);
    ref.invalidate(commitFileDiffProvider);
    ref.invalidate(conflictFileProvider);
    ref.invalidate(untrackedDiffProvider);
    // These 7 keep their entries alive across a bounded LRU (see
    // _KeepAliveLru) rather than plain autoDispose — release every held link
    // alongside the invalidations above so a stale connection's entries don't
    // linger in the LRUs' own bookkeeping.
    _fileLogLru.clear();
    _blameLru.clear();
    _fileDiffLru.clear();
    _commitDiffLru.clear();
    _commitFileDiffLru.clear();
    _conflictFileLru.clear();
    _untrackedDiffLru.clear();
    // Keyed purely by repoPath with no connection identity — without this, a
    // mutation marked just before disconnecting could suppress a genuinely
    // external change reported by a *different* connection that happens to
    // reuse the same repoPath (e.g. two hosts both mounting a repo at the
    // same conventional path).
    ref.read(ownMutationTrackerProvider).clear();
    ref.invalidate(mergeRequestsProvider);
    ref.invalidate(pipelinesProvider);
    ref.invalidate(jobsProvider);
    ref.invalidate(jobTraceProvider);
    ref.invalidate(projectDashboardProvider);
    // Forge detection + GitHub providers — same rationale as the GitLab set:
    // a repo switch / reconnect must never serve the previous repo's forge
    // classification or cross-host PR/run/issue data.
    ref.invalidate(forgeProvider);
    ref.invalidate(pullRequestsProvider);
    ref.invalidate(workflowRunsProvider);
    ref.invalidate(runJobsProvider);
    ref.invalidate(runJobLogProvider);
    ref.invalidate(githubProjectDashboardProvider);
  }

  /// The executor for [state]'s current backend, read directly off `state`
  /// rather than through [activeExecutorProvider]. That provider watches
  /// [connectionProvider] (to react to backend switches from *other*
  /// consumers like [gitServiceProvider]) — but reading a provider that
  /// depends on `connectionProvider` from *within* this very notifier's own
  /// methods is a self-reference Riverpod's cycle detector rejects outright
  /// (`CircularDependencyError`). Reading `state.backend` directly (already
  /// available as a plain field on this Notifier, no provider graph
  /// involved) sidesteps that entirely.
  CommandExecutor get _activeExecutor => switch (state.backend) {
    ConnectionBackend.local => ref.read(localExecutorProvider),
    ConnectionBackend.ssh => ref.read(executorProvider),
  };

  /// Probes for the active backend's OS + binary locations (honoring settings
  /// overrides), configures the executor's augmented PATH / binary rewrites, and
  /// publishes the result for the Settings panel. Best-effort — any failure
  /// leaves bare-name invocation in place. Meaningful for a local session too:
  /// a Finder-launched GUI app's inherited PATH is often as bare as an SSH
  /// exec channel's (e.g. missing a Homebrew `/opt/homebrew/bin`), and
  /// [EnvironmentResolver]'s probe script has no SSH-specific logic.
  /// The ambient forge-token env vars to neutralize for the current session: a
  /// forge's vars only when this connection supplied that forge's token, so
  /// Magic Git's managed identity wins over any ambient token. A connection
  /// that supplied no token neutralizes nothing, leaving the remote's own
  /// `gh`/`glab` auth (a stored credential or an ambient token — the CLI's own
  /// default) untouched. See [CommandFormatter].
  List<String> _forgeTokenVarsToNeutralize() => [
    if ((_lastGitlabToken ?? '').isNotEmpty) ...CommandFormatter.gitlabTokenVars,
    if ((_lastGithubToken ?? '').isNotEmpty) ...CommandFormatter.githubTokenVars,
  ];

  Future<void> _resolveEnvironment(String repoPath, {int? attempt}) async {
    try {
      final overrides = ref.read(appSettingsProvider).binaryOverrides;
      final executor = _activeExecutor;
      final env = await EnvironmentResolver(
        executor,
      ).resolve(repoPath, overrides: overrides);
      // A superseded connect's env probe can still be running on the old client
      // when a newer connect has already reset the shared executor; re-check the
      // attempt token immediately before touching it, so a stale probe can't
      // reconfigure the executor (or republish the environment) with the old
      // host's PATH/binaries. Mirrors connect()'s attempt-token checks. A null
      // attempt (reprobeBinaries, run while connected) is always current.
      if (attempt != null && attempt != _attempt) return;
      executor.configureEnvironment(path: env.path, binaries: env.found);
      executor.setForgeTokenNeutralization(_forgeTokenVarsToNeutralize());
      ref.read(binaryEnvironmentProvider.notifier).set(env);
    } catch (e) {
      // Same supersession check as the success path above: a probe left
      // running on a since-abandoned attempt must not log its failure as if
      // it were the *current* connection's problem.
      if (attempt != null && attempt != _attempt) return;
      if (!ref.mounted) return;
      // Leave the executor unconfigured; commands use the inherited PATH.
      // Still surfaced so a persistently failing probe is discoverable
      // instead of silently leaving every command unconfigured all session.
      ref
          .read(outputLogProvider.notifier)
          .logError('environment detection', e.toString());
    }
  }

  /// Re-runs binary resolution against the active repo (e.g. after the user
  /// edits path overrides in Settings). No-op when disconnected.
  Future<void> reprobeBinaries() async {
    final repoPath = state.repoPath;
    if (!state.isConnected || repoPath == null) return;
    await _resolveEnvironment(repoPath);
  }

  /// Best-effort background fetch for [repoPath], fired right after a local
  /// mutation (currently: a successful commit) so ahead/behind reflects the
  /// remote's current state immediately instead of waiting for the next
  /// manual fetch or the next [autoFetchProvider] tick. Uses this
  /// controller's own `ref` rather than a caller's widget `ref`, so callers
  /// can fire-and-forget it without it breaking if their own widget unmounts
  /// (e.g. the commit dialog closing) before the fetch completes.
  Future<void> fetchInBackground(String repoPath) async {
    // Pinned at call time: the connection can be superseded (disconnect, or a
    // fresh connect — possibly to a *different* host that happens to reuse
    // this same repoPath) while this fetch is in flight. The remote command
    // itself is already generation-guarded (SSHCommandExecutor refuses a
    // superseded attempt), but without this check its success/failure
    // handling below would still mark/invalidate/log against whatever
    // connection is active *now*, not the one this fetch was meant for.
    final attempt = _attempt;
    try {
      await ref.read(gitServiceProvider).fetch(repoPath);
      if (attempt != _attempt || !ref.mounted) return;
      ref.read(ownMutationTrackerProvider).mark(repoPath);
      ref.invalidate(refsProvider(repoPath));
      ref.invalidate(statusProvider(repoPath));
    } catch (e) {
      if (attempt != _attempt || !ref.mounted) return;
      ref
          .read(outputLogProvider.notifier)
          .logError('git fetch (post-commit)', e.toString());
    }
  }

  Future<void> connect({
    required SSHConnectionProfile profile,
    required String repoPath,
    String? gitlabToken,
    String? githubToken,
    String? connectionId,
    String? connectionLabel,
    List<String>? repoPaths,
    List<String> fsmonitorPaths = const [],
    bool reconnecting = false,
  }) async {
    final attempt = ++_attempt;
    // Supersede any host-key prompt still pending from the attempt we're
    // replacing. Without this, switching connections while a key-mismatch prompt
    // is open (the switcher stays reachable) orphans the old attempt's Completer:
    // `_verifyHostKey` awaits it forever, `awaitingHostKeyDecision` stays true so
    // the pausable auth timeout re-arms indefinitely, and the authenticating
    // client + socket leak until an explicit disconnect. Reject it (safe default),
    // exactly as disconnect() does. Guarded by isCompleted — see
    // acceptHostKeyChange for why a duplicate completion must be a no-op.
    if (!(_hostKeyDecision?.isCompleted ?? true)) {
      _hostKeyDecision!.complete(false);
    }
    _hostKeyDecision = null;
    // Switching straight from a bookmark-backed local repo to an SSH host (the
    // switcher stays reachable, so no explicit disconnect is required) — release
    // the local folder's security-scoped access, which neither disconnect() nor
    // connectLocal() would get a chance to do here. Without this the sandbox
    // grant leaks for the app's lifetime. Safe/no-op if the prior session wasn't
    // a bookmark-backed local one.
    if (state.isLocal && state.repoPath != null) {
      await SecurityScopedBookmark.stopAccessing(state.repoPath!);
    }
    // While reconnecting, keep the popup up (and its attempt number) across this
    // transient connecting phase instead of falling back to the landing card.
    final attemptNo = reconnecting ? state.reconnectAttempt : 0;
    _lastProfile = profile;
    _lastRepoPath = repoPath;
    _lastGitlabToken = gitlabToken;
    _lastGithubToken = githubToken;
    _lastConnectionId = connectionId;
    _lastConnectionLabel = connectionLabel;
    _lastRepoPaths = repoPaths;
    _lastFsmonitorPaths = fsmonitorPaths;
    _invalidateRepoState();
    // A fresh connection to a different host/repo shouldn't keep showing the
    // previous session's command output — but an auto-reconnect attempt to
    // the *same* connection should, since that history (including why it
    // dropped) is still relevant.
    if (!reconnecting) {
      ref.read(outputLogProvider.notifier).clear();
    }
    // Clear the previous connection's resolved environment up front. Switching
    // hosts (e.g. a macOS laptop → a Linux bastion) means a different OS, PATH,
    // and binary locations; without this reset, validateRepoPath and every early
    // command would run the old host's absolute paths (e.g. /opt/homebrew/bin/git)
    // against the new host and fail. _resolveEnvironment re-probes below.
    ref.read(executorProvider).resetEnvironment();
    ref.read(binaryEnvironmentProvider.notifier).clear();
    // Identity fields (host/label/connectionId/repoPath) are set from this
    // attempt's own parameters — known upfront, never inherited from
    // whatever `state` happened to hold before this call. That matters for
    // *this* attempt's target, which is always correct here, unlike a blind
    // `state.copyWith(...)` would be for a fresh connect to a different host
    // than whatever was previously displayed. It also means the "Reconnecting…
    // / Lost contact with X" UI keeps showing the right host across every
    // retry instead of losing it the instant a retry begins.
    state = ConnectionState(
      phase: ConnectionPhase.connecting,
      reconnecting: reconnecting,
      reconnectAttempt: attemptNo,
      repoPath: repoPath,
      connectionId: connectionId,
      connectionLabel: connectionLabel ?? profile.host,
      host: profile.host,
    );
    try {
      await ref
          .read(sshClientManagerProvider)
          .connect(
            profile,
            onVerifyHostKey: (type, fingerprintBytes) => _verifyHostKey(
              attempt,
              profile.host,
              profile.port,
              type,
              fingerprintBytes,
            ),
          );
      // Superseded by a newer connect or a disconnect while we were resolving —
      // don't overwrite the current state (the SSH manager has already torn its
      // superseded client down).
      if (attempt != _attempt || !ref.mounted) return;

      // Detect the remote OS and resolve external binaries FIRST, augmenting
      // the exec-channel PATH so user-installed tools (e.g. Homebrew's
      // git/glab/fswatch in /opt/homebrew/bin) are found. Doing this before
      // validateRepoPath matters: the validation runs `git`, and a git that
      // lives only on a common user path (or a genuinely missing git) would
      // otherwise fail here as a misleading "not a git repository". Best-effort:
      // on probe failure we fall back to bare-name lookup against the inherited
      // PATH, and validateRepoPath still surfaces a real problem.
      await _resolveEnvironment(repoPath, attempt: attempt);
      if (attempt != _attempt || !ref.mounted) return;

      await ref.read(gitServiceProvider).validateRepoPath(repoPath);
      if (attempt != _attempt || !ref.mounted) return;

      // Apply per-repo fsmonitor tuning for every opted-in repo in ONE round
      // trip (each used to be its own — a per-repo SSH round trip before the
      // session became usable). Best-effort and per-repo non-fatal — status
      // works fine without it; a failed repo is reported on stderr by the
      // combined script and logged here, so a persistently-rejected tuning
      // command stays discoverable instead of silently degrading refresh
      // performance all session with no trace.
      if (fsmonitorPaths.isNotEmpty) {
        try {
          final result = await ref
              .read(gitServiceProvider)
              .setFsmonitorMany(fsmonitorPaths, enabled: true);
          if (attempt != _attempt || !ref.mounted) return;
          if (result.stderr.trim().isNotEmpty) {
            ref
                .read(outputLogProvider.notifier)
                .logError('fsmonitor setup', result.stderr.trim());
          }
        } catch (e) {
          if (attempt != _attempt || !ref.mounted) return;
          ref
              .read(outputLogProvider.notifier)
              .logError('fsmonitor setup', e.toString());
        }
      }
      if (attempt != _attempt || !ref.mounted) return;

      // Both forge logins are independent one-shot writes to different CLIs'
      // credential stores — run them concurrently rather than paying two
      // serialized round-trip sequences at every connect. Each maps its own
      // failure to a non-fatal warning; connect() itself never fails on one.
      String? warning;
      final loginWarnings = await Future.wait([
        if (gitlabToken != null && gitlabToken.isNotEmpty)
          ref
              .read(glabServiceProvider)
              .loginWithToken(repoPath, gitlabToken)
              .then<String?>(
                (_) => null,
                onError: (Object e) =>
                    'GitLab token login failed — GitLab panels may not work '
                    'until the remote is authenticated. ($e)',
              ),
        if (githubToken != null && githubToken.isNotEmpty)
          ref
              .read(ghServiceProvider)
              .loginWithToken(repoPath, githubToken)
              .then<String?>(
                (_) => null,
                onError: (Object e) =>
                    'GitHub token login failed — GitHub panels may not work '
                    'until the remote is authenticated. ($e)',
              ),
      ]);
      if (attempt != _attempt || !ref.mounted) return;
      final warnings = loginWarnings.whereType<String>().toList();
      if (warnings.isNotEmpty) warning = warnings.join('\n');

      final repos = SavedConnection.dedupePaths([repoPath, ...?repoPaths]);
      state = ConnectionState(
        phase: ConnectionPhase.connected,
        repoPath: repoPath,
        repoPaths: repos,
        connectionId: connectionId,
        connectionLabel: connectionLabel ?? profile.host,
        host: profile.host,
        warning: warning,
      );
      // Best-effort recency bump so this profile floats to the top of the
      // landing page's recent list; never blocks a successful connect.
      if (connectionId != null) {
        try {
          await ref.read(connectionStoreProvider).touch(connectionId);
          ref.invalidate(savedConnectionsProvider);
        } catch (_) {}
      }
      _watchForDrop(attempt);
    } catch (e) {
      if (attempt != _attempt || !ref.mounted) return;
      if (_hostKeyCancelledAttempt == attempt) {
        // The user explicitly declined the changed host key via the mismatch
        // prompt — a deliberate, clean cancellation, not a connection
        // failure. Reset all the way to disconnected (mirroring [disconnect])
        // rather than `error`/`lost`, so this neither shows a scary message
        // nor (on a reconnect attempt) resumes the auto-reconnect loop, which
        // would just hit the exact same mismatch and re-prompt forever.
        state = const ConnectionState();
        return;
      }
      // A failed *reconnect* stays in the reconnecting popup (as `lost`) so
      // _autoReconnect keeps retrying; a failed *initial* connect surfaces the
      // error to the landing card as before. Identity fields carried through
      // from this attempt's own parameters, same reasoning as the connecting
      // state above — the "Lost contact with X" popup must still name the
      // right host on a failed retry, not just on the first drop.
      state = ConnectionState(
        phase: reconnecting ? ConnectionPhase.lost : ConnectionPhase.error,
        error: e.toString(),
        reconnecting: reconnecting,
        reconnectAttempt: attemptNo,
        repoPath: repoPath,
        connectionId: connectionId,
        connectionLabel: connectionLabel ?? profile.host,
        host: profile.host,
      );
    }
  }

  /// Opens a repo on this machine's own filesystem — no SSH client, no host
  /// key, no environment probe of a *remote* host (though [_resolveEnvironment]
  /// still runs, since a Finder-launched GUI app's own PATH can be just as
  /// bare as an SSH exec channel's), and no drop-watching/auto-reconnect
  /// (there is no transport to drop). Reuses the same [ConnectionState]/
  /// [ConnectionPhase] machinery as [connect] so `app_shell.dart`'s routing —
  /// and every repo-scoped provider — needs zero changes to serve a local
  /// session.
  Future<void> connectLocal(String repoPath, {String? label, String? id}) async {
    final attempt = ++_attempt;
    // Same supersession guard as connect(): a host-key prompt left open from
    // a still-in-flight SSH attempt must not orphan its Completer just
    // because the user switched to opening a local repo instead.
    if (!(_hostKeyDecision?.isCompleted ?? true)) {
      _hostKeyDecision!.complete(false);
    }
    _hostKeyDecision = null;
    // A local session has no SSH profile to reconnect with, and isn't itself
    // reconnectable (no drop concept) — an explicit local open, like an
    // explicit disconnect, must not leave a stale SSH profile behind for
    // `reconnect()` to act on later.
    _lastProfile = null;
    _lastRepoPath = null;
    // A local session carries no forge token (connectLocal has no token
    // params), so it must not inherit a prior SSH session's neutralization
    // decision — clear them, so _forgeTokenVarsToNeutralize() leaves this
    // machine's own gh/glab auth untouched.
    _lastGitlabToken = null;
    _lastGithubToken = null;
    // Release the *previous* session's transport before starting the new one —
    // the switcher lets the user jump straight here with no explicit disconnect.
    if (state.isLocal) {
      // local → local: release the prior repo's security-scoped access. Safe/
      // no-op if that session was never bookmark-backed.
      if (state.repoPath != null && state.repoPath != repoPath) {
        await SecurityScopedBookmark.stopAccessing(state.repoPath!);
      }
    } else if (state.repoPath != null) {
      // ssh → local: tear down the authenticated SSH client and socket.
      // connectLocal has no SSH connect() to supersede it, and a later local
      // disconnect() deliberately skips SSH teardown — so without this the
      // client leaks until the next SSH connect or app quit. (repoPath is null
      // on a fresh launch, so this doesn't fire before any SSH session existed.)
      ref.read(executorProvider).resetEnvironment();
      await ref.read(sshClientManagerProvider).disconnect();
    }
    _invalidateRepoState();
    ref.read(outputLogProvider.notifier).clear();
    ref.read(localExecutorProvider).resetEnvironment();
    ref.read(binaryEnvironmentProvider.notifier).clear();
    // `backend: local` is set immediately — before anything below reads
    // `activeExecutorProvider` (via `gitServiceProvider`) — so every command
    // this attempt issues routes to `LocalCommandExecutor`, not the SSH one.
    state = ConnectionState(
      phase: ConnectionPhase.connecting,
      backend: ConnectionBackend.local,
      repoPath: repoPath,
      connectionId: id,
      connectionLabel: label,
    );
    try {
      // Resolve the environment FIRST so the augmented PATH / absolute git path
      // is in place before any git runs. A Finder-launched app inherits a bare
      // PATH; without this, a Homebrew-only git (/opt/homebrew/bin) would make
      // the validations below fail as a misleading "not a git repository".
      await _resolveEnvironment(repoPath, attempt: attempt);
      if (attempt != _attempt || !ref.mounted) return;

      // Doubles as "is this actually a git repo" validation — a folder that
      // isn't fails here with a clear GitException rather than silently
      // landing in the connected shell with nothing to show.
      await ref.read(gitServiceProvider).validateRepoPath(repoPath);
      if (attempt != _attempt || !ref.mounted) return;

      // Local-only: the sandbox grant covers just this folder, so reject a
      // picked subdirectory / linked worktree / submodule whose real git dir is
      // outside it now, with a clear message, rather than a raw permission error
      // on the first real read.
      await ref.read(gitServiceProvider).validateLocalRepoRoot(repoPath);
      if (attempt != _attempt || !ref.mounted) return;

      bool? fsmonitorEnabled;
      if (id != null) {
        for (final r in await ref.read(localRepoStoreProvider).list()) {
          if (r.id == id) {
            fsmonitorEnabled = r.fsmonitorEnabled;
            break;
          }
        }
      }
      if (fsmonitorEnabled == true) {
        if (attempt != _attempt || !ref.mounted) return;
        try {
          await ref.read(gitServiceProvider).setFsmonitor(repoPath, enabled: true);
        } catch (e) {
          if (attempt != _attempt || !ref.mounted) return;
          ref
              .read(outputLogProvider.notifier)
              .logError('fsmonitor setup ($repoPath)', e.toString());
        }
      }
      if (attempt != _attempt || !ref.mounted) return;

      state = ConnectionState(
        phase: ConnectionPhase.connected,
        backend: ConnectionBackend.local,
        repoPath: repoPath,
        repoPaths: [repoPath],
        connectionId: id,
        connectionLabel: label,
      );
      // Best-effort recency bump; never blocks a successful open.
      if (id != null) {
        try {
          await ref.read(localRepoStoreProvider).touch(id);
          ref.invalidate(savedLocalReposProvider);
        } catch (_) {}
      }
    } catch (e) {
      if (attempt != _attempt || !ref.mounted) return;
      state = ConnectionState(
        phase: ConnectionPhase.error,
        backend: ConnectionBackend.local,
        error: e.toString(),
        repoPath: repoPath,
        connectionId: id,
        connectionLabel: label,
      );
    }
  }

  /// Connects to a saved profile, loading its secrets from the store. Opens at
  /// [repoPath] when given, otherwise the connection's default repo.
  Future<void> connectToSaved(SavedConnection conn, {String? repoPath}) async {
    final store = ref.read(connectionStoreProvider);
    String? secret, token, ghToken, key, passphrase;
    try {
      // Read all secrets concurrently — they're independent Keychain lookups,
      // so serializing them just adds latency to every connect.
      final secrets = await Future.wait([
        store.secretFor(conn.id),
        store.gitlabTokenFor(conn.id),
        store.githubTokenFor(conn.id),
        store.privateKeyFor(conn.id),
        store.passphraseFor(conn.id),
      ]);
      secret = secrets[0];
      token = secrets[1];
      ghToken = secrets[2];
      key = secrets[3];
      passphrase = secrets[4];
    } catch (_) {
      // Secrets unavailable (e.g. unsigned build without a dotfile) — the
      // connection may still succeed via agent/other auth, or fail cleanly.
    }
    String? notEmpty(String? v) => (v != null && v.isNotEmpty) ? v : null;
    await connect(
      profile: SSHConnectionProfile(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: notEmpty(secret),
        privateKey: notEmpty(key),
        passphrase: notEmpty(passphrase),
      ),
      repoPath: repoPath ?? conn.repoPath,
      gitlabToken: token,
      githubToken: ghToken,
      connectionId: conn.id,
      connectionLabel: conn.displayName,
      repoPaths: conn.allRepoPaths,
      fsmonitorPaths: conn.fsmonitorPaths,
    );
  }

  /// Watches the live connection's transport; if it closes while this attempt is
  /// still the active, connected session, transitions to the `lost` phase so the
  /// UI can offer a one-click reconnect (rather than failing the next command).
  void _watchForDrop(int attempt) {
    final done = ref.read(sshClientManagerProvider).done;
    if (done == null) return;
    // An abrupt network loss can complete `done` with an *error* rather than
    // normally; handle both so the drop is always caught (previously an
    // error-completion slipped through, leaving the next git command to fail
    // with an ugly dialog and no reconnect).
    done
        .then((_) => _onTransportClosed(attempt))
        .catchError((Object _) => _onTransportClosed(attempt));
  }

  void _onTransportClosed(int attempt) {
    if (attempt != _attempt || !ref.mounted) return;
    if (state.phase != ConnectionPhase.connected) return; // intentional close
    state = state.copyWith(
      phase: ConnectionPhase.lost,
      error: 'Connection lost',
      reconnecting: true,
    );
    _autoReconnect();
  }

  /// Backoff schedule for automatic reconnection after an unexpected drop.
  static const _reconnectDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];

  /// Automatically retries the last connection after a drop, **indefinitely**,
  /// with bounded backoff (the schedule, then its last delay repeated) — so the
  /// popup keeps trying "until it reconnects" or the user cancels. Aborts the
  /// moment a user action (new connect / disconnect / cancel) bumps [_attempt].
  /// After this many attempts (~4 minutes of backoff-bounded retries), pause
  /// automatically and require explicit user confirmation to keep trying —
  /// without this, a permanently unreachable host (VPN down, laptop closed,
  /// decommissioned server) left open unattended drives a connect+auth cycle
  /// every 15s forever.
  static const int _maxAutoReconnectAttempts = 20;

  Future<void> _autoReconnect() async {
    var i = 0;
    while (true) {
      // Snapshot the generation before waiting; a user action during the wait
      // changes it and must cancel the loop.
      final gen = _attempt;
      if (!ref.mounted || _attempt != gen) return;
      if (state.phase != ConnectionPhase.lost) return;
      if (i >= _maxAutoReconnectAttempts) {
        // Same effect as the user tapping "Stop Retrying": stay `lost`, but
        // stop retrying until they explicitly ask to reconnect.
        state = state.copyWith(reconnecting: false);
        return;
      }
      state = state.copyWith(reconnectAttempt: i + 1, reconnecting: true);

      final delay = _reconnectDelays[i < _reconnectDelays.length
          ? i
          : _reconnectDelays.length - 1];
      await Future<void>.delayed(delay);
      if (!ref.mounted || _attempt != gen) return;
      if (state.phase != ConnectionPhase.lost) return;

      await reconnect(); // bumps _attempt; connects or lands back in `lost`
      if (!ref.mounted) return;
      if (state.isConnected) return; // success re-armed the drop watcher
      // `reconnect()` always passes `reconnecting: true`, so a *legitimate*
      // (non-superseded) failure always lands `state` back in `lost` itself
      // (see the catch branch in `connect`) — `connect` already detects and
      // silently drops its own result when superseded by a concurrent
      // disconnect or a fresh user-initiated connect, leaving `state` exactly
      // as that other action set it. So if `state` isn't `lost` here, this
      // loop's attempt was superseded; stop rather than stomping whatever the
      // other action set back to `lost` (previously this unconditionally
      // forced it back, silently resurrecting the reconnect popup right after
      // the user had cancelled it).
      if (state.phase != ConnectionPhase.lost) return;
      i++;
    }
  }

  /// Stops an in-progress auto-reconnect loop (leaves the session `lost` so the
  /// user can reconnect manually or start fresh).
  void stopReconnect() {
    ++_attempt; // supersede the loop
    if (state.phase == ConnectionPhase.lost || state.reconnectAttempt > 0) {
      state = state.copyWith(reconnectAttempt: 0, reconnecting: false);
    }
  }

  /// Re-establishes the last connection after a drop, reusing its profile/repo.
  Future<void> reconnect() async {
    final profile = _lastProfile;
    final repoPath = _lastRepoPath;
    if (profile == null || repoPath == null) return;
    await connect(
      profile: profile,
      repoPath: repoPath,
      gitlabToken: _lastGitlabToken,
      githubToken: _lastGithubToken,
      connectionId: _lastConnectionId,
      connectionLabel: _lastConnectionLabel,
      repoPaths: _lastRepoPaths,
      fsmonitorPaths: _lastFsmonitorPaths,
      reconnecting: true,
    );
  }

  /// Switches the active repository on the current host (no reconnect).
  void setRepoPath(String path) {
    if (!state.isConnected || path.isEmpty || path == state.repoPath) return;
    final repos = state.repoPaths.contains(path)
        ? state.repoPaths
        : [...state.repoPaths, path];
    _invalidateRepoState();
    // The output view otherwise keeps showing the previous repo's command
    // history alongside the newly selected one, which reads as if it came
    // from the repo just switched to.
    ref.read(outputLogProvider.notifier).clear();
    state = state.copyWith(
      repoPath: path,
      repoPaths: repos,
      clearWarning: true,
    );
  }

  Future<void> disconnect() async {
    ++_attempt; // supersede any in-flight connect
    _lastProfile = null; // an explicit disconnect is not reconnectable
    // The sidebar's connection switcher stays reachable even while a host-key
    // prompt covers the content area, so a disconnect can race a still-open
    // prompt — reject it (the safe default) rather than leaving its Completer
    // dangling forever. Guarded by isCompleted — see acceptHostKeyChange for
    // why a duplicate completion must be a no-op.
    if (!(_hostKeyDecision?.isCompleted ?? true)) {
      _hostKeyDecision!.complete(false);
    }
    _hostKeyDecision = null;
    if (state.isLocal) {
      // No SSH client to tear down — a local session never established one.
      ref.read(localExecutorProvider).resetEnvironment();
      // Safe/no-op if this session was never bookmark-backed in the first
      // place (an unsaved/ad-hoc local open).
      final repoPath = state.repoPath;
      if (repoPath != null) {
        await SecurityScopedBookmark.stopAccessing(repoPath);
      }
    } else {
      ref.read(executorProvider).resetEnvironment();
      await ref.read(sshClientManagerProvider).disconnect();
    }
    ref.read(binaryEnvironmentProvider.notifier).clear();
    _invalidateRepoState();
    state = const ConnectionState();
  }
}

final connectionProvider =
    NotifierProvider<ConnectionController, ConnectionState>(
      ConnectionController.new,
    );

/// The remote host's detected OS and resolved external-binary locations for the
/// active connection, published for the Settings panel. Empty until a
/// connection resolves it (see [ConnectionController._resolveEnvironment]).
class BinaryEnvironmentNotifier extends Notifier<RemoteEnvironment> {
  @override
  RemoteEnvironment build() => RemoteEnvironment.empty;
  void set(RemoteEnvironment env) => state = env;
  void clear() => state = RemoteEnvironment.empty;
}

final binaryEnvironmentProvider =
    NotifierProvider<BinaryEnvironmentNotifier, RemoteEnvironment>(
      BinaryEnvironmentNotifier.new,
    );

/// Tracks the most recent moment this app itself mutated a repo's `.git`
/// state (stage/commit/push/fetch/…), so a remote-watcher tick that arrives
/// shortly after can be recognized as almost certainly reporting that very
/// same self-inflicted change — not a genuinely external one — and skipped.
///
/// The watcher's exclude filters deliberately do NOT cover `.git/index`,
/// `HEAD`, `refs/**`, etc.: those are exactly the paths any external `git`
/// invocation on the same host touches, and detecting *that* is the watcher's
/// whole purpose. Filtering them out at the source would silently blind the
/// app to another session's changes, not just this app's own. Time-windowed
/// suppression here instead targets only the redundant case — this app's own
/// mutating action already invalidated [statusProvider] explicitly and
/// immediately; the watcher noticing the same write 150ms-a few seconds later
/// (SSH round trip + coalescing) would otherwise invalidate it a second time
/// for no new information.
///
/// Plain mutable state, not reactive — nothing needs to watch a mark, only
/// read the latest timestamp when a watch tick arrives.
class OwnMutationTracker {
  final _lastByRepo = <String, DateTime>{};

  /// Well beyond any real suppression window (a few seconds) — entries older
  /// than this are dead weight, evicted so a session that connects to many
  /// distinct ad-hoc repo paths over time doesn't grow this map unbounded.
  static const _staleAfter = Duration(minutes: 1);

  void mark(String repoPath) {
    final now = DateTime.now();
    _lastByRepo[repoPath] = now;
    _lastByRepo.removeWhere((_, at) => now.difference(at) > _staleAfter);
  }

  bool isRecent(String repoPath, DateTime at, Duration within) {
    final last = _lastByRepo[repoPath];
    return last != null && at.difference(last) < within;
  }

  /// Discards every mark. Called alongside the repo-scoped provider
  /// invalidations on connect/disconnect/repo-switch (see
  /// [ConnectionController._invalidateRepoState]) so a mark recorded against
  /// a previous connection can never suppress a genuinely external change
  /// reported by a new one.
  void clear() => _lastByRepo.clear();
}

final ownMutationTrackerProvider = Provider<OwnMutationTracker>((ref) {
  return OwnMutationTracker();
});

/// Working-tree status for a repo path, keyed so multiple repos can coexist.
/// autoDispose so it's discarded when [RepoStatusView] unmounts on disconnect
/// (and explicitly invalidated on connect/disconnect) — a reconnect never
/// serves the previous session's branch/files. Refresh with
/// `ref.invalidate(statusProvider(repoPath))`.
final statusProvider = FutureProvider.autoDispose.family<GitStatus, String>((
  ref,
  repoPath,
) async {
  final status = await ref.watch(gitServiceProvider).status(repoPath);
  // `parseWarnings` records any porcelain status record that failed its
  // expected field-count check and was dropped (e.g. output truncated by a
  // transport hiccup) — computed so the drop is inspectable instead of
  // silent, but nothing previously read it. Surface it in the output log so a
  // status-parsing issue is discoverable rather than vanishing with zero
  // trace.
  if (status.parseWarnings.isNotEmpty) {
    for (final warning in status.parseWarnings) {
      ref
          .read(outputLogProvider.notifier)
          .logError('git status parse warning', warning);
    }
  }
  return status;
});

/// Which git operation (merge / cherry-pick / revert / rebase), if any, is
/// mid-flight, so the Repository panel can offer to continue or abort it.
/// Follows [statusProvider] (refreshes on every watcher tick and after any
/// mutation, no separate invalidation needed). A single cheap state-file check
/// per refresh — and it must run even when conflict-free, because a merge or
/// rebase stays pending after conflicts are resolved until it's committed.
final pendingOpProvider = FutureProvider.autoDispose.family<PendingOp, String>((
  ref,
  repoPath,
) async {
  // Depend on status so this re-runs whenever the working tree changes.
  ref.watch(statusProvider(repoPath));
  return ref.watch(gitServiceProvider).pendingOp(repoPath);
});

/// Background auto-fetch: while connected and a positive interval is configured,
/// periodically `git fetch --prune` the active repo and refresh refs/status, so
/// ahead/behind counts and remote branches stay current without manual fetches.
/// Kept alive by [RepoStatusView]; re-created when the interval or repo changes.
final autoFetchProvider = Provider.autoDispose<void>((ref) {
  final minutes = ref.watch(
    appSettingsProvider.select((s) => s.autoFetchMinutes),
  );
  // Select only the fields this provider actually depends on: `ConnectionState`
  // has no `==` override, so watching the whole object would recreate the
  // Timer (resetting its cadence) on every unrelated state change (a reconnect
  // attempt tick, a warning dismissal, etc.), not just a phase/repo change.
  final (phase, repoPath) = ref.watch(
    connectionProvider.select((s) => (s.phase, s.repoPath)),
  );
  if (minutes <= 0 || phase != ConnectionPhase.connected || repoPath == null) {
    return;
  }
  // A repo with no remote at all has nothing to fetch — arming the timer
  // would just fail every tick and spam the output log with an expected, not
  // actually-broken "git fetch (auto)" error. Common for a local-only repo
  // that was never pushed anywhere.
  //
  // Gated via `.select` down to a single bool so this provider (and its Timer)
  // rebuilds ONLY when the has-remote answer actually flips — not on every
  // `refsProvider` invalidation (the auto-fetch tick's own re-fetch, a
  // post-commit fetch, a watcher-driven refresh). Watching refs directly would
  // tear down and recreate the timer on each of those, resetting its cadence so
  // that on an actively-used repo the interval never elapses and auto-fetch
  // effectively never runs. Null (refs still loading) doesn't block the timer —
  // only a *confirmed* absence of any remote-tracking ref does.
  final hasRemote = ref.watch(
    refsProvider(repoPath).select((a) => a.value?.any((r) => r.isRemote)),
  );
  if (hasRemote == false) {
    return;
  }

  final timer = Timer.periodic(Duration(minutes: minutes), (_) async {
    try {
      await ref.read(gitServiceProvider).fetch(repoPath);
      // The provider can be disposed mid-fetch (disconnect, repo switch, or the
      // interval set to 0 while this round-trip is outstanding). Touching `ref`
      // after disposal throws; onDispose(timer.cancel) only stops *future* ticks.
      if (!ref.mounted) return;
      ref.read(ownMutationTrackerProvider).mark(repoPath);
      ref.invalidate(refsProvider(repoPath));
      ref.invalidate(statusProvider(repoPath));
    } catch (e) {
      // Best-effort — the next tick just retries — but a persistent failure
      // (expired credentials, revoked key) should be discoverable instead of
      // silently going stale forever.
      if (!ref.mounted) return;
      // `disconnect()` awaits the manager's disconnect *before* invalidating
      // repo state / resetting `connectionProvider`'s state, so `phase` is
      // still `connected` during that window and this provider (disposed only
      // once its watched (phase, repoPath) tuple actually changes) stays live.
      // If the timer fires in that narrow window, the fetch fails against the
      // closing connection and would otherwise log a confusing error right
      // as/after the user deliberately disconnected. Skip logging once the
      // phase has already moved on from `connected`.
      if (ref.read(connectionProvider).phase != ConnectionPhase.connected) {
        return;
      }
      ref
          .read(outputLogProvider.notifier)
          .logError('git fetch (auto)', e.toString());
    }
  });
  ref.onDispose(timer.cancel);
});

/// The repository file-tree *structure* for the file-view pane, keyed by
/// repoPath. autoDispose so the `ls-files` work only runs while the pane is
/// open. Gated by [structureSignature] via `selectAsync`, so it re-fetches and
/// rebuilds **only when the set of files/dirs changes** — a plain content edit
/// leaves the signature unchanged and the cached tree is served untouched,
/// keeping status refreshes off this expensive path. Change/untracked coloring
/// lives in [repoStatusOverlayProvider] instead. Large trees are assembled in a
/// background isolate.
final repoStructureProvider = FutureProvider.autoDispose.family<RepoNode, String>(
  (ref, repoPath) async {
    // Re-run only when the tree's shape (not its contents) changes.
    await ref.watch(statusProvider(repoPath).selectAsync(structureSignature));
    final tree = await ref.watch(gitServiceProvider).listWorkingTree(repoPath);
    final files = tree.files;
    final ignored = tree.ignored;
    RepoNode build() => buildRepoTree(files: files, ignored: ignored);
    if (files.length + ignored.length > 3000) {
      return Isolate.run(build);
    }
    return build();
  },
);

/// The change/dirty overlay for the file-view pane, derived from
/// [statusProvider]. Cheap (pure CPU over the status list, no SSH), so it can
/// refresh on every watcher tick without rebuilding the structure tree — the
/// file view recolors atomically from this while [repoStructureProvider] stays
/// put.
final repoStatusOverlayProvider = Provider.autoDispose
    .family<RepoStatusOverlay, String>((ref, repoPath) {
      final status = ref.watch(statusProvider(repoPath)).value;
      return status == null
          ? RepoStatusOverlay.empty
          : RepoStatusOverlay.fromStatus(status);
    });

/// Whether the file-view pane is shown on the Repository panel. Off by default;
/// toggled from the native "View → Show File View" menu item — mirrors the
/// output view's `visible` flag.
class FileViewVisibility extends Notifier<bool> {
  @override
  bool build() => true; // open by default on startup/connect

  void setVisible(bool value) {
    if (state != value) state = value;
  }

  void toggle() => state = !state;
}

final fileViewVisibleProvider = NotifierProvider<FileViewVisibility, bool>(
  FileViewVisibility.new,
);

/// Event-driven "repo changed" ticks from the active backend's watcher.
/// Auto-disposed so the remote fswatch/inotifywait process (or the native
/// `Directory.watch()` subscription, for a local repo) is torn down when no
/// view is listening. Emits a [RepoWatchEvent] per coalesced burst (with
/// [WatchMode]).
final repoWatchProvider = StreamProvider.autoDispose
    .family<RepoWatchEvent, String>((ref, repoPath) {
      final backend = ref.watch(connectionProvider.select((c) => c.backend));
      // Keep the connection-scoped services alive while the watcher runs.
      // Exhaustive switch (no default) so a new backend can't silently fall
      // through to the SSH watcher.
      return switch (backend) {
        ConnectionBackend.local => ref
            .watch(localWatchServiceProvider)
            .watch(repoPath),
        ConnectionBackend.ssh => ref
            .watch(remoteWatchServiceProvider)
            .watch(repoPath),
      };
    });

/// Branches + remote-tracking refs for a repo.
final refsProvider = FutureProvider.autoDispose.family<List<GitRef>, String>((
  ref,
  repoPath,
) {
  return ref.watch(gitServiceProvider).refs(repoPath);
});

/// Commit history (HEAD) for a repo.
final logProvider = FutureProvider.autoDispose.family<List<GitCommit>, String>((
  ref,
  repoPath,
) {
  return ref.watch(gitServiceProvider).log(repoPath);
});

/// A filtered/searched commit log. Keyed by a query record (structural equality
/// gives correct caching). [all] walks every ref; grep/author/since narrow it.
typedef LogQuery = ({
  String repoPath,
  String? grep,
  String? author,
  String? since,
  bool all,
});

final logSearchProvider = FutureProvider.autoDispose
    .family<List<GitCommit>, LogQuery>((ref, q) {
      return ref
          .watch(gitServiceProvider)
          .log(
            q.repoPath,
            grep: q.grep,
            author: q.author,
            since: q.since,
            all: q.all,
          );
    });

/// Ties a **worktree-dependent** cached provider to the repo's most recently
/// *landed* status, so its cached content can never go stale: every completed
/// status refresh (a watcher tick reporting an external edit, this app's own
/// post-mutation refresh, a manual ⌘R) produces a fresh [GitStatus] instance,
/// which invalidates the dependent provider exactly once — an open pane
/// refetches (live-updating its content), and a closed-but-LRU-cached entry is
/// marked dirty so its next open refetches instead of serving stale bytes.
///
/// `select((s) => s.value)` rather than the raw AsyncValue: Riverpod carries
/// the previous data through the loading state (`.value` keeps returning it),
/// so this fires once per completed refresh — not a second, wasted time on
/// the loading transition.
///
/// `ref.listen` + `invalidateSelf` rather than `ref.watch`: a select-based
/// *watch* never observes the watched provider's errors, so if this cache
/// entry happened to be [statusProvider]'s only subscriber (a kept-alive diff
/// after the repo view unmounted, a viewer window on its own), a failed
/// status refresh would surface as an *unhandled* error in the zone. The
/// listener's `onError` swallows it deliberately — a failed status refresh is
/// the status view's problem to display, not this cache's; the cached content
/// simply stays as-is until a refresh lands.
///
/// Deliberately NOT applied to the hash-keyed caches ([commitDiffProvider] /
/// [commitFileDiffProvider]): a commit's patch is immutable, which is exactly
/// what lets those caches be large and long-lived (see [KeepAliveLru]).
void _dependOnWorktreeState(Ref ref, String repoPath) {
  ref.listen(
    statusProvider(repoPath).select((s) => s.value),
    (previous, next) => ref.invalidateSelf(),
    onError: (_, _) {},
  );
}

// The bounded keep-alive LRUs backing the diff/blame/file-history caches live
// in keep_alive_lru.dart (extracted so it's unit-testable). Every cache
// reports payload size via `reportSize` (measured for strings, estimated for
// the list-valued fileLog/blame) so the byte budgets — not just entry counts —
// bound what's pinned.
//
// Budgets are tiered by mutability. Over SSH, RAM is the cheapest resource in
// the system: re-fetching content the user just looked at costs a round trip
// plus remote git work, so the client deliberately holds a generous in-memory
// working set.
//
//  * IMMUTABLE tier (hash-keyed commit patches): content that can never go
//    stale — [_dependOnWorktreeState] deliberately doesn't touch it — so it's
//    cached hard: browsing history stays instant for the whole session.
//  * WORKTREE tier (file diffs, untracked previews, conflict content, blame):
//    invalidated on every landed status refresh, so entries only serve the
//    window between repo changes — still worth real capacity, since "close a
//    diff, reopen it" with no intervening change is the hot path.
const int _mib = 1024 * 1024;

// Immutable tier.
final _commitDiffLru = KeepAliveLru<(String, String)>(
  512,
  maxTotalBytes: 256 * _mib,
  maxEntryBytes: 16 * _mib,
);
final _commitFileDiffLru = KeepAliveLru<(String, String, String)>(
  512,
  maxTotalBytes: 128 * _mib,
  maxEntryBytes: 8 * _mib,
);

// Worktree tier.
final _fileDiffLru = KeepAliveLru<(String, String, bool, bool, int)>(
  64,
  maxTotalBytes: 64 * _mib,
  maxEntryBytes: 8 * _mib,
);
final _untrackedDiffLru = KeepAliveLru<(String, String)>(
  64,
  maxTotalBytes: 32 * _mib,
  maxEntryBytes: 8 * _mib,
);
final _conflictFileLru = KeepAliveLru<(String, String)>(
  32,
  maxTotalBytes: 16 * _mib,
  maxEntryBytes: 4 * _mib,
);
final _fileLogLru = KeepAliveLru<(String, String)>(
  128,
  maxTotalBytes: 32 * _mib,
  maxEntryBytes: 4 * _mib,
);
final _blameLru = KeepAliveLru<(String, String)>(
  64,
  maxTotalBytes: 64 * _mib,
  maxEntryBytes: 8 * _mib,
);

/// Rough resident size of a parsed commit list, for [KeepAliveLru.reportSize]
/// — field code units plus a fixed per-object overhead.
int _estimateCommitListBytes(List<GitCommit> commits) => commits.fold(
  0,
  (n, c) =>
      n +
      c.hash.length +
      c.shortHash.length +
      c.authorName.length +
      c.authorEmail.length +
      c.date.length +
      c.subject.length +
      64,
);

/// Rough resident size of a parsed blame, for [KeepAliveLru.reportSize].
int _estimateBlameBytes(List<BlameLine> lines) => lines.fold(
  0,
  (n, l) =>
      n + l.hash.length + l.author.length + l.summary.length + l.content.length + 48,
);

/// Commits that touched a single file, newest first, following renames — the
/// "file history" view. Keyed by (repoPath, path). Kept alive (bounded LRU)
/// so reopening a file's history doesn't re-fetch over SSH — see
/// [KeepAliveLru].
final fileLogProvider = FutureProvider.autoDispose
    .family<List<GitCommit>, (String, String)>((ref, key) {
      _fileLogLru.touch(key, ref.keepAlive());
      final (repoPath, path) = key;
      final future = ref
          .watch(gitServiceProvider)
          .log(repoPath, path: path, follow: true);
      future.then(
        (v) => _fileLogLru.reportSize(key, _estimateCommitListBytes(v)),
        onError: (_) {},
      );
      return future;
    });

/// Line-by-line blame for a file. Keyed by (repoPath, path). Kept alive
/// (bounded LRU) — see [KeepAliveLru].
final blameProvider = FutureProvider.autoDispose
    .family<List<BlameLine>, (String, String)>((ref, key) {
      _blameLru.touch(key, ref.keepAlive());
      final (repoPath, path) = key;
      // Working-copy blame reads the file as it is on disk right now — an
      // external edit must invalidate it (see _dependOnWorktreeState).
      _dependOnWorktreeState(ref, repoPath);
      final future = ref.watch(gitServiceProvider).blame(repoPath, path);
      future.then(
        (v) => _blameLru.reportSize(key, _estimateBlameBytes(v)),
        onError: (_) {},
      );
      return future;
    });

/// Stashes for a repo.
final stashesProvider = FutureProvider.autoDispose
    .family<List<GitStash>, String>((ref, repoPath) {
      return ref.watch(gitServiceProvider).stashList(repoPath);
    });

/// The patch a single stash holds, for the stash preview pane. Keyed by
/// (repoPath, index).
final stashDiffProvider = FutureProvider.autoDispose
    .family<String, (String, int)>((ref, key) {
      final (repoPath, index) = key;
      return ref.watch(gitServiceProvider).stashShow(repoPath, index);
    });

/// Whether the repo has a prepare-commit-msg hook (message becomes optional /
/// the "Generate" action becomes available). Keyed by repoPath.
final prepareCommitMsgHookProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, repoPath) {
      return ref.watch(gitServiceProvider).hasPrepareCommitMsgHook(repoPath);
    });

/// Unified diff for a single working-tree/staged file. Keyed by
/// (repoPath, path, staged, ignoreWhitespace, context) — records give
/// structural equality for free, so the diff-viewer's hide-whitespace and
/// expand-context toggles re-fetch just by changing the key.
final fileDiffProvider = FutureProvider.autoDispose
    .family<String, (String, String, bool, bool, int)>((ref, key) {
      _fileDiffLru.touch(key, ref.keepAlive());
      final (repoPath, path, staged, ignoreWhitespace, context) = key;
      // A worktree/index diff changes whenever the repo does — every landed
      // status refresh invalidates this so a cached diff can't go stale.
      _dependOnWorktreeState(ref, repoPath);
      final future = ref.watch(gitServiceProvider).diffFile(
        repoPath,
        path: path,
        staged: staged,
        ignoreWhitespace: ignoreWhitespace,
        context: context,
      );
      future.then((d) => _fileDiffLru.reportSize(key, d.length), onError: (_) {});
      return future;
    });

/// Full patch for a commit. Keyed by (repoPath, hash). Kept alive (bounded
/// LRU) — see [KeepAliveLru].
final commitDiffProvider = FutureProvider.autoDispose
    .family<String, (String, String)>((ref, key) {
      _commitDiffLru.touch(key, ref.keepAlive());
      final (repoPath, hash) = key;
      final future = ref.watch(gitServiceProvider).showCommit(repoPath, hash);
      future.then(
        (d) => _commitDiffLru.reportSize(key, d.length),
        onError: (_) {},
      );
      return future;
    });

/// A commit's patch scoped to a single file. Keyed by (repoPath, hash, path)
/// — used by the file-history view so selecting a commit fetches only the
/// file being inspected, not every file that commit touched. Kept alive
/// (bounded LRU) — see [KeepAliveLru].
final commitFileDiffProvider = FutureProvider.autoDispose
    .family<String, (String, String, String)>((ref, key) {
      _commitFileDiffLru.touch(key, ref.keepAlive());
      final (repoPath, hash, path) = key;
      final future = ref
          .watch(gitServiceProvider)
          .showCommit(repoPath, hash, path: path);
      future.then(
        (d) => _commitFileDiffLru.reportSize(key, d.length),
        onError: (_) {},
      );
      return future;
    });

/// The conflicted working-tree file (with merge markers). Keyed by
/// (repoPath, path). Kept alive (bounded LRU) — see [KeepAliveLru].
final conflictFileProvider = FutureProvider.autoDispose
    .family<String, (String, String)>((ref, key) {
      _conflictFileLru.touch(key, ref.keepAlive());
      final (repoPath, path) = key;
      // Conflict markers change as the user (or another session) edits the
      // file — follow the landed status so the pane never shows stale markers.
      _dependOnWorktreeState(ref, repoPath);
      final future = ref.watch(gitServiceProvider).conflictFile(repoPath, path);
      future.then(
        (d) => _conflictFileLru.reportSize(key, d.length),
        onError: (_) {},
      );
      return future;
    });

/// An untracked file's contents rendered as an all-additions diff, so new files
/// display their content (a plain `git diff` shows nothing for them). Keyed by
/// (repoPath, path). Kept alive (bounded LRU) — see [KeepAliveLru].
final untrackedDiffProvider = FutureProvider.autoDispose
    .family<String, (String, String)>((ref, key) {
      _untrackedDiffLru.touch(key, ref.keepAlive());
      final (repoPath, path) = key;
      // An untracked file's contents are pure worktree state — follow the
      // landed status so the rendered "diff" tracks on-disk edits.
      _dependOnWorktreeState(ref, repoPath);
      final future = ref.watch(gitServiceProvider).diffUntracked(repoPath, path);
      future.then(
        (d) => _untrackedDiffLru.reportSize(key, d.length),
        onError: (_) {},
      );
      return future;
    });

/// Open merge requests for the connected project.
final mergeRequestsProvider = FutureProvider.autoDispose
    .family<List<MergeRequest>, String>((ref, repoPath) {
      return ref.watch(glabServiceProvider).mergeRequests(repoPath);
    });

/// Recent CI/CD pipelines for the connected project.
final pipelinesProvider = FutureProvider.autoDispose
    .family<List<Pipeline>, String>((ref, repoPath) {
      return ref.watch(glabServiceProvider).pipelines(repoPath);
    });

/// Jobs of a pipeline. Keyed by (repoPath, pipelineId).
final jobsProvider = FutureProvider.autoDispose
    .family<List<Job>, (String, int)>((ref, key) {
      final (repoPath, pipelineId) = key;
      return ref.watch(glabServiceProvider).jobs(repoPath, pipelineId);
    });

/// Live CI job-trace log. Keyed by (repoPath, jobId); emits **incremental** log
/// chunks (the view accumulates them). Auto-disposed so the remote trace process
/// is killed when the view closes.
final jobTraceProvider = StreamProvider.autoDispose
    .family<String, (String, int)>((ref, key) {
      final (repoPath, jobId) = key;
      return ref.watch(glabServiceProvider).traceStream(repoPath, jobId);
    });

/// Project overview (issues, labels, milestones, releases) in one GraphQL hop.
final projectDashboardProvider = FutureProvider.autoDispose
    .family<ProjectDashboard, String>((ref, repoPath) {
      return ref.watch(glabServiceProvider).projectDashboard(repoPath);
    });

// ---- Forge detection + GitHub providers ------------------------------------

/// The forge (GitHub/GitLab) the repo's `origin` remote points at — decides
/// which forge panel/service the "Forge" and "Project" tabs drive. Detects by
/// hostname first; for an unrecognized self-hosted host (a custom-domain GitHub
/// Enterprise / GitLab instance) it falls back to whichever CLI reports being
/// authenticated to that host. Returns [Forge.none] when the repo has no
/// origin remote at all.
final forgeProvider = FutureProvider.autoDispose.family<Forge, String>((
  ref,
  repoPath,
) async {
  final executor = ref.watch(activeExecutorProvider);

  Future<Forge> detect() async {
    final remote = await executor.execute(
      repoPath: repoPath,
      gitArgs: ['git', 'remote', 'get-url', 'origin'],
      timeout: const Duration(seconds: 20),
      lane: ExecLane.read,
    );
    if (!remote.isSuccess) return Forge.none;
    final url = remote.stdout.trim();
    final byHost = forgeFromRemoteUrl(url);
    if (byHost != Forge.unknown) return byHost;

    // Unrecognized (self-hosted) host: ask the CLIs which hosts they're logged
    // in to. `gh auth status` / `glab auth status` print their configured hosts;
    // their exit codes are unreliable, so scan the combined stdout+stderr text.
    final host = forgeHostFromRemoteUrl(url);
    if (host == null) return Forge.unknown;
    try {
      final gh = await executor.execute(
        repoPath: repoPath,
        gitArgs: ['gh', 'auth', 'status'],
        timeout: const Duration(seconds: 20),
        lane: ExecLane.read,
      );
      if ('${gh.stdout}\n${gh.stderr}'.contains(host)) return Forge.github;
      final glab = await executor.execute(
        repoPath: repoPath,
        gitArgs: ['glab', 'auth', 'status'],
        timeout: const Duration(seconds: 20),
        lane: ExecLane.read,
      );
      if ('${glab.stdout}\n${glab.stderr}'.contains(host)) return Forge.gitlab;
    } catch (_) {
      // A missing CLI / timeout during the probe just leaves it unclassified.
    }
    return Forge.unknown;
  }

  final forge = await detect();
  // A repo's forge can't change within a session, and re-probing it costs up
  // to three round trips (two of them CLI spawns) every time the Forge tab
  // remounts — pin a *conclusive* answer for the session. Inconclusive results
  // (`unknown`: probe raced a slow CLI; `none`: possibly a transient failure
  // to read the remote) stay autoDispose so they re-probe on next mount.
  // _invalidateRepoState still clears this on every connect/repo switch.
  if (forge == Forge.github || forge == Forge.gitlab) {
    ref.keepAlive();
  }
  return forge;
});

/// Open pull requests for the connected GitHub repo.
final pullRequestsProvider = FutureProvider.autoDispose
    .family<List<PullRequest>, String>((ref, repoPath) {
      return ref.watch(ghServiceProvider).pullRequests(repoPath);
    });

/// Recent GitHub Actions workflow runs for the connected repo.
final workflowRunsProvider = FutureProvider.autoDispose
    .family<List<WorkflowRun>, String>((ref, repoPath) {
      return ref.watch(ghServiceProvider).workflowRuns(repoPath);
    });

/// Live jobs of a workflow run, keyed by (repoPath, runId). Polls until the run
/// completes (GitHub exposes no live log stream); auto-disposed so the poll
/// stops when the view closes.
final runJobsProvider = StreamProvider.autoDispose
    .family<List<GhJob>, (String, int)>((ref, key) {
      final (repoPath, runId) = key;
      return ref.watch(ghServiceProvider).runJobsStream(repoPath, runId);
    });

/// A completed job's log, keyed by (repoPath, jobId). GitHub only serves logs
/// once a job finishes; an in-progress job surfaces as an error the view shows
/// as a "logs available when the job completes" placeholder.
final runJobLogProvider = FutureProvider.autoDispose
    .family<String, (String, int)>((ref, key) {
      final (repoPath, jobId) = key;
      return ref.watch(ghServiceProvider).runJobLog(repoPath, jobId);
    });

/// GitHub repository overview (issues, labels, milestones, releases) in one
/// GraphQL hop.
final githubProjectDashboardProvider = FutureProvider.autoDispose
    .family<GhProjectDashboard, String>((ref, repoPath) {
      return ref.watch(ghServiceProvider).projectDashboard(repoPath);
    });
