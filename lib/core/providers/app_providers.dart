import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// For ProviderOrFamily — the type of [repoScopedFetchFamilies]' entries;
// flutter_riverpod's main export list doesn't include it.
import 'package:riverpod/misc.dart' show ProviderOrFamily;
import 'package:shared_preferences/shared_preferences.dart';
import '../exec/command_telemetry.dart';
import '../exec/local_command_executor.dart';
import '../forge/auth_probe_service.dart';
import '../forge/auth_status.dart';
import '../forge/forge.dart';
import '../forge/forge_repo_summary.dart';
import '../git/git_service.dart';
import '../git/host_fs_service.dart';
import '../git/ignore_oracle.dart';
import '../git/local_watch_service.dart';
import '../git/log_search.dart';
import '../git/remote_watch_service.dart';
import '../git/repo_tree.dart';
import '../git/watch_event.dart';
import '../github/gh_service.dart';
import '../github/models.dart';
import '../gitlab/glab_service.dart';
import '../gitlab/models.dart';
import '../local/scoped_access.dart';
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
import '../undo/undo_journal.dart';
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

/// Ensures the shared [LocalCommandExecutor] has its augmented PATH and
/// binary rewrites before This-Mac work that runs *outside* any local
/// session — the landing create/clone sheets and the This-Mac forge browse.
/// A GUI-launched app's inherited PATH usually lacks Homebrew's bin dir, so
/// a bare `gh`/`glab` exits 127 there even though the tool is installed;
/// a local *connect* avoids this via [ConnectionController]'s own probe,
/// but these flows run before any connect exists.
final localEnvironmentProvider = Provider<LocalEnvironmentGuard>(
  LocalEnvironmentGuard.new,
);

/// See [localEnvironmentProvider]. [ensure] is a no-op when the executor is
/// already configured (a connect's probe or a previous call), re-probes
/// after a [LocalCommandExecutor.resetEnvironment], and coalesces concurrent
/// callers onto one in-flight probe. Best-effort like the connect-path
/// probe: on failure, commands fall back to the inherited PATH.
class LocalEnvironmentGuard {
  LocalEnvironmentGuard(this._ref);
  final Ref _ref;
  Future<void>? _inFlight;

  Future<void> ensure() {
    final executor = _ref.read(localExecutorProvider);
    if (executor.isConfigured) return Future<void>.value();
    return _inFlight ??= _probe(
      executor,
    ).whenComplete(() => _inFlight = null);
  }

  Future<void> _probe(LocalCommandExecutor executor) async {
    final overrides = _ref.read(appSettingsProvider).binaryOverrides;
    try {
      final env = await EnvironmentResolver(
        executor,
      ).resolve('/', overrides: overrides);
      executor.configureEnvironment(path: env.path, binaries: env.found);
    } catch (_) {
      // Best-effort: leave bare-name invocation on the inherited PATH.
    }
  }
}

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
    // Every successful undoable mutation lands in the journal, which is what
    // ⌘Z (UndoController) pops. `read` deliberately: the journal is a sink,
    // not a dependency — its state changing must not rebuild GitService.
    onUndoRecord: (record) =>
        ref.read(undoJournalProvider.notifier).push(record),
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

/// Plain host filesystem primitives (home dir, directory listing, path
/// probing, mkdir, the guarded clone-cleanup delete) — used by the clone/
/// create flows and the remote directory browser. Same executor seam as the
/// services above.
final hostFsServiceProvider = Provider<HostFsService>((ref) {
  return HostFsService(ref.watch(activeExecutorProvider));
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

  /// When the current session reached [ConnectionPhase.connected] — null
  /// while not connected. Drives the dashboard's session-uptime readout.
  final DateTime? connectedAt;

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
    this.connectedAt,
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
    DateTime? connectedAt,
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
      connectedAt: connectedAt ?? this.connectedAt,
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

  /// Per-session memo of forge CLI logins keyed by (forge, host), so browsing
  /// a forge's repos authenticates its host at most once. Deliberately *not*
  /// cleared by [_invalidateRepoState] (a repo switch keeps the same host
  /// auth) — only by the lifecycle methods that change the connection identity
  /// ([connect], [connectLocal], [beginProvisioning], [disconnect]). A failed
  /// login evicts its own entry so the next browse/reload retries. See
  /// [ensureForgeHostLogin].
  final Map<(Forge, String), Future<void>> _hostLogins = {};

  /// Gate for the current session's connect-time forge CLI logins, which run
  /// in the background *after* the session is already `connected` (each login
  /// validates its token against the forge's API from the host — the slowest
  /// connect stage back when it blocked the critical path). Starts completed:
  /// before any connect — and for sessions that supply no tokens (local
  /// sessions, provisioning, tokenless SSH) — there is nothing to wait for.
  Completer<void> _forgeAuthGate = Completer<void>()..complete();

  /// Completes when the current connection's background forge logins have
  /// settled (success *or* failure — this never throws). Forge data providers
  /// await it before their first gh/glab call, so a panel already visible at
  /// connect shows its ordinary loading state while the login lands instead
  /// of flashing a transient authentication error.
  Future<void> get forgeAuthSettled => _forgeAuthGate.future;

  /// Resolved by [acceptHostKeyChange]/[rejectHostKeyChange] — the only way
  /// [_verifyHostKey] ever returns while a mismatch prompt is showing. Null
  /// whenever no prompt is currently awaiting a decision.
  /// Security-scoped grants this local session holds *in addition to* its own
  /// repo folder (which is released by path at each teardown site below).
  ///
  /// Today that means exactly one thing: a linked worktree also needs its **main
  /// repository** granted, because git reads the shared objects/refs and this
  /// worktree's own HEAD/index out of `<main>/.git`. Both grants must be held
  /// for the whole session — a spawned `git` child only inherits them while
  /// they're open — and both must be released together.
  ///
  /// The UI acquires them (it owns the folder picker and the saved bookmarks;
  /// see `resolveSavedLocalRepoPath`) and hands the paths to [connectLocal];
  /// this controller owns the session lifetime, so it does the releasing. That
  /// is the same split already used for the primary grant. Keeping the extras in
  /// one list is what stops the four teardown paths from each having to remember
  /// a new grant — and leaking it when they don't.
  final List<String> _auxGrants = [];

  /// Releases every *additional* grant held by the current local session.
  /// Idempotent: [ScopedAccess.release] refcounts and no-ops on an untracked
  /// path, so calling this on a session that had none costs nothing.
  Future<void> _releaseAuxGrants() async {
    if (_auxGrants.isEmpty) return;
    final held = List<String>.from(_auxGrants);
    _auxGrants.clear();
    for (final path in held) {
      await ScopedAccess.instance.release(path);
    }
  }

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
    for (final family in repoScopedFetchFamilies) {
      ref.invalidate(family);
    }
    // The live subscriptions — restart on reset (never on ⌘R, which is why
    // they aren't in the shared registry).
    ref.invalidate(repoWatchProvider);
    ref.invalidate(jobTraceProvider);
    // These 7 keep their entries alive across a bounded LRU (see
    // _KeepAliveLru) rather than plain autoDispose — release every held link
    // alongside the invalidations above so a stale connection's entries don't
    // linger in the LRUs' own bookkeeping.
    clearHashKeyedRepoCaches();
    // Keyed purely by repoPath with no connection identity — without this, a
    // mutation marked just before disconnecting could suppress a genuinely
    // external change reported by a *different* connection that happens to
    // reuse the same repoPath (e.g. two hosts both mounting a repo at the
    // same conventional path). The status memo maps share that keying (and
    // would otherwise grow by one retained GitStatus per repo path, forever).
    ref.read(ownMutationTrackerProvider).clear();
    _lastLandedStatus.clear();
    // Same pure-repoPath keying, same reasoning: a stamp or an ignore verdict
    // from the previous connection must not answer for the next one, and a
    // reconnect is exactly when a repo's ignore rules may have changed under us.
    ref.read(worktreeEditsProvider.notifier).state = const WorktreeEditStamps();
    ref.read(ignoreOracleProvider).clear();
    // Undo records share that pure-repoPath keying — and undoing an operation
    // from a previous connection into a colliding path would be worse than a
    // suppressed refresh.
    ref.read(undoJournalProvider.notifier).clear();
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
  /// edits path overrides in Settings). No-op when disconnected. Unlike the
  /// connect path, versions are refreshed inline: this is user-triggered from
  /// the Settings health panel, which displays them.
  Future<void> reprobeBinaries() async {
    final repoPath = state.repoPath;
    if (!state.isConnected || repoPath == null) return;
    await _resolveEnvironment(repoPath);
    await _refreshToolVersions(_attempt, repoPath);
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
      // A fetch moves the remote-tracking refs and can bring commits down with
      // them, so it is a change to the repo like any other — the shared set,
      // not a hand-picked pair (see [repoMutationFamilies]).
      for (final p in repoMutationFamilies(repoPath)) {
        ref.invalidate(p);
      }
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
      await ScopedAccess.instance.release(state.repoPath!);
      await _releaseAuxGrants();
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
    _hostLogins.clear(); // new connection identity — re-auth forge hosts lazily
    // A new gate for this attempt's background logins. Captured locally so
    // this attempt only ever completes its *own* gate, never a successor's.
    final forgeGate = _forgeAuthGate = Completer<void>();
    // Set once _finishConnectInBackground has been launched — from then on,
    // completing the gate is the background task's job, not the finally's.
    var backgroundLaunched = false;
    _invalidateRepoState();
    // A fresh connection to a different host/repo shouldn't keep showing the
    // previous session's command output — but an auto-reconnect attempt to
    // the *same* connection should, since that history (including why it
    // dropped) is still relevant.
    if (!reconnecting) {
      ref.read(outputLogProvider.notifier).clear();
    }
    // Session-scoped dashboard metrics start over with the session.
    CommandTelemetry.instance.reset();
    ref.read(pingSamplesProvider.notifier).clear();
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
    // Per-stage wall-clock, logged at connected so "why is connecting slow"
    // is answerable from inside the app (Output view) instead of by guesswork:
    // the SSH handshake, the environment probe (which spawns the login shell
    // remotely), and the repo check have very different failure/latency modes.
    final timings = Stopwatch()..start();
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
            // Feed keepalive RTTs to the dashboard's latency sparkline —
            // guarded so a retired session's monitor can't pollute a newer
            // session's chart.
            onPingSample: (rtt) {
              if (attempt != _attempt || !ref.mounted) return;
              ref.read(pingSamplesProvider.notifier).add(rtt);
            },
          );
      // Superseded by a newer connect or a disconnect while we were resolving —
      // don't overwrite the current state (the SSH manager has already torn its
      // superseded client down).
      if (attempt != _attempt || !ref.mounted) return;
      final sshMs = timings.elapsedMilliseconds;

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
      final envMs = timings.elapsedMilliseconds;

      await ref.read(gitServiceProvider).validateRepoPath(repoPath);
      if (attempt != _attempt || !ref.mounted) return;

      // The session is usable NOW: publish `connected` and let the UI switch.
      // Everything else a session wants — fsmonitor tuning, forge CLI logins,
      // tool version probing — is deliberately background work (see
      // _finishConnectInBackground): each is best-effort, none is needed for
      // git reads, and the logins in particular validate their tokens against
      // the forge's API from the host, historically the slowest connect stage.
      final repos = SavedConnection.dedupePaths([repoPath, ...?repoPaths]);
      state = ConnectionState(
        phase: ConnectionPhase.connected,
        repoPath: repoPath,
        repoPaths: repos,
        connectionId: connectionId,
        connectionLabel: connectionLabel ?? profile.host,
        host: profile.host,
        connectedAt: DateTime.now(),
      );
      ref
          .read(outputLogProvider.notifier)
          .logInfo(
            'connected to ${profile.host} in '
            '${_fmtMs(timings.elapsedMilliseconds)} '
            '(ssh ${_fmtMs(sshMs)} · environment ${_fmtMs(envMs - sshMs)} · '
            'repo check ${_fmtMs(timings.elapsedMilliseconds - envMs)})',
          );
      backgroundLaunched = true;
      unawaited(
        _finishConnectInBackground(
          attempt: attempt,
          gate: forgeGate,
          repoPath: repoPath,
          fsmonitorPaths: fsmonitorPaths,
          gitlabToken: gitlabToken,
          githubToken: githubToken,
        ),
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
    } finally {
      // Any path that never launched the background finish (failure, host-key
      // decline, supersession's early returns) must still release whoever is
      // awaiting this attempt's forge gate — otherwise a provider created just
      // before the failure would hang on it instead of being torn down.
      if (!backgroundLaunched && !forgeGate.isCompleted) forgeGate.complete();
    }
  }

  /// Post-`connected` session finish: fsmonitor tuning for opted-in repos,
  /// forge CLI token logins, and the external-tool version probe (Settings
  /// health panel). None of this is needed before the first git read, so none
  /// of it belongs on the connect critical path — the logins especially, since
  /// `gh`/`glab auth login` each validate their token against the forge's API
  /// *from the host* (seconds of third-party network latency, previously paid
  /// at every connect before the UI would switch). Every step is
  /// attempt-guarded and non-fatal; login failures surface as a state warning
  /// exactly as they did when they blocked the connect. Completes [gate] when
  /// the login step settles — see [forgeAuthSettled].
  Future<void> _finishConnectInBackground({
    required int attempt,
    required Completer<void> gate,
    required String repoPath,
    List<String> fsmonitorPaths = const [],
    String? gitlabToken,
    String? githubToken,
  }) async {
    try {
      await Future.wait([
        if (fsmonitorPaths.isNotEmpty)
          _applyFsmonitorTuning(attempt, fsmonitorPaths),
        _refreshToolVersions(attempt, repoPath),
        _connectForgeLogins(
          attempt: attempt,
          gate: gate,
          repoPath: repoPath,
          gitlabToken: gitlabToken,
          githubToken: githubToken,
        ),
      ]);
    } finally {
      // _connectForgeLogins already completed it; this is the backstop.
      if (!gate.isCompleted) gate.complete();
    }
  }

  /// Applies per-repo fsmonitor tuning for every opted-in repo in ONE round
  /// trip (each used to be its own SSH round trip before the session became
  /// usable). Best-effort and per-repo non-fatal — status works fine without
  /// it; a failed repo is reported on stderr by the combined script and logged
  /// here, so a persistently-rejected tuning command stays discoverable
  /// instead of silently degrading refresh performance all session.
  Future<void> _applyFsmonitorTuning(int attempt, List<String> paths) async {
    try {
      final result = await ref
          .read(gitServiceProvider)
          .setFsmonitorMany(paths, enabled: true);
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

  /// Version-checks the session's resolved tools in one background round trip
  /// and merges the results into [binaryEnvironmentProvider] for the Settings
  /// health panel. Best-effort: on failure the panel simply shows no version
  /// numbers. Kept off the connect path because spawning `gh`/`glab` for a
  /// banner is exactly the kind of hidden network wait (update checks) that
  /// made connecting slow.
  Future<void> _refreshToolVersions(int attempt, String repoPath) async {
    try {
      final executor = _activeExecutor;
      final found = ref.read(binaryEnvironmentProvider).found;
      final versions = await EnvironmentResolver(
        executor,
      ).probeVersions(found, repoPath: repoPath);
      if (attempt != _attempt || !ref.mounted || versions.isEmpty) return;
      // Re-read: a settings-triggered reprobe may have republished the
      // environment while the version probe was in flight.
      ref
          .read(binaryEnvironmentProvider.notifier)
          .set(ref.read(binaryEnvironmentProvider).withVersions(versions));
    } catch (_) {
      // Best-effort by design.
    }
  }

  /// Connect-time forge CLI logins, run in the background once the session is
  /// already `connected`. Both logins are independent one-shot writes to
  /// different CLIs' credential stores; each maps its own failure to a
  /// non-fatal warning appended to the connected state (never a failed
  /// connect). Completes [gate] when both settle so gated forge providers can
  /// start fetching against an authenticated CLI.
  Future<void> _connectForgeLogins({
    required int attempt,
    required Completer<void> gate,
    required String repoPath,
    String? gitlabToken,
    String? githubToken,
  }) async {
    try {
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
      if (warnings.isNotEmpty && state.isConnected) {
        final joined = warnings.join('\n');
        state = state.copyWith(warning: joined);
        ref.read(outputLogProvider.notifier).logError('forge login', joined);
      }
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  }

  /// `1234` → `1.2s`, `87` → `87ms` — for the connect timing log line.
  static String _fmtMs(int ms) =>
      ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)}s' : '${ms}ms';

  /// Opens a repo on this machine's own filesystem — no SSH client, no host
  /// key, no environment probe of a *remote* host (though [_resolveEnvironment]
  /// still runs, since a Finder-launched GUI app's own PATH can be just as
  /// bare as an SSH exec channel's), and no drop-watching/auto-reconnect
  /// (there is no transport to drop). Reuses the same [ConnectionState]/
  /// [ConnectionPhase] machinery as [connect] so `app_shell.dart`'s routing —
  /// and every repo-scoped provider — needs zero changes to serve a local
  /// session.
  /// Opens a repo on this machine's filesystem.
  ///
  /// [mainRepoPath] is set only when [repoPath] is a **linked worktree**: it is
  /// the main repository's folder, for which the caller must ALREADY hold a
  /// security-scoped grant (see `resolveSavedLocalRepoPath` /
  /// `grantMainRepoAccess` — the UI owns the picker and the saved bookmarks, so
  /// it does the acquiring). Git cannot run in a linked worktree without it: a
  /// bare `git status` there reads this worktree's HEAD and index out of
  /// `<main>/.git/worktrees/<id>`, and every object and ref out of
  /// `<main>/.git`. Passing it here transfers ownership — this controller
  /// releases it when the session ends.
  Future<void> connectLocal(
    String repoPath, {
    String? label,
    String? id,
    String? mainRepoPath,
  }) async {
    final attempt = ++_attempt;
    // Session-scoped dashboard metrics start over with the session.
    CommandTelemetry.instance.reset();
    ref.read(pingSamplesProvider.notifier).clear();
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
    _hostLogins.clear(); // new connection identity — re-auth forge hosts lazily
    // No tokens → no background logins to wait for: gate opens immediately,
    // and forge panels rely on this machine's own gh/glab auth.
    _forgeAuthGate = Completer<void>()..complete();
    // Release the *previous* session's transport before starting the new one —
    // the switcher lets the user jump straight here with no explicit disconnect.
    //
    // The prior session's EXTRA grants go unconditionally, even when the primary
    // is kept below (same repoPath): the incoming caller has already acquired
    // whatever this session needs, so the refcount never dips to zero and no
    // command loses its grant mid-flight. Not releasing them would leak one
    // hold per reconnect.
    await _releaseAuxGrants();
    if (state.isLocal) {
      // local → local: release the prior repo's security-scoped access. Safe/
      // no-op if that session was never bookmark-backed.
      if (state.repoPath != null && state.repoPath != repoPath) {
        await ScopedAccess.instance.release(state.repoPath!);
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
    // Take ownership of the main repo's grant BEFORE any git runs. It has to be
    // held for the whole session, not per-command: a spawned `git` child only
    // inherits the sandbox grant while it is open.
    if (mainRepoPath != null && mainRepoPath.isNotEmpty) {
      _auxGrants.add(mainRepoPath);
    }
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

      // Local-only: the sandbox grant covers only the folders we were given, so
      // reject a picked subdirectory / submodule / separate-git-dir repo whose
      // real git dir is unreachable — with a clear message, rather than a raw
      // permission error on the first real read.
      //
      // A linked worktree is NOT rejected: it is returned classified, and by
      // this point we are already holding its main repository's grant (see
      // [mainRepoPath] above), which is what makes the git calls here succeed
      // at all.
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
        connectedAt: DateTime.now(),
      );
      // Tool versions for the Settings health panel — same background pass as
      // the SSH path, and for the same reason: spawning gh/glab `--version`
      // (with their potential update-check stalls) must not block the open.
      unawaited(_refreshToolVersions(attempt, repoPath));
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

  /// Ensures the active backend's forge CLI is authenticated to [host] for
  /// [forge], using this connection's stored token — the repo-less login the
  /// clone sheet needs before it can list "your repositories" on a host that
  /// no open repo's origin points at. Memoized per (forge, host) for the
  /// session (see [_hostLogins]); a no-op when this connection supplied no
  /// token for the forge (the host's own CLI auth is then relied on). A failed
  /// login evicts its memo so a reload retries rather than replaying failure.
  Future<void> ensureForgeHostLogin(Forge forge, String host) {
    final key = (forge, host);
    final existing = _hostLogins[key];
    if (existing != null) return existing;

    final token = switch (forge) {
      Forge.github => _lastGithubToken,
      Forge.gitlab => _lastGitlabToken,
      _ => null,
    };
    if (token == null || token.isEmpty) {
      // No managed token — rely on whatever auth the host's gh/glab already
      // has. Memoize the decision so a browse doesn't re-derive it each time.
      return _hostLogins[key] = Future<void>.value();
    }

    // Construct the service from [_activeExecutor] directly rather than via
    // ghServiceProvider/glabServiceProvider: those watch activeExecutorProvider
    // → connectionProvider, and reading them from within this notifier trips
    // Riverpod's circular-dependency guard. Same reason [_activeExecutor]
    // exists (see its doc).
    final login = switch (forge) {
      Forge.github => GhService(
        _activeExecutor,
      ).loginWithTokenHost(host: host, token: token),
      Forge.gitlab => GlabService(
        _activeExecutor,
      ).loginWithTokenHost(host: host, token: token),
      _ => Future<void>.value(),
    };
    final guarded = login.catchError((Object e) {
      _hostLogins.remove(key); // a failed login is retryable
      throw e;
    });
    return _hostLogins[key] = guarded;
  }

  /// Opens a transport-only ("provisioning") SSH session to [conn]'s host with
  /// **no repository**: it establishes the client and probes the environment
  /// (so `git`/`gh`/`glab` resolve), but skips repo validation, fsmonitor, the
  /// repo-scoped forge logins, and the `connected` state. The phase stays
  /// [ConnectionPhase.connecting], so `app_shell` keeps routing to the landing
  /// while the clone/create sheet drives the actual work on top.
  ///
  /// Returns this attempt's token — pass it to [finalizeProvisioned] (on
  /// success) or [abortProvisioning] (on cancel/close). Returns null when the
  /// attempt was superseded or failed (a failure lands `phase: error` exactly
  /// like [connect]).
  Future<int?> beginProvisioning(SavedConnection conn) async {
    final store = ref.read(connectionStoreProvider);
    String? secret, token, ghToken, key, passphrase;
    try {
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
      // Secrets unavailable — the connection may still succeed via other auth.
    }
    String? notEmpty(String? v) => (v != null && v.isNotEmpty) ? v : null;
    final profile = SSHConnectionProfile(
      host: conn.host,
      port: conn.port,
      username: conn.username,
      password: notEmpty(secret),
      privateKey: notEmpty(key),
      passphrase: notEmpty(passphrase),
    );

    final attempt = ++_attempt;
    if (!(_hostKeyDecision?.isCompleted ?? true)) {
      _hostKeyDecision!.complete(false);
    }
    _hostKeyDecision = null;
    if (state.isLocal && state.repoPath != null) {
      await ScopedAccess.instance.release(state.repoPath!);
      await _releaseAuxGrants();
    }

    _lastProfile = profile;
    // Null repo: a half-provisioned session is not reconnectable until
    // [finalizeProvisioned] gives it a real repo path.
    _lastRepoPath = null;
    // Retain the tokens so _forgeTokenVarsToNeutralize() and
    // ensureForgeHostLogin work during the browse, and finalize can log in.
    _lastGitlabToken = token;
    _lastGithubToken = ghToken;
    _lastConnectionId = conn.id;
    _lastConnectionLabel = conn.displayName;
    _lastRepoPaths = conn.allRepoPaths;
    _lastFsmonitorPaths = conn.fsmonitorPaths;
    _hostLogins.clear();
    // Provisioning logs its forge hosts in lazily during the browse
    // (ensureForgeHostLogin) and repo-scoped at finalize — both awaited
    // inline before `connected`, so there is never a background login to
    // gate on for this session.
    _forgeAuthGate = Completer<void>()..complete();

    _invalidateRepoState();
    ref.read(outputLogProvider.notifier).clear();
    ref.read(executorProvider).resetEnvironment();
    ref.read(binaryEnvironmentProvider.notifier).clear();
    // Same contract as [connect]/[connectLocal]: session metrics always
    // describe the current session, so a wizard-provisioned connection must
    // not inherit the previous host's command counts or latency samples.
    CommandTelemetry.instance.reset();
    ref.read(pingSamplesProvider.notifier).clear();

    state = ConnectionState(
      phase: ConnectionPhase.connecting,
      repoPath: null,
      connectionId: conn.id,
      connectionLabel: conn.displayName,
      host: conn.host,
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
            // Feed keepalive RTTs to the dashboard's latency sparkline —
            // guarded so a retired session's monitor can't pollute a newer
            // session's chart.
            onPingSample: (rtt) {
              if (attempt != _attempt || !ref.mounted) return;
              ref.read(pingSamplesProvider.notifier).add(rtt);
            },
          );
      if (attempt != _attempt || !ref.mounted) return null;

      // Probe from the login home dir (`cd '.'`) — no repo to validate yet.
      await _resolveEnvironment('.', attempt: attempt);
      if (attempt != _attempt || !ref.mounted) return null;

      return attempt;
    } catch (e) {
      if (attempt != _attempt || !ref.mounted) return null;
      if (_hostKeyCancelledAttempt == attempt) {
        state = const ConnectionState();
        return null;
      }
      state = ConnectionState(
        phase: ConnectionPhase.error,
        error: e.toString(),
        connectionId: conn.id,
        connectionLabel: conn.displayName,
        host: conn.host,
      );
      return null;
    }
  }

  /// Promotes a provisioning session (see [beginProvisioning]) into a normal
  /// connected session on [repoPath] — the just-cloned/created repo. Validates
  /// the repo, optionally tunes fsmonitor, runs the repo-scoped forge logins,
  /// persists [repoPath] into the saved connection's repo list, and lands the
  /// `connected` state watching for drops.
  ///
  /// Returns false when the session was superseded (a concurrent disconnect /
  /// new connect) — the caller should just close. Rethrows a validation
  /// failure so the sheet can show it and offer Close (→ [abortProvisioning]).
  /// Deliberately does NOT clear the output log, so the clone transcript
  /// remains as this session's history.
  Future<bool> finalizeProvisioned({
    required int token,
    required SavedConnection conn,
    required String repoPath,
    bool enableFsmonitor = false,
  }) async {
    if (token != _attempt || !ref.mounted) return false;

    await ref.read(gitServiceProvider).validateRepoPath(repoPath);
    if (token != _attempt || !ref.mounted) return false;

    if (enableFsmonitor) {
      try {
        await ref.read(gitServiceProvider).setFsmonitor(repoPath, enabled: true);
      } catch (e) {
        if (token != _attempt || !ref.mounted) return false;
        ref
            .read(outputLogProvider.notifier)
            .logError('fsmonitor setup ($repoPath)', e.toString());
      }
      if (token != _attempt || !ref.mounted) return false;
    }

    // Repo-scoped forge logins against the new repo's origin — idempotent with
    // any host login already done while browsing, and the path that
    // authenticates a private clone-by-URL whose host was never typed into a
    // browse field. Best-effort → non-fatal warnings, exactly like connect().
    String? warning;
    // Services built from [_activeExecutor] directly — see ensureForgeHostLogin
    // for why not the providers.
    final loginWarnings = await Future.wait([
      if ((_lastGitlabToken ?? '').isNotEmpty)
        GlabService(_activeExecutor)
            .loginWithToken(repoPath, _lastGitlabToken!)
            .then<String?>(
              (_) => null,
              onError: (Object e) =>
                  'GitLab token login failed — GitLab panels may not work '
                  'until the remote is authenticated. ($e)',
            ),
      if ((_lastGithubToken ?? '').isNotEmpty)
        GhService(_activeExecutor)
            .loginWithToken(repoPath, _lastGithubToken!)
            .then<String?>(
              (_) => null,
              onError: (Object e) =>
                  'GitHub token login failed — GitHub panels may not work '
                  'until the remote is authenticated. ($e)',
            ),
    ]);
    if (token != _attempt || !ref.mounted) return false;
    final warnings = loginWarnings.whereType<String>().toList();
    if (warnings.isNotEmpty) warning = warnings.join('\n');

    // Persist the new repo into the saved connection.
    var updated = conn.copyWith(
      repoPaths: SavedConnection.dedupePaths([...conn.allRepoPaths, repoPath]),
    );
    if (enableFsmonitor) updated = updated.withFsmonitor(repoPath, true);
    try {
      await ref.read(connectionStoreProvider).updateMetadata(updated);
      if (token != _attempt || !ref.mounted) return false;
      ref.invalidate(savedConnectionsProvider);
      await ref.read(connectionStoreProvider).touch(conn.id);
    } catch (e) {
      warning = [
        ?warning,
        'The repository was opened but could not be saved to this '
            'connection. ($e)',
      ].join('\n');
    }
    if (token != _attempt || !ref.mounted) return false;

    // The session is reconnectable again now that it has a real repo.
    _lastRepoPath = repoPath;
    _lastRepoPaths = updated.allRepoPaths;
    _lastFsmonitorPaths = updated.fsmonitorPaths;

    _invalidateRepoState(); // NB: does not clear the output log
    state = ConnectionState(
      phase: ConnectionPhase.connected,
      repoPath: repoPath,
      repoPaths: updated.allRepoPaths,
      connectionId: conn.id,
      connectionLabel: conn.displayName,
      host: conn.host,
      warning: warning,
      connectedAt: DateTime.now(),
    );
    _watchForDrop(token);
    return true;
  }

  /// Tears down a provisioning session that was never finalized (the clone/
  /// create sheet closed or its job was cancelled). A no-op once superseded.
  Future<void> abortProvisioning(int token) async {
    if (token != _attempt) return;
    await disconnect();
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
        await ScopedAccess.instance.release(repoPath);
      }
      // …and, for a linked worktree, the main repository's grant too.
      await _releaseAuxGrants();
    } else {
      ref.read(executorProvider).resetEnvironment();
      await ref.read(sshClientManagerProvider).disconnect();
    }
    ref.read(binaryEnvironmentProvider.notifier).clear();
    _hostLogins.clear();
    // Release anyone still awaiting the departing session's background
    // logins — their providers are invalidated right below, but an awaiter
    // must never be left hanging on a gate no connect will ever complete.
    if (!_forgeAuthGate.isCompleted) _forgeAuthGate.complete();
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

/// Every repo-scoped one-shot-fetch provider family, in one place.
///
/// Two call sites iterate this registry instead of hand-maintaining their own
/// lists (which drifted in the past — ⌘R silently skipped the GitHub panels):
///
///  * [ConnectionController._invalidateRepoState] — connect / disconnect /
///    repo switch. Also restarts the live subscriptions and clears the LRUs,
///    which are reset-only concerns layered on top of this list.
///  * `AppShell._refresh` (⌘R) — manual refresh of the active repo. Also
///    invalidates the viewer's `fileContentProvider`/`fileBytesProvider`,
///    which live in the features layer and can't be listed here.
///
/// `ref.invalidate(family)` with no key invalidates every keyed instance of
/// the family at once, and invalidating an unmounted provider is a harmless
/// no-op — so both call sites can share one list. The live subscriptions
/// ([repoWatchProvider], [jobTraceProvider]) are deliberately NOT here: ⌘R
/// must not restart an already-current stream.
///
/// A new repo-scoped fetch family belongs in this list — that single addition
/// covers both ⌘R and connection resets.
final List<ProviderOrFamily> repoScopedFetchFamilies = [
  statusProvider,
  pendingOpProvider,
  logProvider,
  logSearchProvider,
  refsProvider,
  stashesProvider,
  stashDiffProvider,
  prepareCommitMsgHookProvider,
  repoStructureProvider,
  repoStatusOverlayProvider,
  fileLogProvider,
  blameProvider,
  fileDiffProvider,
  commitDiffProvider,
  commitFileDiffProvider,
  conflictFileProvider,
  untrackedDiffProvider,
  mergeRequestsProvider,
  pipelinesProvider,
  jobsProvider,
  projectDashboardProvider,
  forgeProvider,
  forgeRepoListProvider,
  pullRequestsProvider,
  workflowRunsProvider,
  runJobsProvider,
  runJobLogProvider,
  githubProjectDashboardProvider,
  reflogProvider,
  magicSnapshotsProvider,
  gitWorktreesProvider,
  repoLayoutProvider,
];

/// Clears the eight hash-keyed diff/blame/log LRUs — the LRU-clearing half of
/// [ConnectionController._invalidateRepoState], exposed for callers that
/// invalidate repo-scoped state WITHOUT going through the controller: the
/// secondary (History pop-out) window's `_applySession` on a repo retarget.
/// Without it, those callers leave the LRUs holding stale KeepAliveLinks to
/// just-disposed providers, and a subsequent FRESH fetch for a key can fail to
/// deliver its result to the watching pane (already-cached entries still render,
/// fresh ones stay stuck loading — the pop-out diff-on-switch bug).
///
/// Every LRU declared below must appear here: an omitted one recreates that same
/// stuck-loading bug for its pane on a repo switch (the commit-range compare pane
/// was such an omission — its LRU is in the immutable tier alongside the commit
/// and commit-file diffs, all three of which must be cleared together).
void clearHashKeyedRepoCaches() {
  _fileLogLru.clear();
  _blameLru.clear();
  _fileDiffLru.clear();
  _commitDiffLru.clear();
  _commitFileDiffLru.clear();
  _commitRangeDiffLru.clear();
  _blobLru.clear();
  _conflictFileLru.clear();
  _untrackedDiffLru.clear();
}

/// The repo-scoped fetch providers a single commit-mutating operation (commit,
/// cherry-pick, revert, reset, amend, undo…) can change for one [repoPath] —
/// the ONE list every post-mutation refresh path shares (the undo controller,
/// the History window bridge, the History window shell, the in-tab History
/// refresh). Keeping it here rather than hand-copying the six invalidations in
/// each site means a newly-added mutation-sensitive family is picked up
/// everywhere at once, with no chance of one isolate drifting stale.
///
/// Unlike [repoScopedFetchFamilies] (whole families, for ⌘R / connection
/// resets), these are the concrete per-[repoPath] provider instances, so only
/// the affected repo's entries are dropped. Invalidating an unwatched instance
/// is a harmless no-op — hence reflog/snapshots are always included so an open
/// Recovery sheet can never show a pre-mutation reflog.
/// A note on instances vs whole families here, which git's own layout dictates.
///
/// A repository's worktrees SHARE their objects, refs, stash and reflog (all of
/// it lives in the common git dir); only the working tree, the index and HEAD
/// are private to each. So a commit made in a linked worktree moves a branch
/// that the main repo's Branches panel is showing, and adds a commit that its
/// History is showing — under a DIFFERENT repoPath key, which the mutating site
/// has no way to enumerate (it knows only the worktree it ran in).
///
/// Hence the split below: **shared** state goes in as the whole FAMILY, so every
/// open worktree of the repo refetches it; **per-worktree** state goes in keyed
/// by [repoPath], because no other worktree's copy of it changed.
///
/// Passing a family invalidates all of its keyed instances. That is not a
/// scattergun: each tab owns its own root ProviderContainer, so the only
/// instances that exist in this one are this repo and its worktrees — exactly
/// the set that shares the state. For a repo with no worktrees open it is
/// identical to invalidating the single instance, so nothing changes there.
/// (This is the same reasoning that already puts [logSearchProvider] in as a
/// family — it is keyed by a whole [LogQuery] no mutation site can rebuild.)
List<ProviderOrFamily> repoMutationFamilies(String repoPath) => [
  // ---- per-worktree: the working tree and index are this checkout's alone ----
  statusProvider(repoPath),

  // ---- shared across every worktree of this repository ----
  logProvider,
  logSearchProvider,
  refsProvider,
  stashesProvider,
  reflogProvider,
  magicSnapshotsProvider,
  // The worktree list itself: `worktree add/remove/lock` from any worktree
  // rewrites `<common>/.git/worktrees/`, which every other worktree reads.
  gitWorktreesProvider,
];

/// Working-tree status for a repo path, keyed so multiple repos can coexist.
/// autoDispose so it's discarded when [RepoStatusView] unmounts on disconnect
/// (and explicitly invalidated on connect/disconnect) — a reconnect never
/// serves the previous session's branch/files. Refresh with
/// `ref.invalidate(statusProvider(repoPath))`.
/// Last landed status per repo, for [statusProvider]'s content-identity memo.
/// Cleared on connect/disconnect/repo-switch alongside the repo-scoped
/// providers (see [ConnectionController._invalidateRepoState]) so the app
/// doesn't retain one full [GitStatus] per repo path ever opened.
final _lastLandedStatus = <String, GitStatus>{};

/// A monotonic stamp per (repo, file), plus one per repo, marking on-disk
/// *content* edits — the changes porcelain status cannot describe.
///
/// Two files can have byte-identical status records and different bytes on
/// disk: re-editing an already-modified file changes nothing about `M  foo.c`.
/// So content edits need a channel of their own, and this is it.
///
/// It is deliberately **per path**. The signal it replaced was per repo, which
/// meant every filesystem event invalidated every cached diff, blame, conflict
/// and untracked preview for every file — an edit to one file re-fetched all of
/// them, and a build touching files git does not even track re-fetched all of
/// them several times a second. A stamp per path lets each cache watch only the
/// file it is actually about.
class WorktreeEditStamps {
  const WorktreeEditStamps({this.repos = const {}, this.files = const {}});

  /// repoPath → stamp. Bumped when the *scope* of a change is unknown (a
  /// polling tick, a watcher restart, a mutation this app performed): every
  /// path in the repo must then be treated as possibly edited.
  final Map<String, int> repos;

  /// 'repoPath path' → stamp.
  final Map<String, int> files;

  static String _key(String repoPath, String path) => '$repoPath $path';

  /// The pair a cache for [path] watches. A record, so Riverpod's `select`
  /// compares it by value: the listener fires only when *this* file's stamp (or
  /// its repo's) moves, not when some unrelated file is touched.
  (int, int) stampFor(String repoPath, String path) =>
      (repos[repoPath] ?? 0, files[_key(repoPath, path)] ?? 0);
}

/// Beyond this many remembered file stamps, the map is reset rather than grown
/// without bound. Dropping a stamp is safe by construction: it changes the
/// value a cache is watching, so the cache refetches once — costing a read, not
/// correctness. (Growing forever, in a session that touches every file in a
/// large repo, would cost memory that is never released.)
const int _maxFileStamps = 8192;

class WorktreeEditsNotifier extends Notifier<WorktreeEditStamps> {
  @override
  WorktreeEditStamps build() => const WorktreeEditStamps();

  /// A content edit to [paths] — an event-driven watcher tick that named them.
  void noteFiles(String repoPath, Iterable<String> paths) {
    if (paths.isEmpty) return;
    final files = Map<String, int>.from(
      state.files.length > _maxFileStamps ? const {} : state.files,
    );
    for (final path in paths) {
      final key = WorktreeEditStamps._key(repoPath, path);
      files[key] = (files[key] ?? 0) + 1;
    }
    state = WorktreeEditStamps(repos: state.repos, files: files);
  }

  /// A change whose scope is unknown — everything in [repoPath] may have been
  /// edited. A watcher that can't name what moved (polling, a restart, an
  /// overflowing burst), or a mutation this app made.
  void noteRepo(String repoPath) {
    state = WorktreeEditStamps(
      repos: {...state.repos, repoPath: (state.repos[repoPath] ?? 0) + 1},
      files: state.files,
    );
  }

  /// Drops [repoPath]'s stamps — connect/disconnect/repo-switch, alongside the
  /// repo-scoped provider invalidations.
  void forgetRepo(String repoPath) {
    state = WorktreeEditStamps(
      repos: {...state.repos}..remove(repoPath),
      files: {...state.files}
        ..removeWhere((k, _) => k.startsWith('$repoPath ')),
    );
  }
}

final worktreeEditsProvider =
    NotifierProvider<WorktreeEditsNotifier, WorktreeEditStamps>(
      WorktreeEditsNotifier.new,
    );

/// Decides which watched paths git actually cares about — see [GitIgnoreOracle].
/// Held at the container root (not auto-disposed) because its whole value is the
/// memory it accumulates: the verdict on `build/` should outlive any one pane.
final ignoreOracleProvider = Provider<GitIgnoreOracle>(
  (ref) => GitIgnoreOracle(ref.watch(gitServiceProvider)),
);

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
  // Content-identity memo: a refresh that found *nothing changed* hands back
  // the previous instance, so every select/identical-based listener — the
  // worktree cache invalidation ([_dependOnWorktreeState]), the structure-tree
  // gate, diff prefetching — sees a no-op instead of a "new" status. Without
  // this, every watcher tick on an idle repo minted a fresh GitStatus and
  // re-fetched the world.
  //
  // This is now a *pure* record comparison. It used to be deliberately poisoned
  // by a per-repo "edit generation", bumped on every filesystem event, so that
  // a content-only edit (which leaves porcelain records identical) could not be
  // memoized away. That worked, but it made a status refresh the carrier for
  // two unrelated facts, and the cost fell on everything downstream: any event
  // anywhere — including one in a directory git ignores — landed as a brand-new
  // status and invalidated every cached diff in the repo. Content edits now
  // travel on their own per-path channel ([worktreeEditsProvider]), which says
  // exactly which file changed, so this can go back to meaning only what it
  // says: the records are the same, nothing here moved.
  final previous = _lastLandedStatus[repoPath];
  if (previous != null && previous.contentEquals(status)) {
    return previous;
  }
  _lastLandedStatus[repoPath] = status;
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
      // Same reasoning as the post-commit fetch: new remote refs, and possibly
      // new commits behind them, are a change to the repo (see
      // [repoMutationFamilies]).
      for (final p in repoMutationFamilies(repoPath)) {
        ref.invalidate(p);
      }
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

/// Whether the Dashboard sheet is open. Driven from three directions — the
/// native "View → Dashboard View" menu checkbox, the sheet's own X button,
/// and Esc — all routed through this one notifier so the checkmark and the
/// sheet can never disagree.
class DashboardVisibility extends Notifier<bool> {
  @override
  bool build() => false;

  void setVisible(bool value) {
    if (state != value) state = value;
  }

  void toggle() => state = !state;
}

final dashboardVisibleProvider = NotifierProvider<DashboardVisibility, bool>(
  DashboardVisibility.new,
);

/// The Recovery sheet's visibility — same provider-driven modal-route pattern
/// as [dashboardVisibleProvider] (View-menu checkbox, palette entry, and the
/// sheet's own Esc/X all stay in sync through it).
class RecoveryVisibility extends Notifier<bool> {
  @override
  bool build() => false;

  void setVisible(bool value) {
    if (state != value) state = value;
  }

  void toggle() => state = !state;
}

final recoveryVisibleProvider = NotifierProvider<RecoveryVisibility, bool>(
  RecoveryVisibility.new,
);

/// Keepalive round-trip times from the active SSH session (newest last,
/// bounded) — the dashboard's link-latency sparkline. The health monitor was
/// already pinging every 15 s; this just stops discarding the timings.
/// Cleared on every connect so the chart describes the current session.
class PingSamplesNotifier extends Notifier<List<Duration>> {
  static const int _cap = 40;

  @override
  List<Duration> build() => const [];

  void add(Duration rtt) {
    final next = [...state, rtt];
    if (next.length > _cap) next.removeRange(0, next.length - _cap);
    state = next;
  }

  void clear() => state = const [];
}

final pingSamplesProvider =
    NotifierProvider<PingSamplesNotifier, List<Duration>>(
      PingSamplesNotifier.new,
    );

/// The repo's object-store footprint (`git count-objects -vH`) — fetched on
/// demand by the dashboard's Measure action, cheap enough to re-run freely.
final repoFootprintProvider = FutureProvider.autoDispose
    .family<RepoFootprint, String>((ref, repoPath) {
      return ref.watch(gitServiceProvider).repoFootprint(repoPath);
    });

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
      final raw = switch (backend) {
        ConnectionBackend.local => ref
            .watch(localWatchServiceProvider)
            .watch(repoPath),
        ConnectionBackend.ssh => ref
            .watch(remoteWatchServiceProvider)
            .watch(repoPath),
      };
      final oracle = ref.watch(ignoreOracleProvider);
      return _withoutIgnoredPaths(oracle, repoPath, raw);
    });

/// Drops the paths git ignores from each tick — and the tick itself when
/// nothing survives.
///
/// This is where a build stops costing anything. `build/` and `.dart_tool/`
/// churn produces a filesystem event per artifact; unfiltered, each one lands as
/// a repo change, refreshes status, and invalidates every cached diff. None of
/// it is anything git will ever report. Filtered, the burst is recognized for
/// what it is and the tick never leaves this stream: no `git status`, no
/// invalidation, no round trip.
///
/// `asyncMap` (not a parallel map) so ticks stay strictly ordered — a tick that
/// resolved from cache must not overtake one still waiting on git, or an older
/// view of the repo would land last. Ticks are already coalesced, so the rate
/// here is at most a few per second, and the oracle answers nearly all of them
/// from memory.
Stream<RepoWatchEvent> _withoutIgnoredPaths(
  GitIgnoreOracle oracle,
  String repoPath,
  Stream<RepoWatchEvent> raw,
) async* {
  await for (final event in raw) {
    // Unknown scope (a poll, a watcher restart, an overflowing burst). There is
    // nothing to filter and nothing may be assumed — pass it through as the
    // "refresh everything" signal it is.
    if (!event.isScoped) {
      yield event;
      continue;
    }
    // An edited `.gitignore` changes the answers themselves, so every verdict
    // derived from the old one is void.
    if (event.paths.any(GitIgnoreOracle.isIgnoreSource)) {
      oracle.forgetRepo(repoPath);
    }
    Set<String> visible;
    try {
      visible = await oracle.visible(repoPath, event.paths);
    } catch (_) {
      // Fail open: a burst we could not classify is treated as a real change.
      // Refreshing when we needn't is a wasted read; the converse is a pane
      // that silently stops updating.
      yield event;
      continue;
    }
    if (visible.isEmpty) continue; // the whole burst was noise git can't see
    yield event.withPaths(visible);
  }
}

/// Branches + remote-tracking refs for a repo.
/// Every worktree of this repository, main worktree first.
///
/// Keyed by repoPath like every other repo-scoped fetch, but note the result is
/// a property of the *repository*, not of the particular worktree asked: any
/// worktree of a repo returns the same list. See [repoMutationFamilies] for why
/// that means it is invalidated as a whole family.
final gitWorktreesProvider = FutureProvider.autoDispose
    .family<List<GitWorktree>, String>((ref, repoPath) {
      return ref.watch(gitServiceProvider).gitWorktrees(repoPath);
    });

/// Where this repo's git data lives — and specifically whether [repoPath] is a
/// linked worktree, and if so where its main repository is.
///
/// Not in [repoMutationFamilies]: the layout of a checkout is fixed for as long
/// as it is open. Only `worktree move`/`repair` can change it, and both go
/// through a full refresh anyway.
final repoLayoutProvider = FutureProvider.autoDispose
    .family<RepoLayout, String>((ref, repoPath) {
      return ref.watch(gitServiceProvider).repoLayout(repoPath);
    });

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

/// HEAD's reflog — the Recovery sheet's entry list.
final reflogProvider = FutureProvider.autoDispose
    .family<List<ReflogEntry>, String>((ref, repoPath) {
      return ref.watch(gitServiceProvider).reflog(repoPath);
    });

/// The anchored pre-destroy snapshots (`refs/magic-git/snapshots/`) — the
/// Recovery sheet's second section.
final magicSnapshotsProvider = FutureProvider.autoDispose
    .family<List<SnapshotRef>, String>((ref, repoPath) {
      return ref.watch(gitServiceProvider).snapshotRefs(repoPath);
    });

/// How deep the History panel walks on first load, and how much further each
/// "Load more" goes.
const int kHistoryPageSize = 500;

/// A filtered/searched commit log. Keyed by a query record (structural equality
/// gives correct caching — so every field here must stay a value type; a `List`
/// would compare by identity and re-fetch on every rebuild). [all] walks every
/// ref; the rest narrow the walk. Every criterion is applied by git itself, so
/// results are complete up to the walked depth rather than "whatever was already
/// loaded" — including [sha], which is resolved against the object database and
/// so finds a commit on any branch, at any depth.
///
/// The paging depth is deliberately NOT a key field. It lives on
/// [LogSearchNotifier], so scrolling deeper extends the existing walk instead of
/// minting a new provider that re-walks from the top — see [LogSearchNotifier].
typedef LogQuery = ({
  String repoPath,
  String? grep,
  String? author,
  String? since,
  String? until,
  String? path,
  String? sha,
  bool noMerges,
  bool all,
});

/// The History panel's commit list, walked a page at a time.
///
/// Two paths write the list, and they are deliberately different:
///
///  * **[build] — a refresh.** First load, ⌘R, or the invalidation every
///    mutation fires. One `git log` produces the *whole* displayed prefix, so a
///    refresh can never leave a page-boundary duplicate or drop behind, and the
///    list is always a single consistent snapshot of one walk. The depth is a
///    field on the notifier, and Riverpod re-runs `build` on the *same* notifier
///    instance across an invalidation — so a commit made while scrolled 5,000
///    deep refreshes all 5,000 rows and does not collapse the list back to one
///    page. (`log_paging_test.dart` pins that; if a Riverpod upgrade ever
///    recreates the instance instead, that test fails rather than the behaviour
///    silently regressing to a snap-back.)
///
///  * **[loadMore] — scrolling off the end.** Fetches ONLY the next page, with
///    `--skip` past what is already held, and appends. Paging used to be
///    expressed as a bigger `--max-count` on a *new* provider key, which re-ran
///    the whole walk: page 20 re-formatted, re-transferred and re-parsed the
///    9,500 commits already on screen to show 500 more. That is quadratic in the
///    scroll depth, and on the SSH backend it re-sends every one of those
///    commits over the wire. The prefix it appends to is a settled value from a
///    single walk, so the only seam is between pages.
///
/// The seam is why the append dedupes by hash: `--skip=N` is an offset into a
/// walk that git re-runs, so a commit landing between two pages shifts the
/// window under us and the next page can repeat a row already held. Dropping the
/// repeat keeps the list well-formed; the row that shifted out of the window is
/// picked up by the refresh that any such commit triggers anyway.
final logSearchProvider = AsyncNotifierProvider.autoDispose
    .family<LogSearchNotifier, List<GitCommit>, LogQuery>(LogSearchNotifier.new);

class LogSearchNotifier extends AsyncNotifier<List<GitCommit>> {
  LogSearchNotifier(this.query);

  final LogQuery query;

  /// How deep the walk currently goes. Survives an invalidation with the
  /// notifier instance, so a refresh re-walks everything the user paged to.
  int _depth = kHistoryPageSize;

  /// The walk ran out: the last fetch returned fewer commits than it asked for,
  /// so there is nothing below and [loadMore] is a no-op.
  bool get exhausted => _exhausted;
  bool _exhausted = false;

  int get depth => _depth;

  Future<List<GitCommit>> _walk(
    GitService git, {
    required int skip,
    required int count,
  }) {
    return git.log(
      query.repoPath,
      maxCount: count,
      skip: skip,
      grep: query.grep,
      author: query.author,
      since: query.since,
      until: query.until,
      // A typed `file:` term is a search term, not a literal path —
      // `pathQuery`, never `path`.
      pathQuery: query.path,
      sha: query.sha,
      noMerges: query.noMerges,
      all: query.all,
    );
  }

  /// A single free-text token that could be a commit-hash prefix: five or
  /// more hex digits. Four is git's own disambiguation minimum, but at four
  /// too many ordinary words fit the hex alphabet ('dead', 'face', 'cafe');
  /// at five, shadowing a message search additionally requires an actual
  /// COMMIT bearing the prefix — which [build] verifies before committing to
  /// the hash reading.
  static bool _readsAsShaPrefix(String? grep) {
    final text = grep?.trim() ?? '';
    return text.length >= 5 && isResolvableShaPrefix(text);
  }

  @override
  Future<List<GitCommit>> build() async {
    // Watched, not read: a new session's [GitService] (reconnect, backend
    // switch) must re-walk this log rather than leave the previous host's
    // commits on screen. [loadMore] reads instead — it runs outside a build,
    // where a watch cannot be registered, and it always extends the list this
    // build produced.
    final git = ref.watch(gitServiceProvider);

    // A bare hash pasted into the search box means "find this commit", but it
    // is indistinguishable from a message word until the object database has
    // been asked — so ask it first. Only a prefix that names a real commit
    // wins; hex-shaped words ('added') resolve to nothing and fall through to
    // the ordinary message search. Every other criterion still narrows the
    // hash reading, exactly as it would an explicit `sha:` term.
    if (query.sha == null && _readsAsShaPrefix(query.grep)) {
      final byHash = await git.log(
        query.repoPath,
        maxCount: _depth,
        sha: query.grep!.trim(),
        author: query.author,
        since: query.since,
        until: query.until,
        pathQuery: query.path,
        noMerges: query.noMerges,
      );
      if (byHash.isNotEmpty) {
        // The object database answered in full — there is no deeper page.
        _exhausted = true;
        return byHash;
      }
    }

    final commits = await _walk(git, skip: 0, count: _depth);
    _exhausted = commits.length < _depth;
    return commits;
  }

  /// A page fetch is in flight. The list keeps its current value throughout —
  /// this is an *extension*, not a refresh, so the rows on screen stay put and
  /// there is nothing to show a spinner over except the trailing sentinel.
  bool get loadingMore => _loadingMore;
  bool _loadingMore = false;

  /// The last page fetch failed. The rows already walked are still perfectly
  /// good — a failed page is not a failed log — so the list is left alone and
  /// only the paging stops, rather than an error blowing away history the user
  /// is reading. Cleared by the next refresh, which re-walks from the top.
  bool get pageFailed => _pageFailed;
  bool _pageFailed = false;

  /// Extends the walk by one page. Safe to call on every rebuild of the
  /// load-more sentinel: it is a no-op unless there is a settled list to extend
  /// and more history to find.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null ||
        state.isLoading ||
        _loadingMore ||
        _exhausted ||
        _pageFailed) {
      return;
    }

    _loadingMore = true;
    try {
      final next = await _walk(
        ref.read(gitServiceProvider),
        skip: current.length,
        count: kHistoryPageSize,
      );
      // What git returned for the page it was actually asked for — the honest
      // end-of-history signal. The merged length is not, because the dedupe
      // below can shorten it without the history having ended.
      _exhausted = next.length < kHistoryPageSize;
      _depth = current.length + kHistoryPageSize;
      final seen = {for (final c in current) c.hash};
      state = AsyncData([...current, ...next.where((c) => seen.add(c.hash))]);
    } catch (_) {
      _pageFailed = true;
    } finally {
      _loadingMore = false;
    }
  }
}

/// Ties a **worktree-dependent** cache for one file to the two things that can
/// actually change it, and to nothing else.
///
/// A cached diff / blame / conflict / untracked preview of `lib/a.dart` goes
/// stale in exactly two ways:
///
///  1. **Its status record changed** — staged, unstaged, resolved, deleted — or
///     HEAD moved under it (a commit, a checkout, a rebase), which changes what
///     the file is being compared *against*. Both are visible in the landed
///     [GitStatus], so both are read straight off it.
///  2. **Its bytes changed with its record intact** — re-editing an
///     already-modified file. Porcelain carries no content hash, so status
///     cannot see this at all; it arrives on [worktreeEditsProvider], stamped
///     with the path the watcher actually named.
///
/// Everything is keyed to [path]. The previous design keyed all of it to the
/// repo: any filesystem event invalidated every worktree cache for every file,
/// so editing one file re-fetched all of them, and a build writing into a
/// directory git ignores re-fetched all of them several times a second.
///
/// **An in-flight fetch is never restarted.** Invalidating a provider whose
/// fetch has not landed does not refresh it — it discards the in-flight read
/// and restarts from a *bare* AsyncLoading, since there is no previous value for
/// Riverpod to carry through a refresh. The pane drops to a spinner; and if the
/// next change arrives before the restarted read finishes, that one is discarded
/// too. A repo changing faster than a diff takes to fetch would then never show
/// a diff at all — it would spin forever. So a change arriving mid-fetch is
/// *remembered* and applied once, after the value lands. Nothing is lost: the
/// read in flight is already reading the present worktree, and the single
/// follow-up closes the only real gap (a read that raced the write). Forward
/// progress is guaranteed at any rate of change.
///
/// `ref.listen` + `invalidateSelf` rather than `ref.watch`: a select-based
/// *watch* never observes the watched provider's errors, so if this cache entry
/// happened to be [statusProvider]'s only subscriber (a kept-alive diff after
/// the repo view unmounted, a viewer window on its own), a failed status refresh
/// would surface as an *unhandled* error in the zone. The listener's `onError`
/// swallows it deliberately — a failed status refresh is the status view's
/// problem to display, not this cache's.
///
/// Deliberately NOT applied to the hash-keyed caches ([commitDiffProvider] /
/// [commitFileDiffProvider]): a commit's patch is immutable, which is exactly
/// what lets those caches be large and long-lived (see [KeepAliveLru]).
void _dependOnWorktreeState(
  Ref ref,
  String repoPath, {
  required String path,
  required Future<Object?> content,
}) {
  var landed = false;
  var disposed = false;
  // A change arrived while [content] was still in flight — see the deferral
  // below.
  var refetchOnLanding = false;

  ref.onDispose(() => disposed = true);

  // Deliberately a *microtask* hop off [content], not a callback registered
  // directly on it. Riverpod publishes the fetched value from its own callback
  // on this same future, and invalidating from a callback sitting alongside it
  // can tear the element down before the value is ever published — the fetch
  // then completes over and over while the pane never leaves its spinner.
  // Hopping a microtask orders this strictly after the publish, whichever
  // callback happened to run first.
  void onLanded(Object? _) {
    Future.microtask(() {
      landed = true;
      if (refetchOnLanding && !disposed) {
        refetchOnLanding = false;
        ref.invalidateSelf();
      }
    });
  }

  // The error arm is consumed here so this derived future can't surface the
  // failure a second time — the original still reaches Riverpod, whose job it
  // is to put the provider into an error state.
  content.then(onLanded, onError: (Object _, StackTrace _) => onLanded(null));

  void staleNow() {
    if (!landed) {
      refetchOnLanding = true;
      return;
    }
    ref.invalidateSelf();
  }

  // (1) This file's record, and the commit it is diffed against.
  ref.listen(
    statusProvider(repoPath).select((s) => _fileStateOf(s.value, path)),
    (previous, next) {
      // Nothing has landed yet: the content being fetched and the status now
      // landing describe the same present worktree, so there is nothing to have
      // gone stale. (Every first open used to pay this as a guaranteed second
      // fetch.)
      if (previous == null) return;
      if (previous == next) return;
      staleNow();
    },
    onError: (_, _) {},
  );

  // (2) Bytes changed under an unchanged record.
  ref.listen(
    worktreeEditsProvider.select((s) => s.stampFor(repoPath, path)),
    (previous, next) {
      if (previous == null || previous == next) return;
      staleNow();
    },
  );
}

/// Everything about [path] that a worktree cache for it depends on: the commit
/// it is compared against, and its own status record. A value record, so
/// `select` compares it by value and fires only when *this* file moves.
///
/// `null` while no status has landed. A path git reports nothing about (a clean,
/// tracked file being blamed) yields a record with null status fields — still a
/// value, and still sensitive to HEAD moving beneath it.
({String? oid, String? x, String? y, String? oldPath})? _fileStateOf(
  GitStatus? status,
  String path,
) {
  if (status == null) return null;
  for (final file in status.files) {
    if (file.path == path) {
      return (
        oid: status.branch.oid,
        x: file.statusX,
        y: file.statusY,
        oldPath: file.oldPath,
      );
    }
  }
  return (oid: status.branch.oid, x: null, y: null, oldPath: null);
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
final _commitDiffLru = KeepAliveLru<(String, String, int)>(
  512,
  maxTotalBytes: 256 * _mib,
  maxEntryBytes: 16 * _mib,
);
final _commitFileDiffLru = KeepAliveLru<(String, String, String)>(
  512,
  maxTotalBytes: 128 * _mib,
  maxEntryBytes: 8 * _mib,
);
final _blobLru = KeepAliveLru<(String, String, String)>(
  128,
  maxTotalBytes: 64 * _mib,
  maxEntryBytes: 8 * _mib,
);
final _commitRangeDiffLru = KeepAliveLru<(String, String, String, int)>(
  64,
  maxTotalBytes: 64 * _mib,
  maxEntryBytes: 16 * _mib,
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
        // Release a failed fetch so a re-watch retries rather than serving the
        // pinned error (see KeepAliveLru.evict).
        onError: (_) => _fileLogLru.evict(key),
      );
      return future;
    });

/// Line-by-line blame for a file. Keyed by (repoPath, path). Kept alive
/// (bounded LRU) — see [KeepAliveLru].
final blameProvider = FutureProvider.autoDispose
    .family<List<BlameLine>, (String, String)>((ref, key) {
      _blameLru.touch(key, ref.keepAlive());
      final (repoPath, path) = key;
      final future = ref.watch(gitServiceProvider).blame(repoPath, path);
      // Working-copy blame reads the file as it is on disk right now — an
      // external edit must invalidate it (see _dependOnWorktreeState).
      _dependOnWorktreeState(ref, repoPath, path: path, content: future);
      future.then(
        (v) => _blameLru.reportSize(key, _estimateBlameBytes(v)),
        onError: (_) => _blameLru.evict(key),
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
      final future = ref.watch(gitServiceProvider).diffFile(
        repoPath,
        path: path,
        staged: staged,
        ignoreWhitespace: ignoreWhitespace,
        context: context,
      );
      // A worktree/index diff changes whenever the repo does — every landed
      // status refresh invalidates this so a cached diff can't go stale.
      _dependOnWorktreeState(ref, repoPath, path: path, content: future);
      future.then(
        (d) => _fileDiffLru.reportSize(key, d.length),
        onError: (_) => _fileDiffLru.evict(key),
      );
      return future;
    });

/// Full patch for a commit. Keyed by (repoPath, hash, contextLines) — the
/// context is part of the key because the same commit at `-U3` and at `-U25`
/// are two different patches, and a shared key would serve whichever landed
/// first. Kept alive (bounded LRU) — see [KeepAliveLru].
final commitDiffProvider = FutureProvider.autoDispose
    .family<String, (String, String, int)>((ref, key) {
      _commitDiffLru.touch(key, ref.keepAlive());
      final (repoPath, hash, context) = key;
      final future = ref
          .watch(gitServiceProvider)
          .showCommit(repoPath, hash, context: context);
      future.then(
        (d) => _commitDiffLru.reportSize(key, d.length),
        onError: (_) => _commitDiffLru.evict(key),
      );
      return future;
    });

/// The diff between two commits — what `newer` adds on top of `older`
/// (`git diff older..newer`). Keyed by (repoPath, olderHash, newerHash,
/// contextLines); immutable like a commit patch, so it shares the hash-keyed
/// LRU treatment.
final commitRangeDiffProvider = FutureProvider.autoDispose
    .family<String, (String, String, String, int)>((ref, key) {
      _commitRangeDiffLru.touch(key, ref.keepAlive());
      final (repoPath, older, newer, context) = key;
      final future = ref
          .watch(gitServiceProvider)
          .diffRange(repoPath, '$older..$newer', context: context);
      future.then(
        (d) => _commitRangeDiffLru.reportSize(key, d.length),
        onError: (_) => _commitRangeDiffLru.evict(key),
      );
      return future;
    });

/// A file's contents **as of a commit** (`git show <rev>:<path>`), split into
/// lines. Keyed by (repoPath, rev, path) — hash-keyed and therefore immutable,
/// so it lives in the hard-cached tier alongside commit patches.
///
/// This is what the diff viewer's context expansion reads: revealing the lines
/// around a hunk means fetching the file as that commit left it. Split here
/// (not at each call site) so the line list is computed once per blob and the
/// expansion engine can index it directly.
final blobLinesProvider = FutureProvider.autoDispose
    .family<List<String>, (String, String, String)>((ref, key) async {
      _blobLru.touch(key, ref.keepAlive());
      final (repoPath, rev, path) = key;
      try {
        final content = await ref
            .watch(gitServiceProvider)
            .showBlob(repoPath, rev, path);
        _blobLru.reportSize(key, content.length);
        final lines = const LineSplitter().convert(content);
        return lines;
      } catch (_) {
        _blobLru.evict(key);
        rethrow;
      }
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
        onError: (_) => _commitFileDiffLru.evict(key),
      );
      return future;
    });

/// The conflicted working-tree file (with merge markers). Keyed by
/// (repoPath, path). Kept alive (bounded LRU) — see [KeepAliveLru].
final conflictFileProvider = FutureProvider.autoDispose
    .family<String, (String, String)>((ref, key) {
      _conflictFileLru.touch(key, ref.keepAlive());
      final (repoPath, path) = key;
      final future = ref.watch(gitServiceProvider).conflictFile(repoPath, path);
      // Conflict markers change as the user (or another session) edits the
      // file — follow the landed status so the pane never shows stale markers.
      _dependOnWorktreeState(ref, repoPath, path: path, content: future);
      future.then(
        (d) => _conflictFileLru.reportSize(key, d.length),
        onError: (_) => _conflictFileLru.evict(key),
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
      final future = ref.watch(gitServiceProvider).diffUntracked(repoPath, path);
      // An untracked file's contents are pure worktree state — follow the
      // landed status so the rendered "diff" tracks on-disk edits.
      _dependOnWorktreeState(ref, repoPath, path: path, content: future);
      future.then(
        (d) => _untrackedDiffLru.reportSize(key, d.length),
        onError: (_) => _untrackedDiffLru.evict(key),
      );
      return future;
    });

/// Holds a forge data provider until the session's background forge logins
/// have settled, so a panel visible right at connect loads against an
/// authenticated CLI instead of flashing a transient auth error. A no-op
/// (already-completed future) for sessions without managed tokens and once
/// the logins land. See [ConnectionController.forgeAuthSettled].
Future<void> _forgeAuthReady(Ref ref) =>
    ref.read(connectionProvider.notifier).forgeAuthSettled;

/// Open merge requests for the connected project.
final mergeRequestsProvider = FutureProvider.autoDispose
    .family<List<MergeRequest>, String>((ref, repoPath) async {
      final glab = ref.watch(glabServiceProvider);
      await _forgeAuthReady(ref);
      return glab.mergeRequests(repoPath);
    });

/// Recent CI/CD pipelines for the connected project.
final pipelinesProvider = FutureProvider.autoDispose
    .family<List<Pipeline>, String>((ref, repoPath) async {
      final glab = ref.watch(glabServiceProvider);
      await _forgeAuthReady(ref);
      return glab.pipelines(repoPath);
    });

/// Jobs of a pipeline. Keyed by (repoPath, pipelineId).
final jobsProvider = FutureProvider.autoDispose
    .family<List<Job>, (String, int)>((ref, key) async {
      final (repoPath, pipelineId) = key;
      final glab = ref.watch(glabServiceProvider);
      await _forgeAuthReady(ref);
      return glab.jobs(repoPath, pipelineId);
    });

/// Live CI job-trace log. Keyed by (repoPath, jobId); emits **incremental** log
/// chunks (the view accumulates them). Auto-disposed so the remote trace process
/// is killed when the view closes.
final jobTraceProvider = StreamProvider.autoDispose
    .family<String, (String, int)>((ref, key) async* {
      final (repoPath, jobId) = key;
      final glab = ref.watch(glabServiceProvider);
      await _forgeAuthReady(ref);
      yield* glab.traceStream(repoPath, jobId);
    });

/// Project overview (issues, labels, milestones, releases) in one GraphQL hop.
final projectDashboardProvider = FutureProvider.autoDispose
    .family<ProjectDashboard, String>((ref, repoPath) async {
      final glab = ref.watch(glabServiceProvider);
      await _forgeAuthReady(ref);
      return glab.projectDashboard(repoPath);
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
  // The self-hosted fallback below consults `gh/glab auth status` — let the
  // background login land first so a custom-domain forge classifies on the
  // first probe instead of burning a three-round-trip re-probe on remount.
  await _forgeAuthReady(ref);

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

/// The authenticated user's repositories on a forge host, for the clone
/// sheet's browse list. Keyed by (forge, host, local) — an *account-level*
/// listing, independent of any active repo, so deliberately NOT keyed by
/// repoPath. `local` runs against this machine's own gh/glab (for a
/// "This Mac" destination, relying on the Mac's own CLI auth — no managed
/// token); otherwise it runs on the active/provisioned SSH session, logging
/// the host in first with the connection's stored token. Session-scoped:
/// cleared by [ConnectionController._invalidateRepoState] on every connect /
/// repo switch so a stale connection's repos never leak across hosts.
final forgeRepoListProvider = FutureProvider.autoDispose
    .family<List<ForgeRepoSummary>, (Forge, String, bool)>((ref, key) async {
      final (forge, host, local) = key;
      final executor = local
          ? ref.read(localExecutorProvider)
          : ref.read(activeExecutorProvider);
      if (local) {
        // A This-Mac browse can run before any local session exists — make
        // sure the executor's PATH can actually see the Mac's gh/glab.
        await ref.read(localEnvironmentProvider).ensure();
      } else {
        await ref.read(connectionProvider.notifier).ensureForgeHostLogin(
          forge,
          host,
        );
      }
      return switch (forge) {
        Forge.github => GhService(executor).listRepos(host: host),
        Forge.gitlab => GlabService(executor).listRepos(host: host),
        _ => throw ArgumentError('forgeRepoListProvider: not a forge: $forge'),
      };
    });

/// The forge CLI's parsed auth state on the target machine — the strict
/// judgment (a host with an expired/revoked token does NOT count as signed
/// in) behind both the wizards' host prefill and the create wizard's
/// pre-publish guard, so the two can never disagree and the guard reuses the
/// prefill's cached probe instead of spawning a second `auth status`.
/// Keyed by (forge, local) like [forgeRepoListProvider]: `local` asks this
/// Mac's own gh/glab, otherwise the active/provisioned SSH session's.
final forgeAuthProvider = FutureProvider.autoDispose
    .family<ToolAuth, (Forge, bool)>((ref, key) async {
      final (forge, local) = key;
      // Re-resolve when the connection generation moves (a landing wizard
      // can ask before its SSH session finishes provisioning — the answer
      // must not stay cached as signed-out once the host is reachable).
      ref.watch(connectionProvider.select((c) => (c.phase, c.backend)));
      final executor = local
          ? ref.read(localExecutorProvider)
          : ref.read(activeExecutorProvider);
      if (local) {
        // Can run before any local session exists (landing wizards) — make
        // sure the executor's PATH can actually see the Mac's gh/glab.
        await ref.read(localEnvironmentProvider).ensure();
      }
      final auth = await AuthProbeService(executor).probeForgeCli(forge);
      // Surfaced so "why didn't my host prefill" / "why did the guard stop
      // me" are answerable from the output log instead of being invisible.
      ref
          .read(outputLogProvider.notifier)
          .logInfo('${auth.tool} auth: ${auth.detail}');
      return auth;
    });

/// The host the forge CLI on the target machine is signed in to — what the
/// create/clone wizards prefill their forge-host fields with, so a user on a
/// self-hosted instance (or GitHub Enterprise) sees their real host instead
/// of the stock github.com/gitlab.com default. Derived from
/// [forgeAuthProvider]'s strict judgment: null when signed out, the CLI is
/// missing, the token is expired, or the check couldn't complete — the
/// caller keeps its stock default in every one of those cases.
final forgeAuthHostProvider = FutureProvider.autoDispose
    .family<String?, (Forge, bool)>((ref, key) async {
      final auth = await ref.watch(forgeAuthProvider(key).future);
      return auth.authenticated ? auth.host : null;
    });

/// Authentication status of git/gh/glab on **this Mac** — probed on demand for
/// the Dashboard's Authentication section (and reusable by any This-Mac flow
/// that wants to warn before a create/clone that would fail on a signed-out
/// CLI). Ensures the local executor's PATH can see Homebrew tools first, since
/// this can run before any local session exists.
final localAuthStatusProvider = FutureProvider.autoDispose<TargetAuth>((
  ref,
) async {
  await ref.read(localEnvironmentProvider).ensure();
  final auth = await AuthProbeService(
    ref.read(localExecutorProvider),
  ).probe(label: 'This Mac', isLocal: true);
  ref
      .read(outputLogProvider.notifier)
      .logInfo(
        'auth (this Mac): '
        'gh ${auth.gh.authenticated ? auth.gh.host : 'signed out'}, '
        'glab ${auth.glab.authenticated ? auth.glab.host : 'signed out'}',
      );
  return auth;
});

/// Authentication status of git/gh/glab on the **active session's** target —
/// the connected SSH host, or this Mac for a local session. Null when nothing
/// is connected. Re-resolves when the connection generation moves so a
/// reconnect / repo switch never shows a stale host.
final sessionAuthStatusProvider = FutureProvider.autoDispose<TargetAuth?>((
  ref,
) async {
  final (phase, backend, label, host, repoPath) = ref.watch(
    connectionProvider.select(
      (c) => (c.phase, c.backend, c.connectionLabel, c.host, c.repoPath),
    ),
  );
  if (phase != ConnectionPhase.connected) return null;
  final isLocal = backend == ConnectionBackend.local;
  final display = isLocal
      ? 'This Mac (active session)'
      : (label ?? host ?? 'Connected host');
  return AuthProbeService(ref.read(activeExecutorProvider)).probe(
    label: display,
    isLocal: isLocal,
    // Run from the repo when there is one so a repo-scoped gh/glab host
    // (an Enterprise remote) resolves; falls back to the home dir otherwise.
    cwd: repoPath ?? '.',
  );
});

/// Open pull requests for the connected GitHub repo.
final pullRequestsProvider = FutureProvider.autoDispose
    .family<List<PullRequest>, String>((ref, repoPath) async {
      final gh = ref.watch(ghServiceProvider);
      await _forgeAuthReady(ref);
      return gh.pullRequests(repoPath);
    });

/// Recent GitHub Actions workflow runs for the connected repo.
final workflowRunsProvider = FutureProvider.autoDispose
    .family<List<WorkflowRun>, String>((ref, repoPath) async {
      final gh = ref.watch(ghServiceProvider);
      await _forgeAuthReady(ref);
      return gh.workflowRuns(repoPath);
    });

/// Live jobs of a workflow run, keyed by (repoPath, runId). Polls until the run
/// completes (GitHub exposes no live log stream); auto-disposed so the poll
/// stops when the view closes.
final runJobsProvider = StreamProvider.autoDispose
    .family<List<GhJob>, (String, int)>((ref, key) async* {
      final (repoPath, runId) = key;
      final gh = ref.watch(ghServiceProvider);
      await _forgeAuthReady(ref);
      yield* gh.runJobsStream(repoPath, runId);
    });

/// A completed job's log, keyed by (repoPath, jobId). GitHub only serves logs
/// once a job finishes; an in-progress job surfaces as an error the view shows
/// as a "logs available when the job completes" placeholder.
final runJobLogProvider = FutureProvider.autoDispose
    .family<String, (String, int)>((ref, key) async {
      final (repoPath, jobId) = key;
      final gh = ref.watch(ghServiceProvider);
      await _forgeAuthReady(ref);
      return gh.runJobLog(repoPath, jobId);
    });

/// GitHub repository overview (issues, labels, milestones, releases) in one
/// GraphQL hop.
final githubProjectDashboardProvider = FutureProvider.autoDispose
    .family<GhProjectDashboard, String>((ref, repoPath) async {
      final gh = ref.watch(ghServiceProvider);
      await _forgeAuthReady(ref);
      return gh.projectDashboard(repoPath);
    });
