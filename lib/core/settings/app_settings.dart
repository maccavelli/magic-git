import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../git/git_service.dart';

/// User-tunable knobs persisted across sessions:
///  * the two generous per-command timeouts, so a legitimately slow push/commit
///    on a slow link isn't killed as if it had hung;
///  * a committer identity applied to every commit (so commits are authored
///    correctly regardless of the remote host's git config);
///  * default sync behavior (pull mode + whether to push tags);
///  * an optional background auto-fetch interval.
class AppSettings {
  final Duration networkTimeout; // fetch / pull / push
  final Duration commitTimeout; // commit (may fire a slow AI hook)

  /// Applied as `-c user.name/-c user.email` on every commit. Empty = unset
  /// (git uses the remote host's own config, the prior behavior).
  final String committerName;
  final String committerEmail;

  /// What the plain Pull button / Sync do by default.
  final PullMode defaultPullMode;

  /// Whether a plain Push also pushes annotated tags (`--follow-tags`).
  final bool pushFollowTags;

  /// Background fetch interval in minutes; 0 disables auto-fetch. Defaults to
  /// every 5 minutes — frequent enough to keep ahead/behind honest for
  /// passive awareness of a teammate's pushes, infrequent enough to not spam
  /// the SSH link. [ConnectionController.fetchInBackground] already covers
  /// the more common "did I just fall behind" moment (right after a commit),
  /// so this interval only needs to catch the case where nothing local
  /// happened for a while.
  final int autoFetchMinutes;

  /// Optional absolute-path overrides for external binaries, keyed by tool name
  /// (`git`, `glab`, `gh`, `fswatch`, `inotifywait`). Empty = auto-discover.
  /// These win over discovery when resolving the remote environment.
  final Map<String, String> binaryOverrides;

  /// Scale factor for the History commit list (row height, graph geometry,
  /// and text together). 1.0 = default density; clamped to
  /// [AppSettingsNotifier.minHistoryZoom]–[AppSettingsNotifier.maxHistoryZoom].
  final double historyZoom;

  const AppSettings({
    this.networkTimeout = GitService.defaultNetworkTimeout,
    this.commitTimeout = GitService.defaultCommitTimeout,
    this.committerName = '',
    this.committerEmail = '',
    this.defaultPullMode = PullMode.ffOnly,
    this.pushFollowTags = false,
    this.autoFetchMinutes = 5,
    this.binaryOverrides = const {},
    this.historyZoom = 1.0,
  });

  AppSettings copyWith({
    Duration? networkTimeout,
    Duration? commitTimeout,
    String? committerName,
    String? committerEmail,
    PullMode? defaultPullMode,
    bool? pushFollowTags,
    int? autoFetchMinutes,
    Map<String, String>? binaryOverrides,
    double? historyZoom,
  }) => AppSettings(
    networkTimeout: networkTimeout ?? this.networkTimeout,
    commitTimeout: commitTimeout ?? this.commitTimeout,
    committerName: committerName ?? this.committerName,
    committerEmail: committerEmail ?? this.committerEmail,
    defaultPullMode: defaultPullMode ?? this.defaultPullMode,
    pushFollowTags: pushFollowTags ?? this.pushFollowTags,
    autoFetchMinutes: autoFetchMinutes ?? this.autoFetchMinutes,
    binaryOverrides: binaryOverrides ?? this.binaryOverrides,
    historyZoom: historyZoom ?? this.historyZoom,
  );
}

/// Loads settings from [SharedPreferences] (async, after construction) and
/// persists changes. Starts at defaults so consumers never block on disk; the
/// stored values fold in once loaded, rebuilding dependents (e.g.
/// `gitServiceProvider`).
class AppSettingsNotifier extends Notifier<AppSettings> {
  static const _networkKey = 'networkTimeoutSecs';
  static const _commitKey = 'commitTimeoutSecs';
  static const _nameKey = 'committerName';
  static const _emailKey = 'committerEmail';
  static const _pullModeKey = 'defaultPullMode';
  static const _followTagsKey = 'pushFollowTags';
  static const _autoFetchKey = 'autoFetchMinutes';
  static const _binPrefix = 'binPath_';
  static const _historyZoomKey = 'historyZoom';

  /// Set true by any setter the moment the user explicitly changes a setting.
  /// [build] kicks [_load] fire-and-forget and returns defaults immediately, so
  /// a user mutation can land before the async on-disk read resolves; when that
  /// happens [_load] must not clobber the just-made edit with the stale stored
  /// value. Checked right before [_load]'s state assignment.
  bool _userEdited = false;

  /// Binaries the user may override a path for.
  static const List<String> overridableBinaries = [
    'git',
    'glab',
    'gh',
    'fswatch',
    'inotifywait',
  ];

  @override
  AppSettings build() {
    _load();
    return const AppSettings();
  }

  Future<void> _load() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return; // storage unavailable (e.g. no platform binding) — keep defaults
    }
    final n = prefs.getInt(_networkKey);
    final c = prefs.getInt(_commitKey);
    final pull = prefs.getInt(_pullModeKey);
    final overrides = <String, String>{};
    for (final bin in overridableBinaries) {
      final v = prefs.getString('$_binPrefix$bin');
      if (v != null && v.trim().isNotEmpty) overrides[bin] = v.trim();
    }
    // A user edit landed while we were reading from disk — honor it rather than
    // overwriting it with the now-stale stored snapshot.
    if (_userEdited) return;
    state = state.copyWith(
      networkTimeout: n != null ? _floorTimeout(Duration(seconds: n)) : null,
      commitTimeout: c != null ? _floorTimeout(Duration(seconds: c)) : null,
      committerName: prefs.getString(_nameKey),
      committerEmail: prefs.getString(_emailKey),
      defaultPullMode: pull != null && pull >= 0 && pull < PullMode.values.length
          ? PullMode.values[pull]
          : null,
      pushFollowTags: prefs.getBool(_followTagsKey),
      autoFetchMinutes: prefs
          .getInt(_autoFetchKey)
          ?.clamp(0, _maxAutoFetchMinutes),
      binaryOverrides: overrides,
      historyZoom: prefs
          .getDouble(_historyZoomKey)
          ?.clamp(minHistoryZoom, maxHistoryZoom)
          .toDouble(),
    );
  }

  /// Re-reads settings that ANOTHER isolate persisted. Each isolate's
  /// SharedPreferences caches the on-disk map at first read, so the native
  /// History window's engine never sees main-window edits without an explicit
  /// `reload()`. Called from its `settingsChanged` hub event.
  Future<void> reloadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
    } catch (_) {
      return; // storage unavailable — keep what we have
    }
    // No settings UI exists in the History window, so a pending local edit
    // can't be clobbered here — the on-disk state is authoritative.
    _userEdited = false;
    await _load();
  }

  /// Floors a timeout to [_minTimeout] so a 0-second (or negative) value —
  /// user-set or a corrupted/stale stored value — never kills every command.
  static Duration _floorTimeout(Duration d) => d < _minTimeout ? _minTimeout : d;

  /// Updates the timeouts and persists them. Values are clamped to a sane floor
  /// so a user can't set a 0-second timeout that kills every command.
  Future<void> setTimeouts({Duration? network, Duration? commit}) async {
    _userEdited = true;
    Duration? floor(Duration? d) => d == null ? null : _floorTimeout(d);
    state = state.copyWith(
      networkTimeout: floor(network),
      commitTimeout: floor(commit),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_networkKey, state.networkTimeout.inSeconds);
    await prefs.setInt(_commitKey, state.commitTimeout.inSeconds);
  }

  /// Updates and persists the committer identity, sync defaults, and auto-fetch
  /// interval. Names/emails are trimmed; the interval is clamped to sane bounds
  /// (0 = off, capped at [_maxAutoFetchMinutes]).
  Future<void> setPreferences({
    String? committerName,
    String? committerEmail,
    PullMode? defaultPullMode,
    bool? pushFollowTags,
    int? autoFetchMinutes,
  }) async {
    _userEdited = true;
    state = state.copyWith(
      committerName: committerName?.trim(),
      committerEmail: committerEmail?.trim(),
      defaultPullMode: defaultPullMode,
      pushFollowTags: pushFollowTags,
      // Clamp to a floor of 0 (off) *and* a ceiling: a runaway value (fat-
      // fingered, or a corrupt import) shouldn't schedule a fetch years out.
      autoFetchMinutes: autoFetchMinutes?.clamp(0, _maxAutoFetchMinutes),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, state.committerName);
    await prefs.setString(_emailKey, state.committerEmail);
    await prefs.setInt(_pullModeKey, state.defaultPullMode.index);
    await prefs.setBool(_followTagsKey, state.pushFollowTags);
    await prefs.setInt(_autoFetchKey, state.autoFetchMinutes);
  }

  /// Updates and persists the external-binary path overrides. Blank entries are
  /// dropped (revert to auto-discovery).
  Future<void> setBinaryOverrides(Map<String, String> overrides) async {
    _userEdited = true;
    final cleaned = <String, String>{
      for (final e in overrides.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    };
    state = state.copyWith(binaryOverrides: cleaned);
    final prefs = await SharedPreferences.getInstance();
    for (final bin in overridableBinaries) {
      final v = cleaned[bin];
      if (v == null) {
        await prefs.remove('$_binPrefix$bin');
      } else {
        await prefs.setString('$_binPrefix$bin', v);
      }
    }
  }

  /// Bounds for [AppSettings.historyZoom]: 60% keeps rows tappable and text
  /// legible; 200% doubles everything without degenerate layouts.
  static const double minHistoryZoom = 0.6;
  static const double maxHistoryZoom = 2.0;

  /// Updates and persists the History-list zoom factor. Called from rapid
  /// gestures (⌘-scroll, pinch), so it early-returns when clamping produces
  /// no change — no state churn or prefs writes while pinned at a bound.
  Future<void> setHistoryZoom(double zoom) async {
    final clamped = zoom.clamp(minHistoryZoom, maxHistoryZoom).toDouble();
    if (clamped == state.historyZoom) return;
    _userEdited = true;
    state = state.copyWith(historyZoom: clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_historyZoomKey, clamped);
  }

  static const _minTimeout = Duration(seconds: 5);

  /// Ceiling for [AppSettings.autoFetchMinutes] — 24h. Beyond a day, "periodic
  /// background fetch" isn't meaningfully doing its job anyway.
  static const _maxAutoFetchMinutes = 1440;
}

final appSettingsProvider = NotifierProvider<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
);
