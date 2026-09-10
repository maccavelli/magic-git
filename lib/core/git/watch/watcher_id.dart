/// Which watcher a diagnostic record came from.
///
/// MADR 0043's investigation turned on reading two records as adjacent when
/// nothing said whether they came from the same watcher (MADR 0045 F9). Every
/// arm already had a token; this carries it, with the session and the attempt,
/// to the record.
final class WatcherId {
  const WatcherId({
    required this.sessionId,
    required this.repoPath,
    required this.attempt,
    this.token,
  });

  /// The session — one tab's container — the watcher belongs to.
  final String sessionId;
  final String repoPath;

  /// Which arm attempt of this watcher, counting from one.
  final int attempt;

  /// The host-side lease token, for a remote arm; null for a local one.
  final String? token;

  @override
  bool operator ==(Object other) =>
      other is WatcherId &&
      other.sessionId == sessionId &&
      other.repoPath == repoPath &&
      other.attempt == attempt &&
      other.token == token;

  @override
  int get hashCode => Object.hash(sessionId, repoPath, attempt, token);

  @override
  String toString() =>
      token == null ? '$sessionId/$attempt' : '$sessionId/$attempt/$token';
}
