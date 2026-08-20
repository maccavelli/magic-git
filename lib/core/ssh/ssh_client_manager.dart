import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../exec/command_telemetry.dart';
import '../utils/pausable_timeout.dart';
import 'native_ssh_socket.dart';

class SSHConnectionProfile {
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKey;
  final String? passphrase;

  const SSHConnectionProfile({
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
    this.privateKey,
    this.passphrase,
  });
}

/// Actively verifies a connection is still alive by pinging it on an interval
/// and declaring it dead after consecutive unanswered pings.
///
/// Why this exists: dartssh2's own `keepAliveInterval` sends a keepalive ping
/// every few seconds but *never checks whether it was answered* — no
/// unanswered-ping counter, no timeout on the reply. A NAT/firewall silently
/// dropping the connection therefore surfaces only when TCP itself gives up
/// (minutes) or the next command hits its own timeout (up to 60s of a wedged
/// UI). This monitor turns that into prompt detection: [onDead] force-closes
/// the client, its `done` completes, and the existing auto-reconnect machinery
/// takes over within seconds.
///
/// Three consecutive failures (not one) are required, and pings never overlap
/// — a reply delayed past [pingTimeout] by a saturated link mustn't kill a
/// connection that's actually fine. Three rather than two: with the read lane
/// running several concurrent compressed transfers, a slow link can
/// legitimately starve keepalive replies for tens of seconds; a false kill
/// costs far more (a reconnect fails every in-flight command as superseded)
/// than the extra ~15 s a real dead peer now takes to detect.
class ConnectionHealthMonitor {
  ConnectionHealthMonitor({
    required this.ping,
    required this.onDead,
    this.onPingSample,
    this.interval = const Duration(seconds: 15),
    this.pingTimeout = const Duration(seconds: 15),
    this.failureThreshold = 3,
    this.isBusy,
  });

  /// Sends one keepalive round trip; the returned future completes when the
  /// peer replies (dartssh2's `SSHClient.ping`).
  final Future<void> Function() ping;

  /// Invoked exactly once, after [failureThreshold] consecutive failed pings.
  final void Function() onDead;

  /// Invoked with each *answered* ping's round-trip time — the probes were
  /// already being sent every [interval]; this just stops discarding the
  /// timing so the dashboard can chart link latency for free.
  final void Function(Duration rtt)? onPingSample;

  final Duration interval;
  final Duration pingTimeout;
  final int failureThreshold;

  /// When true, skip new probes and do not count in-flight failures.
  /// Null means always probe (idle-only behavior).
  final bool Function()? isBusy;

  Timer? _timer;
  int _failures = 0;
  bool _probeInFlight = false;
  bool _stopped = false;

  /// Consecutive failed probes so far — for tests/diagnostics.
  int get failures => _failures;

  /// Clears accumulated failures (command settle / stream byte activity).
  void resetFailures() => _failures = 0;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => _probe());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _probe() async {
    // Never stack probes: a ping still awaiting its reply when the next tick
    // fires would double-count one slow round trip as two failures.
    if (_probeInFlight || _stopped) return;
    if (isBusy?.call() ?? false) {
      _failures = 0;
      return;
    }
    _probeInFlight = true;
    try {
      final sw = Stopwatch()..start();
      await ping().timeout(pingTimeout);
      _failures = 0;
      if (!_stopped) onPingSample?.call(sw.elapsed);
    } catch (_) {
      if (_stopped) return;
      // A probe that started idle and timed out after work began must not
      // count: the transfer is the liveness signal.
      if (isBusy?.call() ?? false) return;
      if (++_failures >= failureThreshold) {
        stop();
        onDead();
      }
    } finally {
      _probeInFlight = false;
    }
  }
}

/// Owns the long-lived SSH connection(s). POSIX remotes only (a native
/// Windows port lives in a separate codebase), so there is no shell probing.
///
/// **Triple client:** when connect succeeds, extra [SSHClient]s are opened for
/// long-lived streams (watcher, CI trace) and for [ExecLane.sync] (fetch/push)
/// so bulk pack transfer does not share a TCP connection with interactive
/// reads. Stream and sync each fail-open onto the command client.
class SSHClientManager {
  static const Duration _socketTimeout = Duration(seconds: 15);
  static const Duration _authTimeout = Duration(seconds: 15);

  /// Stream client is best-effort; fail open to single-client quickly.
  static const Duration _streamAuthTimeout = Duration(seconds: 10);

  /// Sync client is best-effort; fail open so fetch/push share the command
  /// client (today's dual-client behaviour).
  static const Duration _syncAuthTimeout = _streamAuthTimeout;

  /// Command / SFTP / health-monitor client (primary).
  SSHClient? _client;

  /// Long-lived stream client; null when degraded to single-client mode.
  SSHClient? _streamClient;

  /// Sync-lane client (`fetch`/`push`); null when degraded onto [_client].
  SSHClient? _syncClient;

  /// Active dead-peer monitor for [_client] (see [ConnectionHealthMonitor]).
  /// Started when a connect succeeds, stopped when that client is retired.
  ConnectionHealthMonitor? _health;

  /// Dead-peer monitor for [_streamClient]. The stream client is idle by
  /// design (a watcher can be quiet for hours), which makes it exactly the
  /// connection a NAT/firewall idle-drop kills first — and, unlike the
  /// command client, nothing else would ever notice: a silently-dead stream
  /// channel never fires the watcher's onDone, so the UI's watching dot
  /// stays green while external changes go unseen for the rest of the
  /// session. Null when running degraded (single client).
  ConnectionHealthMonitor? _streamHealth;

  /// Dead-peer monitor for [_syncClient]. The sync TCP is idle except during
  /// fetch/push, so a NAT drop would otherwise only surface on the next sync.
  ConnectionHealthMonitor? _syncHealth;

  /// Every client currently being authenticated by an in-flight [connect].
  /// Tracked separately from [_client] (which is only assigned once auth
  /// succeeds) so [disconnect] can force-close all of them immediately
  /// instead of leaving their handshakes to run unbounded in the background.
  /// A set, not a single nullable slot: if two connect() attempts overlap
  /// during the handshake phase (e.g. a fast reconnect-tap racing an already
  /// in-flight attempt), a single slot would only track whichever attempt
  /// wrote it last, leaving an earlier attempt's socket silently open past a
  /// disconnect() until its own auth timeout eventually closes it.
  final Set<SSHClient> _pending = {};

  /// Monotonic attempt counter. Every [connect]/[disconnect] bumps it; an
  /// in-flight connect that finds the counter changed knows it has been
  /// superseded (by a newer connect or a disconnect) and tears its client down
  /// instead of attaching it — this prevents attaching the UI to the wrong host
  /// and prevents leaking an authenticated connection past a disconnect.
  int _generation = 0;

  /// The generation whose [connect] produced the current [_client], or -1
  /// while no client is attached. Distinct from [generation]: a new connect
  /// bumps [generation] at its *start* but only swaps [_client] at its *end*
  /// (deliberately, so a failed attempt doesn't kill a working session) —
  /// during that window the two disagree, and a command must run against
  /// neither the stale client nor the not-yet-attached new one.
  int _clientGeneration = -1;

  /// What a stream-client redial needs to dial with — the profile and verify
  /// callback of the connect that produced the current session. Held only
  /// while a session is attached; cleared by [_closeClient].
  SSHConnectionProfile? _redialProfile;
  FutureOr<bool> Function(String type, Uint8List fingerprint)? _redialVerify;

  /// Pending stream-client redial (see [_onStreamClientLost]) and its
  /// consecutive-failure count. The counter resets on a successful attach.
  Timer? _redialTimer;
  int _redialFailures = 0;
  Timer? _syncRedialTimer;
  int _syncRedialFailures = 0;

  /// Consecutive failed stream redials before giving up for the session. A
  /// host that structurally refuses a second session (MaxSessions 1, auth
  /// rate limiting) must not be hammered with a handshake a minute forever —
  /// past this the session simply stays degraded until the next reconnect.
  static const int _maxRedialFailures = 5;

  bool Function()? _commandBusyProbe;
  bool Function()? _streamBusyProbe;
  bool Function()? _syncBusyProbe;
  TransportDropCause? _lastDropCause;
  DateTime? _connectedAt;

  TransportDropCause? get lastDropCause => _lastDropCause;

  void registerBusyProbes({
    bool Function()? command,
    bool Function()? stream,
    bool Function()? sync,
  }) {
    _commandBusyProbe = command;
    _streamBusyProbe = stream;
    _syncBusyProbe = sync;
  }

  void noteCommandSettled() => _health?.resetFailures();

  void noteStreamActivity() => _streamHealth?.resetFailures();

  void noteSyncSettled() => _syncHealth?.resetFailures();

  void _recordMonitorDrop({
    required ConnectionHealthMonitor monitor,
    required bool Function()? busy,
  }) {
    _lastDropCause = TransportDropCause.monitor;
    CommandTelemetry.instance.recordTransportDrop(
      TransportDropSample(
        cause: TransportDropCause.monitor,
        failures: monitor.failures,
        busy: busy?.call() ?? false,
        connectionAge: DateTime.now().difference(
          _connectedAt ?? DateTime.now(),
        ),
        at: DateTime.now(),
      ),
    );
  }

  /// Backoff for stream-client redial attempt number [failures] (0-based):
  /// 15s, 30s, 60s, 120s, 120s.
  @visibleForTesting
  static Duration streamRedialDelay(int failures) =>
      Duration(seconds: math.min(15 << failures, 120));

  /// Test-only: install already-authenticated client slots without running a
  /// handshake, so unit tests can assert which slot a lane actually talks to.
  ///
  /// Stops and clears any live health monitors and redial timers first — a
  /// manager that had really connected must not keep pinging a fake — and
  /// starts none of its own. [connect] is untouched; nothing in production
  /// calls this.
  @visibleForTesting
  void bindTestClients({
    SSHClient? command,
    SSHClient? stream,
    SSHClient? sync,
  }) {
    _generation++;
    _health?.stop();
    _health = null;
    _streamHealth?.stop();
    _streamHealth = null;
    _syncHealth?.stop();
    _syncHealth = null;
    _redialTimer?.cancel();
    _redialTimer = null;
    _syncRedialTimer?.cancel();
    _syncRedialTimer = null;
    _client = command;
    _streamClient = stream;
    _syncClient = sync;
    _clientGeneration = command == null ? -1 : _generation;
  }

  /// Primary client (commands, SFTP, health). Backward-compatible name.
  SSHClient? get client => _client;

  /// Client for [SSHCommandExecutor.executeStream]. Falls back to [client]
  /// when the dual stream client failed to connect (degraded mode).
  SSHClient? get streamClient => _streamClient ?? _client;

  /// True when streams share the command client (stream open failed).
  bool get streamClientDegraded => _client != null && _streamClient == null;

  /// Client for [ExecLane.sync]. Falls back to [client] when the dedicated
  /// sync handshake failed or has not been re-dialed yet.
  SSHClient? get syncClient => _syncClient ?? _client;

  /// True when sync-lane work shares the command client.
  bool get syncClientDegraded => _client != null && _syncClient == null;

  /// 0 disconnected, 1 single, 2 dual, 3 triple.
  int get attachedClientCount =>
      (_client == null ? 0 : 1) +
      (_streamClient != null ? 1 : 0) +
      (_syncClient != null ? 1 : 0);

  /// Current attempt generation. Bumped by every [connect]/[disconnect].
  /// Exposed so callers that queue work against the *current* connection
  /// (notably [SSHCommandExecutor]'s command scheduler) can detect
  /// that a reconnect/disconnect happened before their turn came up, and
  /// refuse to run against whatever host happens to be connected by then.
  int get generation => _generation;

  /// The generation the currently-attached [client] belongs to (-1 when
  /// none). A command pinned to generation G may only run when *both*
  /// [generation] and this equal G — see [_clientGeneration].
  int get clientGeneration => _clientGeneration;

  /// Whether a command can run right now: a client attached, and belonging to
  /// the current generation rather than a superseded attempt.
  ///
  /// This is the transport's own truth, deliberately independent of any UI
  /// phase. It is already true mid-[connect], the moment the handshake lands
  /// and before the app publishes `connected` — which matters, because the
  /// connect path runs its own commands (the environment probe, the repo
  /// check) through this same executor.
  bool get isAttached => _client != null && _clientGeneration == _generation;

  /// Completes when the in-flight [connect] settles — attached, failed, or
  /// superseded. Already complete when nothing is in flight, so awaiting it
  /// on an idle manager returns at once instead of hanging.
  Future<void> get attachSettled => _attachGate.future;

  /// Whether nothing is in flight. A `Future` cannot answer this
  /// synchronously, and a command must tell "wait for the handshake" from
  /// "there is no handshake" *without* waiting to find out (MADR 0018).
  bool get isAttachSettled => _attachGate.isCompleted;

  /// Starts completed: before any connect there is nothing to wait for.
  Completer<void> _attachGate = Completer<void>()..complete();

  /// Completes when the primary (command) transport closes — whether from a
  /// remote-side drop, network loss, or our own [disconnect]. Callers use it to
  /// detect an unexpected drop (and offer reconnect). Null when not connected.
  /// Stream-only death does **not** complete this; watchers restart on their own.
  Future<void>? get done => _client?.done;

  /// Connects to [profile]. When given, [onVerifyHostKey] is consulted with
  /// the presented host key's algorithm name and OpenSSH-style SHA256
  /// fingerprint (`SHA256:<base64>`, matching `ssh-keygen -lf`'s output) —
  /// return true to trust it and proceed, false to reject it and abort the
  /// connection. Omitting it accepts any host key unverified.
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    void Function(Duration rtt)? onPingSample,
  }) async {
    await withAttachGate(
      () => _connect(
        profile,
        onVerifyHostKey: onVerifyHostKey,
        onPingSample: onPingSample,
      ),
    );
  }

  /// Runs [body] as an attach attempt: opens the gate [attachSettled] waits
  /// on, and settles it on EVERY exit — success, failure, supersession, or
  /// throw. [_connect] has several early returns, so this wrapper is what
  /// makes that a guarantee; a command waiting on the gate must never outlive
  /// the handshake it is waiting for.
  ///
  /// Public to tests so the "handshake in flight" half of the readiness
  /// contract can be driven without a socket — the same reason
  /// [bindTestClients] exists.
  @visibleForTesting
  Future<T> withAttachGate<T>(Future<T> Function() body) async {
    if (!_attachGate.isCompleted) _attachGate.complete();
    _attachGate = Completer<void>();
    try {
      return await body();
    } finally {
      if (!_attachGate.isCompleted) _attachGate.complete();
    }
  }

  Future<void> _connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    void Function(Duration rtt)? onPingSample,
  }) async {
    final gen = ++_generation;
    // The previous clients (if any) are deliberately left open and serving
    // `client`/`done` through this entire attempt — they're only retired once
    // the new command client actually succeeds, at the very end of this method.
    final previousCmd = _client;
    final previousStream = _streamClient;
    final previousSync = _syncClient;

    // Both handshakes run CONCURRENTLY, so a connect pays max(cmd, stream)
    // rather than their sum — a full extra TCP+KEX+auth round trip on every
    // connect, felt hardest exactly where this app is meant to shine (high-
    // RTT links). Concurrency is safe only because the verify callback is
    // serialized (see [serializeHostKeyVerifier]): two handshakes verifying
    // the same unknown/changed key at once would otherwise race the TOFU
    // store — or, on a mismatch, stack two prompts on the UI's single
    // decision slot and leave one handshake paused forever.
    final verify = serializeHostKeyVerifier(onVerifyHostKey);
    // Bcrypt KDF for encrypted PEMs runs off this isolate, once per connect.
    // All three handshakes reuse the decoded identities.
    final identities = await _identitiesFor(profile);
    if (gen != _generation) return;
    final cmdFuture = _openAuthenticatedClient(
      profile,
      gen: gen,
      onVerifyHostKey: verify,
      authTimeout: _authTimeout,
      identities: identities,
    );
    // Best-effort second client for streams. Never fail the whole connect if
    // this fails — degrade to single-client (streams share command client).
    // Errors are absorbed HERE, at creation, not at the later await: this
    // future is also awaited on the command-failure path, where an unhandled
    // second error would otherwise escape as an uncaught async exception.
    final streamFuture =
        _openAuthenticatedClient(
          profile,
          gen: gen,
          onVerifyHostKey: verify,
          authTimeout: _streamAuthTimeout,
          identities: identities,
        ).then<SSHClient?>(
          (c) => c,
          onError: (Object e, StackTrace st) {
            developer.log(
              'stream SSH client failed; degrading to single client: $e',
              name: 'SSHClientManager',
              error: e,
              stackTrace: st,
            );
            return null;
          },
        );
    final syncFuture =
        _openAuthenticatedClient(
          profile,
          gen: gen,
          onVerifyHostKey: verify,
          authTimeout: _syncAuthTimeout,
          identities: identities,
        ).then<SSHClient?>(
          (c) => c,
          onError: (Object e, StackTrace st) {
            developer.log(
              'sync SSH client failed; degrading to dual client: $e',
              name: 'SSHClientManager',
              error: e,
              stackTrace: st,
            );
            return null;
          },
        );

    final SSHClient? cmdClient;
    try {
      cmdClient = await cmdFuture;
    } catch (_) {
      // The stream/sync handshakes may still succeed in the background — close
      // whatever they produce, since no session exists for them to serve.
      unawaited(streamFuture.then((c) => c?.close()));
      unawaited(syncFuture.then((c) => c?.close()));
      // This attempt already bumped the generation past the previous session,
      // so every command pinned from here on refuses to run against it —
      // "keeping" it on failure would keep only its sockets and its ping
      // loop, invisible and unusable, until some later connect or disconnect.
      // Retire it so the transport agrees with what commands can reach. Gen-
      // guarded: if a newer attempt started meanwhile, cleanup is its call.
      if (gen == _generation) await _closeClient();
      rethrow;
    }
    if (cmdClient == null) {
      // Superseded during command-client handshake — leave previous attached;
      // the superseding attempt owns retirement now. The stream attempt makes
      // the same generation checks and self-closes, but close defensively in
      // case it finished before the supersession landed.
      unawaited(streamFuture.then((c) => c?.close()));
      unawaited(syncFuture.then((c) => c?.close()));
      return;
    }
    // Non-nullable rebind: `cmdClient` was assigned inside a try, which bars
    // its promotion inside the monitor closures below.
    final cmd = cmdClient;

    final streamClient = await streamFuture;
    final syncClient = await syncFuture;
    // Superseded after the handshakes — drop all new clients.
    if (gen != _generation) {
      await cmdClient.close();
      if (streamClient != null) await streamClient.close();
      if (syncClient != null) await syncClient.close();
      return;
    }

    // This attempt wins: only now do we retire the previous clients.
    _health?.stop();
    _streamHealth?.stop();
    _streamHealth = null;
    _syncHealth?.stop();
    _syncHealth = null;
    _redialTimer?.cancel();
    _redialTimer = null;
    _syncRedialTimer?.cancel();
    _syncRedialTimer = null;
    unawaited(previousCmd?.close());
    // Avoid double-close when previous was already degraded (stream == null)
    // or when stream shared nothing with cmd.
    if (previousStream != null && !identical(previousStream, previousCmd)) {
      unawaited(previousStream.close());
    }
    if (previousSync != null &&
        !identical(previousSync, previousCmd) &&
        !identical(previousSync, previousStream)) {
      unawaited(previousSync.close());
    }
    _client = cmd;
    _streamClient = streamClient;
    _syncClient = syncClient;
    _clientGeneration = gen;
    _connectedAt = DateTime.now();
    _lastDropCause = null;
    // What a mid-session stream redial dials with (see [_onStreamClientLost]).
    // The raw verify callback, not this connect's serialized wrapper: a redial
    // is a single handshake, and the wrapper would needlessly chain it behind
    // this (long-finished) connect's verifications.
    _redialProfile = profile;
    _redialVerify = onVerifyHostKey;
    _redialFailures = 0;
    _syncRedialFailures = 0;

    // Health monitor on the command client only. onDead must close both
    // clients but *not* null [_client]: ConnectionController listens to
    // [done] on the primary client to drive reconnect — nulling it would
    // drop that Future before the drop path observes it.
    late final ConnectionHealthMonitor monitor;
    monitor = ConnectionHealthMonitor(
      ping: () => cmd.ping(),
      isBusy: () => _commandBusyProbe?.call() ?? false,
      onDead: () {
        _recordMonitorDrop(monitor: monitor, busy: _commandBusyProbe);
        final stream = _streamClient;
        if (stream != null && !identical(stream, cmd)) {
          unawaited(stream.close());
        }
        _streamClient = null;
        final sync = _syncClient;
        if (sync != null && !identical(sync, cmd) && !identical(sync, stream)) {
          unawaited(sync.close());
        }
        _syncClient = null;
        unawaited(cmd.close());
      },
      onPingSample: onPingSample,
    )..start();
    _health = monitor;
    unawaited(
      cmd.done.then((_) {}, onError: (_) {}).whenComplete(monitor.stop),
    );

    // The stream client gets its own monitor and death listener (see
    // [_attachStreamClient]). A connect that starts degraded goes straight
    // into the redial cycle instead — the up-front failure may have been the
    // same transient the mid-session path recovers from.
    // (`streamClient` here is connect()'s local — the just-opened stream
    // client, null when degraded — NOT the like-named getter, whose fallback
    // would wrongly hang a monitor on the command client.)
    if (streamClient != null) {
      _attachStreamClient(streamClient, gen);
    } else {
      _onStreamClientLost(gen);
    }
    if (syncClient != null) {
      _attachSyncClient(syncClient, gen);
    } else {
      _onSyncClientLost(gen);
    }
  }

  /// Installs [stream] as the dedicated stream client for generation [gen]:
  /// its own dead-peer monitor (see [_streamHealth]) plus a death listener
  /// that — dead or alive — clears its slot the moment its transport closes,
  /// so the `streamClient` getter's fall-back to the command client (the
  /// documented degraded mode) engages mid-session too. Identity-guarded: by
  /// the time this client dies, a newer connect may already own the slot.
  void _attachStreamClient(SSHClient stream, int gen) {
    _redialTimer?.cancel();
    _redialTimer = null;
    _streamClient = stream;
    late final ConnectionHealthMonitor streamMonitor;
    streamMonitor = ConnectionHealthMonitor(
      ping: () => stream.ping(),
      isBusy: () => _streamBusyProbe?.call() ?? false,
      onDead: () {
        _recordMonitorDrop(monitor: streamMonitor, busy: _streamBusyProbe);
        if (identical(_streamClient, stream)) _streamClient = null;
        unawaited(stream.close());
      },
    )..start();
    _streamHealth = streamMonitor;
    unawaited(
      stream.done.then((_) {}, onError: (_) {}).whenComplete(() {
        streamMonitor.stop();
        if (identical(_streamClient, stream)) _streamClient = null;
        // The stream connection is idle by design, which makes it exactly the
        // one a NAT/firewall idle-drop kills — losing it must not degrade the
        // session to single-client for the rest of its life.
        _onStreamClientLost(gen);
      }),
    );
  }

  /// Schedules a background redial of the dedicated stream client (with
  /// backoff — see [streamRedialDelay]), after its transport died mid-session
  /// or the initial open degraded. Every step is generation-guarded, so a
  /// reconnect/disconnect supersedes the cycle for free, and [_closeClient]
  /// cancels the pending timer outright. Gives up for the session after
  /// [_maxRedialFailures] consecutive failures.
  void _onStreamClientLost(int gen) {
    if (gen != _generation || _client == null) return;
    final profile = _redialProfile;
    if (profile == null) return;
    if (_redialFailures >= _maxRedialFailures) {
      developer.log(
        'stream SSH client gave out $_redialFailures times; staying on a '
        'single client for the rest of this session',
        name: 'SSHClientManager',
      );
      return;
    }
    _redialTimer?.cancel();
    _redialTimer = Timer(streamRedialDelay(_redialFailures), () async {
      _redialTimer = null;
      // Re-check everything at fire time: the session may have moved on, or a
      // stream client may already be back (a full reconnect landed first).
      if (gen != _generation || _client == null || _streamClient != null) {
        return;
      }
      SSHClient? stream;
      try {
        stream = await _openAuthenticatedClient(
          profile,
          gen: gen,
          onVerifyHostKey: _redialVerify,
          authTimeout: _streamAuthTimeout,
        );
      } catch (e) {
        developer.log(
          'stream SSH client redial failed: $e',
          name: 'SSHClientManager',
        );
        _redialFailures++;
        _onStreamClientLost(gen);
        return;
      }
      // Null means superseded mid-handshake (the open self-closed the
      // client): a newer connect owns the session now — stop, don't count it
      // as a failure.
      if (stream == null) return;
      if (gen != _generation || _client == null) {
        await stream.close();
        return;
      }
      _redialFailures = 0;
      _attachStreamClient(stream, gen);
      developer.log(
        'stream SSH client re-established after mid-session loss',
        name: 'SSHClientManager',
      );
    });
  }

  void _attachSyncClient(SSHClient sync, int gen) {
    _syncRedialTimer?.cancel();
    _syncRedialTimer = null;
    _syncClient = sync;
    late final ConnectionHealthMonitor syncMonitor;
    syncMonitor = ConnectionHealthMonitor(
      ping: () => sync.ping(),
      isBusy: () => _syncBusyProbe?.call() ?? false,
      onDead: () {
        _recordMonitorDrop(monitor: syncMonitor, busy: _syncBusyProbe);
        if (identical(_syncClient, sync)) _syncClient = null;
        unawaited(sync.close());
      },
    )..start();
    _syncHealth = syncMonitor;
    unawaited(
      sync.done.then((_) {}, onError: (_) {}).whenComplete(() {
        syncMonitor.stop();
        if (identical(_syncClient, sync)) _syncClient = null;
        _onSyncClientLost(gen);
      }),
    );
  }

  void _onSyncClientLost(int gen) {
    if (gen != _generation || _client == null) return;
    final profile = _redialProfile;
    if (profile == null) return;
    if (_syncRedialFailures >= _maxRedialFailures) {
      developer.log(
        'sync SSH client gave out $_syncRedialFailures times; staying '
        'degraded to the command client for the rest of this session',
        name: 'SSHClientManager',
      );
      return;
    }
    _syncRedialTimer?.cancel();
    _syncRedialTimer = Timer(streamRedialDelay(_syncRedialFailures), () async {
      _syncRedialTimer = null;
      if (gen != _generation || _client == null || _syncClient != null) {
        return;
      }
      SSHClient? sync;
      try {
        sync = await _openAuthenticatedClient(
          profile,
          gen: gen,
          onVerifyHostKey: _redialVerify,
          authTimeout: _syncAuthTimeout,
        );
      } catch (e) {
        developer.log(
          'sync SSH client redial failed: $e',
          name: 'SSHClientManager',
        );
        _syncRedialFailures++;
        _onSyncClientLost(gen);
        return;
      }
      if (sync == null) return;
      if (gen != _generation || _client == null) {
        await sync.close();
        return;
      }
      _syncRedialFailures = 0;
      _attachSyncClient(sync, gen);
      developer.log(
        'sync SSH client re-established after mid-session loss',
        name: 'SSHClientManager',
      );
    });
  }

  /// Serializes concurrent host-key verification callbacks: each invocation
  /// waits for every earlier one to resolve before [verify] runs. The two
  /// parallel handshakes in [connect] both verify the same host — without
  /// this, a first-contact (TOFU) connect double-writes the known-hosts
  /// store, and a *changed* key stacks two prompts onto the UI's single
  /// decision slot, leaving whichever handshake lost the race paused on a
  /// completer nobody holds anymore. Serialized, the first verification
  /// records the decision and the second resolves silently against the
  /// updated store. Errors are routed to the caller whose verification threw;
  /// the chain itself never breaks.
  @visibleForTesting
  static FutureOr<bool> Function(String, Uint8List)? serializeHostKeyVerifier(
    FutureOr<bool> Function(String type, Uint8List fingerprint)? verify,
  ) {
    if (verify == null) return null;
    var chain = Future<void>.value();
    return (type, fingerprint) {
      final result = Completer<bool>();
      chain = chain.then((_) async {
        try {
          result.complete(await verify(type, fingerprint));
        } catch (e, st) {
          result.completeError(e, st);
        }
      });
      return result.future;
    };
  }

  /// Decodes [pem] off the UI isolate (bcrypt KDF for encrypted keys) and
  /// re-parses the exported unencrypted PEM here. [toPem] of an in-memory
  /// OpenSSH key is unencrypted, so the second [fromPem] is cheap.
  @visibleForTesting
  static Future<List<SSHKeyPair>> decodeIdentities(
    String pem,
    String? passphrase,
  ) async {
    final exported = await Isolate.run(() {
      final keys = SSHKeyPair.fromPem(pem, passphrase);
      return [for (final k in keys) k.toPem()];
    });
    return [for (final p in exported) ...SSHKeyPair.fromPem(p)];
  }

  Future<List<SSHKeyPair>?> _identitiesFor(SSHConnectionProfile profile) async {
    final privateKey = profile.privateKey;
    if (privateKey == null || privateKey.isEmpty) return null;
    return decodeIdentities(privateKey, profile.passphrase);
  }

  /// Opens and authenticates one [SSHClient]. Returns null if [gen] was
  /// superseded mid-handshake. Throws on auth/socket failure (caller decides
  /// whether that fails connect or degrades).
  Future<SSHClient?> _openAuthenticatedClient(
    SSHConnectionProfile profile, {
    required int gen,
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    required Duration authTimeout,
    List<SSHKeyPair>? identities,
  }) async {
    // Auth method selection is deliberate: a non-null `onPasswordRequest`
    // *registers* the password method with the server. Returning `''` for a
    // key-only profile would attempt empty-password auth on every connect
    // (burning MaxAuthTries / fail2ban and delaying publickey). Only enable
    // password when a real password was supplied; only enable publickey when
    // a private key was supplied. Require at least one — otherwise auth can
    // never succeed and we fail fast instead of hanging on `none`.
    final password = profile.password;
    final privateKey = profile.privateKey;
    final hasPassword = password != null && password.isNotEmpty;
    final hasKey = privateKey != null && privateKey.isNotEmpty;
    if (!hasPassword && !hasKey) {
      throw ArgumentError(
        'SSHConnectionProfile requires a password or a private key',
      );
    }
    // Redial of a single client may decode again (rare). Connect passes the
    // already-decoded list so bcrypt runs once for the whole handshake batch.
    final resolvedIdentities = hasKey
        ? (identities ?? await _identitiesFor(profile))
        : null;
    if (gen != _generation) return null;

    final socket = await NativeSshSocket.connect(
      profile.host,
      profile.port,
      timeout: _socketTimeout,
    );

    // A host-key mismatch pauses on `onVerifyHostKey` awaiting an explicit
    // human decision (see [ConnectionController._verifyHostKey]), which can
    // legitimately take far longer than the auth timeout — this flag lets the
    // timeout below tell "genuinely stuck" apart from "waiting on a person."
    var awaitingHostKeyDecision = false;

    final SSHClient client;
    try {
      client = SSHClient(
        socket,
        username: profile.username,
        // Only when a password exists — see comment above.
        onPasswordRequest: hasPassword ? () => password : null,
        identities: resolvedIdentities,
        // Dead-peer detection is owned by [ConnectionHealthMonitor]
        // (which checks whether pings are *answered*). The library's own
        // keepAliveInterval fires-and-forgets without a reply counter, and
        // stacking both doubles global-request traffic during bulk reads —
        // so leave the library keepalive off.
        keepAliveInterval: null,
        handshakeTimeout: _socketTimeout,
        onVerifyHostKey: onVerifyHostKey == null
            ? null
            : (type, fingerprint) async {
                awaitingHostKeyDecision = true;
                try {
                  return await onVerifyHostKey(type, fingerprint);
                } finally {
                  awaitingHostKeyDecision = false;
                }
              },
      );
    } catch (_) {
      socket.destroy();
      rethrow;
    }

    // Superseded while the socket was connecting.
    if (gen != _generation) {
      await client.close();
      return null;
    }

    // Exposed for the duration of the handshake so a concurrent disconnect()
    // can force-close this exact client rather than only marking it stale.
    _pending.add(client);
    try {
      await awaitWithPausableTimeout(
        client.authenticated,
        authTimeout,
        isPaused: () => awaitingHostKeyDecision,
      );
    } catch (_) {
      await client.close();
      rethrow;
    } finally {
      _pending.remove(client);
    }

    // Superseded while authenticating — don't leak the live connection.
    if (gen != _generation) {
      await client.close();
      return null;
    }
    developer.log(
      'SSH handshake remote=${client.remoteVersion} strictKex=${client.strictKex}',
      name: 'SSHClientManager',
    );
    return client;
  }

  Future<void> disconnect() async {
    ++_generation; // supersede any in-flight connect
    // Force-close every in-flight auth handshake immediately rather than
    // leaving them to run unbounded in the background until the generation
    // check (or the auth timeout) eventually notices they were superseded.
    final pending = [for (final client in _pending) client.close()];
    _pending.clear();
    await Future.wait([...pending, _closeClient()]);
  }

  Future<void> _closeClient() async {
    _health?.stop();
    _health = null;
    _streamHealth?.stop();
    _streamHealth = null;
    _syncHealth?.stop();
    _syncHealth = null;
    _redialTimer?.cancel();
    _redialTimer = null;
    _syncRedialTimer?.cancel();
    _syncRedialTimer = null;
    _redialProfile = null;
    _redialVerify = null;
    _redialFailures = 0;
    _syncRedialFailures = 0;
    _lastDropCause = null;
    _connectedAt = null;
    final cmd = _client;
    final stream = _streamClient;
    final sync = _syncClient;
    _client = null;
    _streamClient = null;
    _syncClient = null;
    _clientGeneration = -1;
    await Future.wait([
      if (cmd != null) cmd.close(),
      if (stream != null && !identical(stream, cmd)) stream.close(),
      if (sync != null && !identical(sync, cmd) && !identical(sync, stream))
        sync.close(),
    ]);
  }
}
