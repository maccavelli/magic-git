import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../git/git_service.dart';
import 'pane_layout.dart';
import 'settings_bus.dart';
import 'tool_catalog.dart';

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

  /// Whether the History diff views wrap long lines to the viewport width.
  /// false (default) keeps one line per source line with a shared horizontal
  /// scrollbar for reaching line ends.
  final bool historyDiffWrap;

  /// Comma-separated globs of **gitignored** files to copy into a newly created
  /// worktree.
  ///
  /// `git worktree add` checks out *tracked* files only, so a fresh worktree has
  /// no `.env` and the project fails on first run with an error that says nothing
  /// about worktrees. This is the same set of patterns nearly every time, so it
  /// is a setting rather than something to retype per worktree. Empty disables
  /// the copy.
  final String worktreeCopyGlobs;

  /// Whether the copy is on by default in the Add Worktree sheet.
  final bool worktreeCopyEnabled;

  /// Command run inside a newly created worktree (e.g. `pnpm install`), so it is
  /// ready to work in rather than ready to configure. Empty = none.
  final String worktreePostCreate;

  /// Whether [worktreePostCreate] runs by default. Kept separate from the string
  /// so a user can park a command without arming it.
  final bool worktreePostCreateEnabled;

  /// The Create Tag sheet's "Annotated tag" default. Defaults true — an
  /// annotated tag carries tagger/date/message, is what `--follow-tags`
  /// pushes, and is the right shape for the release tags the sheet mostly
  /// creates. Persisted from the sheet's last use, like the worktree
  /// defaults.
  final bool tagAnnotatedByDefault;

  /// The Create Tag sheet's "Push to remote after creating" default. Defaults
  /// true: `git push` not sending tags is the single most surprising thing
  /// about them, and a tag that silently stays local is the failure this
  /// whole sheet exists to prevent.
  final bool tagPushAfterCreate;

  /// Whether the History panel defaults to showing all branches (`--all`).
  /// true (default) displays all branch tips and cut/merged branches; false
  /// narrows history to the active branch (HEAD).
  final bool historyAllBranches;

  /// User-chosen widths for the resizable master panes, keyed by [PaneId].
  /// Absent = the pane's [PaneSpec.defaultWidth] (see [paneWidth]). Values
  /// are clamped to the pane's spec bounds on both write and load.
  final Map<PaneId, double> paneWidths;

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
    this.historyDiffWrap = false,
    this.historyAllBranches = true,
    this.worktreeCopyGlobs = '.env*',
    this.worktreeCopyEnabled = true,
    this.worktreePostCreate = '',
    this.worktreePostCreateEnabled = false,
    this.tagAnnotatedByDefault = true,
    this.tagPushAfterCreate = true,
    this.paneWidths = const {},
  });

  /// The effective width for [id]: the stored value, else the spec default.
  double paneWidth(PaneId id) => paneWidths[id] ?? paneSpecs[id]!.defaultWidth;

  /// The stored width for [id], or null when the user never chose one — for
  /// panes whose fallback is layout-relative (file_view's `maxWidth / 4`)
  /// rather than the spec default.
  double? paneWidthOrNull(PaneId id) => paneWidths[id];

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
    bool? historyDiffWrap,
    bool? historyAllBranches,
    String? worktreeCopyGlobs,
    bool? worktreeCopyEnabled,
    String? worktreePostCreate,
    bool? worktreePostCreateEnabled,
    bool? tagAnnotatedByDefault,
    bool? tagPushAfterCreate,
    Map<PaneId, double>? paneWidths,
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
    historyDiffWrap: historyDiffWrap ?? this.historyDiffWrap,
    historyAllBranches: historyAllBranches ?? this.historyAllBranches,
    worktreeCopyGlobs: worktreeCopyGlobs ?? this.worktreeCopyGlobs,
    worktreeCopyEnabled: worktreeCopyEnabled ?? this.worktreeCopyEnabled,
    worktreePostCreate: worktreePostCreate ?? this.worktreePostCreate,
    worktreePostCreateEnabled:
        worktreePostCreateEnabled ?? this.worktreePostCreateEnabled,
    tagAnnotatedByDefault: tagAnnotatedByDefault ?? this.tagAnnotatedByDefault,
    tagPushAfterCreate: tagPushAfterCreate ?? this.tagPushAfterCreate,
    paneWidths: paneWidths ?? this.paneWidths,
  );

  // Value equality so a cross-tab [reloadFromDisk] that re-reads the same value
  // is a no-op (no listener churn, clean echo-termination) — and so unrelated
  // settings mutations don't rebuild value-equal consumers.
  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.networkTimeout == networkTimeout &&
      other.commitTimeout == commitTimeout &&
      other.committerName == committerName &&
      other.committerEmail == committerEmail &&
      other.defaultPullMode == defaultPullMode &&
      other.pushFollowTags == pushFollowTags &&
      other.autoFetchMinutes == autoFetchMinutes &&
      other.historyZoom == historyZoom &&
      other.historyDiffWrap == historyDiffWrap &&
      other.historyAllBranches == historyAllBranches &&
      other.worktreeCopyGlobs == worktreeCopyGlobs &&
      other.worktreeCopyEnabled == worktreeCopyEnabled &&
      other.worktreePostCreate == worktreePostCreate &&
      other.worktreePostCreateEnabled == worktreePostCreateEnabled &&
      other.tagAnnotatedByDefault == tagAnnotatedByDefault &&
      other.tagPushAfterCreate == tagPushAfterCreate &&
      _mapEquals(other.binaryOverrides, binaryOverrides) &&
      _mapEquals(other.paneWidths, paneWidths);

  @override
  int get hashCode => Object.hash(
    networkTimeout,
    commitTimeout,
    committerName,
    committerEmail,
    defaultPullMode,
    pushFollowTags,
    autoFetchMinutes,
    historyZoom,
    historyDiffWrap,
    historyAllBranches,
    worktreeCopyGlobs,
    worktreeCopyEnabled,
    worktreePostCreate,
    worktreePostCreateEnabled,
    tagAnnotatedByDefault,
    tagPushAfterCreate,
    Object.hashAllUnordered(
      binaryOverrides.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      paneWidths.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  static bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }
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
  static const _historyDiffWrapKey = 'historyDiffWrap';
  static const _historyAllBranchesKey = 'historyAllBranches';
  static const _wtCopyGlobsKey = 'worktreeCopyGlobs';
  static const _wtCopyEnabledKey = 'worktreeCopyEnabled';
  static const _wtPostCreateKey = 'worktreePostCreate';
  static const _wtPostCreateEnabledKey = 'worktreePostCreateEnabled';
  static const _tagAnnotatedKey = 'tagAnnotatedByDefault';
  static const _tagPushAfterCreateKey = 'tagPushAfterCreate';

  /// Per-pane width keys: `paneWidth_<PaneId.name>` (mirrors [_binPrefix]).
  /// Enum names are part of the on-disk format — see pane_layout.dart.
  static const _paneWidthPrefix = 'paneWidth_';

  /// Set true by any setter the moment the user explicitly changes a setting.
  /// [build] kicks [_load] fire-and-forget and returns defaults immediately, so
  /// a user mutation can land before the async on-disk read resolves; when that
  /// happens [_load] must not clobber the just-made edit with the stale stored
  /// value. Sticky (never reset), so every disk read [_load] issues defers to a
  /// prior edit. Guards ONLY the initial-load race — cross-isolate syncs use
  /// [_pendingWrites] instead so a once-edited isolate still accepts later
  /// disk updates.
  bool _userEdited = false;

  /// Count of setter disk writes currently in flight. A [reloadFromDisk] (an
  /// explicit cross-isolate sync) reads the on-disk snapshot, which is stale
  /// for the value a local write hasn't yet flushed — so while any write is
  /// pending, the reload defers rather than snapping that value back (e.g. a
  /// zoom gesture mid-write, or an in-flight Settings-sheet save).
  int _pendingWrites = 0;

  /// Binaries the user may override a path for — [kOverridableBinaries], which
  /// is derived from the tool catalog. Kept as an alias so the persisted-key
  /// loops below read in terms of settings, but it is not a second list: a tool
  /// added to the catalog becomes overridable here, probed on the host, and
  /// shown in the doctor, all from that one edit.
  static List<String> get overridableBinaries => kOverridableBinaries;

  @override
  AppSettings build() {
    _load();
    // Cross-tab sync: another tab's write (each tab is its own container with
    // its own notifier) reloads this one from disk. Reload never re-broadcasts,
    // so there is no ping-pong; a value-equal reload is a no-op via AppSettings
    // value equality.
    final sub = SettingsBus.instance.onSettingsWritten.listen(
      (_) => reloadFromDisk(),
    );
    ref.onDispose(sub.cancel);
    return const AppSettings();
  }

  Future<void> _load() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return; // storage unavailable (e.g. no platform binding) — keep defaults
    }
    // Initial-load race: honor a user edit that landed while we read disk
    // rather than overwriting it with the now-stale stored snapshot. Also abort
    // if the provider was disposed across the async gap (e.g. a tab closed).
    _applyFromPrefs(prefs, abort: () => _userEdited || !ref.mounted);
  }

  /// Folds the persisted values from [prefs] into [state]. [abort] is consulted
  /// immediately before the (synchronous) assignment; because the prefs reads
  /// don't await, no setter can interleave between the check and the write —
  /// so a false abort at this instant means it is genuinely safe to apply.
  void _applyFromPrefs(
    SharedPreferences prefs, {
    required bool Function() abort,
  }) {
    final n = prefs.getInt(_networkKey);
    final c = prefs.getInt(_commitKey);
    final pull = prefs.getInt(_pullModeKey);
    final overrides = <String, String>{};
    for (final bin in overridableBinaries) {
      final v = prefs.getString('$_binPrefix$bin');
      if (v != null && v.trim().isNotEmpty) overrides[bin] = v.trim();
    }
    // Clamp-on-load sanitizes a corrupted/out-of-range stored width without
    // writing back — disk stays untouched until the user next drags.
    final paneWidths = <PaneId, double>{};
    for (final MapEntry(key: id, value: spec) in paneSpecs.entries) {
      final w = prefs.getDouble('$_paneWidthPrefix${id.name}');
      if (w != null) paneWidths[id] = w.clamp(spec.min, spec.max).toDouble();
    }
    if (abort()) return;
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
      paneWidths: paneWidths,
      historyZoom: prefs
          .getDouble(_historyZoomKey)
          ?.clamp(minHistoryZoom, maxHistoryZoom)
          .toDouble(),
      historyDiffWrap: prefs.getBool(_historyDiffWrapKey),
      historyAllBranches: prefs.getBool(_historyAllBranchesKey),
      worktreeCopyGlobs: prefs.getString(_wtCopyGlobsKey),
      worktreeCopyEnabled: prefs.getBool(_wtCopyEnabledKey),
      worktreePostCreate: prefs.getString(_wtPostCreateKey),
      worktreePostCreateEnabled: prefs.getBool(_wtPostCreateEnabledKey),
      tagAnnotatedByDefault: prefs.getBool(_tagAnnotatedKey),
      tagPushAfterCreate: prefs.getBool(_tagPushAfterCreateKey),
    );
  }

  /// Re-reads settings that ANOTHER isolate persisted. Each isolate's
  /// SharedPreferences caches the on-disk map at first read, so the native
  /// History window's engine never sees main-window edits without an explicit
  /// `reload()`. Called from its `settingsChanged` hub event.
  ///
  /// The History window DOES make local edits (the zoom gestures write
  /// `historyZoom` from either isolate), so this can't blindly trust disk: a
  /// reload racing an in-flight local write would read the pre-write value and
  /// snap it back. [_pendingWrites] gates that — while a write is in flight the
  /// local value is authoritative and the reload defers. (A genuinely
  /// concurrent remote change is then briefly missed here until the next
  /// settingsChanged, a far smaller cost than reverting the user's live edit.)
  Future<void> reloadFromDisk() async {
    if (_pendingWrites > 0) return;
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      await prefs.reload();
    } catch (_) {
      return; // storage unavailable — keep what we have
    }
    // Guard the disposed-across-the-gap case too — this now fires on every
    // cross-tab settings write, so a tab that closed mid-reload must not assign.
    _applyFromPrefs(prefs, abort: () => _pendingWrites > 0 || !ref.mounted);
  }

  /// Runs a batch of setter disk writes with [_pendingWrites] held up for the
  /// whole batch, so a concurrent [reloadFromDisk] defers to it.
  Future<void> _persist(
    Future<void> Function(SharedPreferences prefs) writes,
  ) async {
    _pendingWrites++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await writes(prefs);
    } finally {
      _pendingWrites--;
    }
    // Tell sibling tabs (and, via the root notifier's listener, the native
    // History window) to reload. Fired after the write is flushed and the
    // pending-guard released, so this notifier's own reload defers correctly.
    SettingsBus.instance.notifySettingsWritten();
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
    await _persist((prefs) async {
      await prefs.setInt(_networkKey, state.networkTimeout.inSeconds);
      await prefs.setInt(_commitKey, state.commitTimeout.inSeconds);
    });
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
    await _persist((prefs) async {
      await prefs.setString(_nameKey, state.committerName);
      await prefs.setString(_emailKey, state.committerEmail);
      await prefs.setInt(_pullModeKey, state.defaultPullMode.index);
      await prefs.setBool(_followTagsKey, state.pushFollowTags);
      await prefs.setInt(_autoFetchKey, state.autoFetchMinutes);
    });
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
    await _persist((prefs) async {
      for (final bin in overridableBinaries) {
        final v = cleaned[bin];
        if (v == null) {
          await prefs.remove('$_binPrefix$bin');
        } else {
          await prefs.setString('$_binPrefix$bin', v);
        }
      }
    });
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
    await _persist((prefs) => prefs.setDouble(_historyZoomKey, clamped));
  }

  /// Updates and persists the width of a resizable master pane, clamped to
  /// its [PaneSpec] bounds. Called once per completed drag (never per frame)
  /// and by the divider's double-click reset.
  Future<void> setPaneWidth(PaneId id, double width) async {
    final spec = paneSpecs[id]!;
    final clamped = width.clamp(spec.min, spec.max).toDouble();
    // Compare the RAW map entry, not paneWidth(id): the first explicit
    // reset-to-default must still persist (an absent entry merely *renders*
    // as the default; after a reset it should be stored).
    if (clamped == state.paneWidths[id]) return;
    _userEdited = true;
    state = state.copyWith(paneWidths: {...state.paneWidths, id: clamped});
    await _persist(
      (prefs) => prefs.setDouble('$_paneWidthPrefix${id.name}', clamped),
    );
  }

  /// Toggles and persists whether History diff views wrap long lines. Shared
  /// by both windows — the sync path is the same as [setHistoryZoom]'s.
  Future<void> setHistoryDiffWrap(bool wrap) async {
    if (wrap == state.historyDiffWrap) return;
    _userEdited = true;
    state = state.copyWith(historyDiffWrap: wrap);
    await _persist((prefs) => prefs.setBool(_historyDiffWrapKey, wrap));
  }

  /// Toggles and persists whether History defaults to showing all branches (`--all`).
  Future<void> setHistoryAllBranches(bool all) async {
    if (all == state.historyAllBranches) return;
    _userEdited = true;
    state = state.copyWith(historyAllBranches: all);
    await _persist((prefs) => prefs.setBool(_historyAllBranchesKey, all));
  }

  /// Persists the Add Worktree sheet's defaults, so the same `.env*` globs and
  /// the same `pnpm install` don't have to be retyped for every worktree — the
  /// answer is the same nearly every time, and per-worktree friction is exactly
  /// what makes the feature feel like a chore.
  Future<void> setWorktreeDefaults({
    String? copyGlobs,
    bool? copyEnabled,
    String? postCreate,
    bool? postCreateEnabled,
  }) async {
    _userEdited = true;
    state = state.copyWith(
      worktreeCopyGlobs: copyGlobs?.trim(),
      worktreeCopyEnabled: copyEnabled,
      worktreePostCreate: postCreate?.trim(),
      worktreePostCreateEnabled: postCreateEnabled,
    );
    await _persist((prefs) async {
      await prefs.setString(_wtCopyGlobsKey, state.worktreeCopyGlobs);
      await prefs.setBool(_wtCopyEnabledKey, state.worktreeCopyEnabled);
      await prefs.setString(_wtPostCreateKey, state.worktreePostCreate);
      await prefs.setBool(
        _wtPostCreateEnabledKey,
        state.worktreePostCreateEnabled,
      );
    });
  }

  /// Persists the Create Tag sheet's defaults — the same rationale as
  /// [setWorktreeDefaults]: the answer to "annotated?" and "push it?" is the
  /// same nearly every time, so the sheet remembers its last use instead of
  /// asking again.
  Future<void> setTagDefaults({bool? annotated, bool? pushAfterCreate}) async {
    _userEdited = true;
    state = state.copyWith(
      tagAnnotatedByDefault: annotated,
      tagPushAfterCreate: pushAfterCreate,
    );
    await _persist((prefs) async {
      await prefs.setBool(_tagAnnotatedKey, state.tagAnnotatedByDefault);
      await prefs.setBool(_tagPushAfterCreateKey, state.tagPushAfterCreate);
    });
  }

  /// The context width the History diffs fetch at (`-U3`, git's own default).
  /// Fixed rather than user-tunable: the viewer reveals more context inline,
  /// per hunk, by reading the file's blob — see `patch_model.dart`. The value
  /// still has to be *known*, because the gaps between hunks are computed from
  /// the hunk headers this produces.
  static const int defaultDiffContext = 3;

  static const _minTimeout = Duration(seconds: 5);

  /// Ceiling for [AppSettings.autoFetchMinutes] — 24h. Beyond a day, "periodic
  /// background fetch" isn't meaningfully doing its job anyway.
  static const _maxAutoFetchMinutes = 1440;
}

final appSettingsProvider = NotifierProvider<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
);
