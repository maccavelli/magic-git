/// The Forge workspace's detail-pane subject, shared by the GitHub and GitLab
/// panels: nothing, one selected item (by its forge-native id), or one of the
/// inline create forms. A sealed union rather than parallel nullable ints so
/// exactly one subject can exist at a time and `switch` exhaustiveness keeps
/// every detail renderer honest.
library;

sealed class ForgeSel {
  const ForgeSel();
}

class ForgeNothingSel extends ForgeSel {
  const ForgeNothingSel();
}

/// A merge request (GitLab `iid`) or pull request (GitHub `number`).
class ForgeChangeRequestSel extends ForgeSel {
  final int id;
  const ForgeChangeRequestSel(this.id);
}

/// A pipeline (GitLab) or workflow run (GitHub) by its id.
class ForgeCiRunSel extends ForgeSel {
  final int id;
  const ForgeCiRunSel(this.id);
}

class ForgeIssueSel extends ForgeSel {
  final int id;
  const ForgeIssueSel(this.id);
}

class ForgeMilestoneSel extends ForgeSel {
  final int id;
  const ForgeMilestoneSel(this.id);
}

/// A published release, keyed by tag name (stable across forges).
class ForgeReleaseSel extends ForgeSel {
  final String tagName;
  const ForgeReleaseSel(this.tagName);
}

/// The inline "New Issue" form.
class ForgeCreatingIssue extends ForgeSel {
  const ForgeCreatingIssue();
}

/// The inline "New MR/PR" form. [seedSource] pre-fills the source/head branch
/// (a branch dropped on the Forge nav item or Branches Create action); null
/// prefills from HEAD. [seedBase] pre-fills the base/target forge branch name
/// (`main`, never `origin/main`); null leaves the form default.
class ForgeCreatingChangeRequest extends ForgeSel {
  final String? seedSource;
  final String? seedBase;
  const ForgeCreatingChangeRequest({this.seedSource, this.seedBase});
}

/// Whether [sel] is one of the inline create forms (the ones whose unsaved
/// draft a row click or tab-away must not silently destroy).
bool isForgeCreateSel(ForgeSel sel) =>
    sel is ForgeCreatingIssue || sel is ForgeCreatingChangeRequest;
