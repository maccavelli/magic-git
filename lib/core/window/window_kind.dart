/// The kinds of secondary (non-main) native window the app can open, each a
/// full second [FlutterEngine]/isolate managed by the native multi-window
/// system (see `SecondaryWindowController.swift` and [WindowManagerBridge]).
///
/// The `.name` of each value is the on-the-wire discriminator shared verbatim
/// with the Swift `WindowKind` enum and carried in the [WindowDescriptor] the
/// child pulls at boot — keep the two in exact sync.
enum WindowKind {
  /// The History pop-out: mirrors the active session's repo and renders the
  /// History view. Singleton — opening it again fronts the existing one.
  history,

  /// A detached full repo view pinned to one `repoPath` (a repo on a second
  /// monitor). Keyed by `(kind, repoPath)` — one per repo. This kind exists to
  /// exercise N>1 independent windows; richer per-repo/worktree kinds build on
  /// the same machinery later.
  detachedRepo;

  /// Parses a wire name back to a kind, defaulting to [history] for an unknown
  /// (version-skewed) discriminator rather than throwing — a missing window
  /// kind should degrade, never crash the child's boot.
  static WindowKind fromName(String? name) =>
      WindowKind.values.asNameMap()[name] ?? WindowKind.history;

  /// Whether at most one window of this kind may exist regardless of repo.
  /// History follows the single active session; repo-bound kinds are deduped
  /// by `(kind, repoPath)` instead (see [WindowManagerBridge]).
  bool get isSingleton => this == WindowKind.history;
}
