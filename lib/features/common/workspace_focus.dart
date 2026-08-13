enum WorkspaceFocusKind {
  repository,
  branch,
  revision,
  range,
  path,
  stash,
  worktree,
  issue,
  request,
  pipeline,
}

/// A semantic location survives page remounts without retaining widget state.
class WorkspaceFocus {
  final String repositoryPath;
  final int sessionEpoch;
  final WorkspaceFocusKind kind;
  final String identity;
  final String? secondaryIdentity;
  final int panelIndex;

  const WorkspaceFocus({
    required this.repositoryPath,
    required this.sessionEpoch,
    required this.kind,
    required this.identity,
    this.secondaryIdentity,
    required this.panelIndex,
  });

  @override
  bool operator ==(Object other) =>
      other is WorkspaceFocus &&
      repositoryPath == other.repositoryPath &&
      sessionEpoch == other.sessionEpoch &&
      kind == other.kind &&
      identity == other.identity &&
      secondaryIdentity == other.secondaryIdentity &&
      panelIndex == other.panelIndex;

  @override
  int get hashCode => Object.hash(
    repositoryPath,
    sessionEpoch,
    kind,
    identity,
    secondaryIdentity,
    panelIndex,
  );
}

class WorkspaceSessionKey {
  final String repositoryPath;
  final int sessionEpoch;
  const WorkspaceSessionKey(this.repositoryPath, this.sessionEpoch);

  @override
  bool operator ==(Object other) =>
      other is WorkspaceSessionKey &&
      repositoryPath == other.repositoryPath &&
      sessionEpoch == other.sessionEpoch;
  @override
  int get hashCode => Object.hash(repositoryPath, sessionEpoch);
}
