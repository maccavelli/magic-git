import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class CommitAssistanceKey {
  final String repoPath;
  final int sessionEpoch;

  const CommitAssistanceKey(this.repoPath, this.sessionEpoch);

  @override
  bool operator ==(Object other) =>
      other is CommitAssistanceKey &&
      other.repoPath == repoPath &&
      other.sessionEpoch == sessionEpoch;

  @override
  int get hashCode => Object.hash(repoPath, sessionEpoch);
}

@immutable
class CommitCoAuthor {
  final String name;
  final String email;

  const CommitCoAuthor({required this.name, required this.email});

  String get trailer => 'Co-authored-by: $name <$email>';

  static CommitCoAuthor? validated(String rawName, String rawEmail) {
    if (rawName.contains(RegExp(r'[\r\n<>]')) ||
        rawEmail.contains(RegExp(r'[\r\n<>]'))) {
      return null;
    }
    final name = rawName.trim().replaceAll(RegExp(r'\s+'), ' ');
    final email = rawEmail.trim().toLowerCase();
    if (name.isEmpty) return null;
    if (!RegExp(r'^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$').hasMatch(email)) {
      return null;
    }
    return CommitCoAuthor(name: name, email: email);
  }

  @override
  bool operator ==(Object other) =>
      other is CommitCoAuthor && other.name == name && other.email == email;

  @override
  int get hashCode => Object.hash(name, email);
}

/// Appends validated co-author trailers in insertion order, separated from the
/// body by exactly one blank line. Existing trailer emails suppress duplicates.
String composeCommitMessage(String body, Iterable<CommitCoAuthor> coAuthors) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '';
  final existingEmails = <String>{};
  final trailerPattern = RegExp(
    r'^Co-authored-by:\s*.+<([^<>\s]+@[^<>\s]+)>\s*$',
    caseSensitive: false,
    multiLine: true,
  );
  for (final match in trailerPattern.allMatches(trimmed)) {
    existingEmails.add(match.group(1)!.toLowerCase());
  }
  final trailers = <String>[];
  for (final author in coAuthors) {
    if (existingEmails.add(author.email.toLowerCase())) {
      trailers.add(author.trailer);
    }
  }
  if (trailers.isEmpty) return trimmed;
  final matches = trailerPattern.allMatches(trimmed).toList();
  final separator = matches.isNotEmpty && matches.last.end == trimmed.length
      ? '\n'
      : '\n\n';
  return '$trimmed$separator${trailers.join('\n')}';
}

/// Passive repository cache populated only by History after its own log has
/// landed. Reading it from the composer never starts a Git command.
class LandedCommitSubjects extends Notifier<List<String>> {
  LandedCommitSubjects(this.key);

  final CommitAssistanceKey key;

  @override
  List<String> build() => const [];

  void publish(Iterable<String> subjects) {
    final unique = <String>[];
    final seen = <String>{};
    for (final subject in subjects) {
      final value = subject.trim();
      if (value.isNotEmpty && seen.add(value)) unique.add(value);
      if (unique.length == 10) break;
    }
    state = List.unmodifiable(unique);
  }
}

final landedCommitSubjectsProvider =
    NotifierProvider.family<
      LandedCommitSubjects,
      List<String>,
      CommitAssistanceKey
    >(LandedCommitSubjects.new);
