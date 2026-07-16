/// The registry of user-resizable master panes: which panes exist, their
/// default widths (today's previously hard-coded constants), and the bounds a
/// stored width is clamped to on both write and load.
///
/// One spec per *kind* of pane, deliberately shared where two views are
/// role-identical: the GitHub and GitLab panels never show together (the
/// Forge tab picks one by remote), so a per-view width would make the "same"
/// pane mysteriously change size when switching between a GitHub repo and a
/// GitLab repo. Likewise the two CI jobs lists.
///
/// Widths persist per [PaneId] under the `paneWidth_<id.name>` preference key
/// (see `AppSettingsNotifier.setPaneWidth`), so enum names are part of the
/// on-disk format — rename one and every user's stored width for that pane
/// silently resets to the default.
library;

enum PaneId {
  /// History tab / pop-out window: the commit list beside the diff pane.
  historyList,

  /// GitHub and GitLab panels: the PR/MR + CI list beside the detail pane.
  forgeList,

  /// Both CI jobs views: the job list beside the log pane.
  jobsList,

  /// Stashes tab: the stash cards beside the preview.
  stashList,

  /// The right-docked Files tree (file_view). Keeps its own drag handle and
  /// relative display clamps; only the chosen width is persisted here.
  filesTree,
}

/// Geometry contract for one resizable pane.
class PaneSpec {
  /// Width when nothing is stored — today's previously fixed constant, so
  /// the feature changes nothing until the user drags.
  final double defaultWidth;

  /// Floor for both storage and display. Chosen per pane so the master's
  /// content stays legible (e.g. the History list keeps room for ref chips —
  /// RefChipStrip's budget is tuned to the 420px pane).
  final double min;

  /// Ceiling for storage. Display may clamp lower still, to leave the detail
  /// pane its floor in a narrow window — that display clamp never writes back.
  final double max;

  const PaneSpec({
    required this.defaultWidth,
    required this.min,
    required this.max,
  }) : assert(min <= defaultWidth && defaultWidth <= max);
}

const paneSpecs = <PaneId, PaneSpec>{
  // min 360: RefChipStrip.maxVisible/maxChipWidth are tuned to the 420px
  // pane (ref_chip.dart) and degrade gracefully down to about this floor.
  PaneId.historyList: PaneSpec(defaultWidth: 420, min: 360, max: 800),
  PaneId.forgeList: PaneSpec(defaultWidth: 360, min: 280, max: 640),
  PaneId.jobsList: PaneSpec(defaultWidth: 240, min: 180, max: 480),
  PaneId.stashList: PaneSpec(defaultWidth: 360, min: 280, max: 640),
  // file_view's own floor is 220 and its ceiling is relative (55% of its
  // host); these bounds only sanitize what lands on disk.
  PaneId.filesTree: PaneSpec(defaultWidth: 280, min: 220, max: 800),
};
