import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/git/git_service.dart' show PendingOp;
import '../../core/providers/app_providers.dart';
import '../../core/utils/display_error.dart';
import '../common/commit_assistance.dart';

@immutable
class CommitComposerKey {
  final String repoPath;
  final int sessionEpoch;

  const CommitComposerKey(this.repoPath, this.sessionEpoch);

  @override
  bool operator ==(Object other) =>
      other is CommitComposerKey &&
      other.repoPath == repoPath &&
      other.sessionEpoch == sessionEpoch;

  @override
  int get hashCode => Object.hash(repoPath, sessionEpoch);
}

@immutable
class CommitComposerOutcome {
  final bool localCommitted;
  final bool? pushSucceeded;
  final bool duplicateIgnored;

  const CommitComposerOutcome({
    required this.localCommitted,
    this.pushSucceeded,
    this.duplicateIgnored = false,
  });
}

class CommitComposerController extends ChangeNotifier {
  CommitComposerController({
    required String repoPath,
    required Future<String?> Function() generatePreview,
    required Future<bool> Function() loadGpgSignConfigured,
    Future<List<String>> Function()? loadRecentSubjects,
    Future<String?> Function()? loadTemplate,
    Future<String?> Function()? loadPendingMessage,
  }) : this._(
         repoPath: repoPath,
         generatePreview: generatePreview,
         loadGpgSignConfigured: loadGpgSignConfigured,
         loadRecentSubjects: loadRecentSubjects ?? (() async => const []),
         loadTemplate: loadTemplate ?? (() async => null),
         loadPendingMessage: loadPendingMessage ?? (() async => null),
       );

  CommitComposerController._({
    required this.repoPath,
    required this._generatePreview,
    required this._loadGpgSignConfigured,
    required this._loadRecentSubjects,
    required this._loadTemplate,
    required this._loadPendingMessage,
  });

  final String repoPath;
  final Future<String?> Function() _generatePreview;
  final Future<bool> Function() _loadGpgSignConfigured;
  final Future<List<String>> Function() _loadRecentSubjects;
  final Future<String?> Function() _loadTemplate;

  /// Git's own prepared message for a paused merge/cherry-pick/revert/rebase
  /// (`MERGE_MSG` / `rebase-merge/message`), or null when nothing is pending.
  /// When present it wins over generation in [ensurePreview] — committing a
  /// resolved merge should carry the merge message, not an AI summary
  /// (0009 M14).
  final Future<String?> Function() _loadPendingMessage;
  final Set<String> _previewedSignatures = {};
  bool _disposed = false;

  String message = '';
  String stagedSignature = '';
  int stagedCount = 0;
  bool expanded = false;
  bool loadingPreview = false;
  bool generated = false;
  bool editable = true;
  bool previewStale = false;
  bool committing = false;
  bool gpgDisclosureLoaded = false;
  bool gpgSignConfigured = false;
  bool assistanceExpanded = false;
  bool loadingRecentSubjects = false;
  bool loadingTemplate = false;
  bool templateLoaded = false;
  String? template;
  List<String> recentSubjects = const [];
  List<CommitCoAuthor> coAuthors = const [];
  String? error;

  bool get canAccept =>
      stagedCount > 0 && !committing && message.trim().isNotEmpty;

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void updateStaged({required int count, required String signature}) {
    if (stagedCount == count && stagedSignature == signature) return;
    final changed = stagedSignature.isNotEmpty && stagedSignature != signature;
    stagedCount = count;
    stagedSignature = signature;
    if (changed && message.isNotEmpty && generated) previewStale = true;
    notifyListeners();
  }

  void expand() {
    if (!expanded) {
      expanded = true;
      notifyListeners();
    }
    ensurePrepared();
  }

  void collapse() {
    if (committing || !expanded) return;
    expanded = false;
    notifyListeners();
  }

  void updateMessage(String next, {bool userInitiated = true}) {
    if (message == next) return;
    message = next;
    error = null;
    if (userInitiated) {
      editable = true;
      previewStale = false;
      _previewedSignatures.remove(stagedSignature);
    }
    notifyListeners();
  }

  void beginEdit() {
    editable = true;
    _previewedSignatures.remove(stagedSignature);
    notifyListeners();
  }

  void clearDraft() {
    message = '';
    coAuthors = const [];
    generated = false;
    editable = true;
    previewStale = false;
    error = null;
    _previewedSignatures.clear();
    notifyListeners();
  }

  void toggleAssistance() {
    assistanceExpanded = !assistanceExpanded;
    notifyListeners();
  }

  void publishLandedSubjects(List<String> subjects) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final subject in subjects) {
      final value = subject.trim();
      if (value.isNotEmpty && seen.add(value)) normalized.add(value);
      if (normalized.length == 10) break;
    }
    if (listEquals(recentSubjects, normalized)) return;
    recentSubjects = List.unmodifiable(normalized);
    _notifyListeners();
  }

  Future<void> loadRecentSubjects() async {
    if (loadingRecentSubjects) return;
    loadingRecentSubjects = true;
    error = null;
    _notifyListeners();
    try {
      final loaded = await _loadRecentSubjects();
      publishLandedSubjects(loaded);
    } catch (caught) {
      error = 'Could not load recent commit subjects.\n${displayError(caught)}';
    } finally {
      loadingRecentSubjects = false;
      _notifyListeners();
    }
  }

  Future<void> loadTemplate() async {
    if (loadingTemplate || templateLoaded) return;
    loadingTemplate = true;
    error = null;
    _notifyListeners();
    try {
      template = await _loadTemplate();
      templateLoaded = true;
    } catch (caught) {
      error =
          'Could not load the configured commit template.\n${displayError(caught)}';
    } finally {
      loadingTemplate = false;
      _notifyListeners();
    }
  }

  void useTemplate() {
    final value = template;
    if (value == null || value.trim().isEmpty || message.trim().isNotEmpty) {
      return;
    }
    updateMessage(value.trim());
  }

  void useRecentSubject(String subject) => updateMessage(subject.trim());

  bool addCoAuthor(String name, String email) {
    final author = CommitCoAuthor.validated(name, email);
    if (author == null) {
      error = 'Enter a valid co-author name and email address.';
      notifyListeners();
      return false;
    }
    if (coAuthors.any((item) => item.email == author.email)) {
      error = null;
      _notifyListeners();
      return true;
    }
    coAuthors = [...coAuthors, author];
    error = null;
    notifyListeners();
    return true;
  }

  void removeCoAuthor(CommitCoAuthor author) {
    coAuthors = [
      for (final item in coAuthors)
        if (item != author) item,
    ];
    notifyListeners();
  }

  Future<void> ensurePrepared() async {
    await Future.wait([ensurePreview(), ensureGpgDisclosure()]);
  }

  Future<void> ensureGpgDisclosure() async {
    if (gpgDisclosureLoaded) return;
    gpgDisclosureLoaded = true;
    try {
      gpgSignConfigured = await _loadGpgSignConfigured();
    } catch (_) {
      gpgSignConfigured = false;
    }
    notifyListeners();
  }

  Future<void> ensurePreview({bool regenerate = false}) async {
    final signature = stagedSignature;
    if (signature.isEmpty || loadingPreview) return;
    if (!regenerate && _previewedSignatures.contains(signature)) return;
    loadingPreview = true;
    error = null;
    notifyListeners();
    try {
      // A pending operation's prepared message takes precedence over
      // generation; a failed read just falls through to the normal path.
      String? pending;
      try {
        pending = await _loadPendingMessage();
      } catch (_) {
        pending = null;
      }
      if (pending != null && pending.trim().isNotEmpty) {
        _previewedSignatures.add(signature);
        if (message.isEmpty || generated) {
          message = pending.trim();
          generated = false;
          editable = true;
          previewStale = false;
        }
        return;
      }
      final preview = await _generatePreview();
      _previewedSignatures.add(signature);
      if (stagedSignature != signature) {
        previewStale = message.isNotEmpty && generated;
        return;
      }
      if (preview != null && preview.trim().isNotEmpty) {
        message = preview.trim();
        generated = true;
        editable = false;
        previewStale = false;
      } else if (message.isEmpty) {
        editable = true;
      }
    } catch (caught) {
      error =
          'Could not generate a message. Enter one manually.\n${displayError(caught)}';
      editable = true;
    } finally {
      loadingPreview = false;
      notifyListeners();
    }
  }

  Future<CommitComposerOutcome> submit({
    required Future<bool> Function(String message) commit,
    Future<bool> Function()? push,
  }) async {
    if (committing) {
      return const CommitComposerOutcome(
        localCommitted: false,
        duplicateIgnored: true,
      );
    }
    final composed = composeCommitMessage(message, coAuthors);
    if (composed.isEmpty || stagedCount == 0) {
      return const CommitComposerOutcome(localCommitted: false);
    }
    committing = true;
    error = null;
    notifyListeners();
    try {
      final committed = await commit(composed);
      if (!committed) {
        return const CommitComposerOutcome(localCommitted: false);
      }
      clearDraft();
      final pushed = push == null ? null : await push();
      return CommitComposerOutcome(localCommitted: true, pushSucceeded: pushed);
    } catch (caught) {
      error = caught.toString();
      return const CommitComposerOutcome(localCommitted: false);
    } finally {
      committing = false;
      notifyListeners();
    }
  }
}

final commitComposerControllerProvider =
    Provider.family<CommitComposerController, CommitComposerKey>((ref, key) {
      final git = ref.watch(gitServiceProvider);
      final assistanceKey = CommitAssistanceKey(key.repoPath, key.sessionEpoch);
      final controller = CommitComposerController(
        repoPath: key.repoPath,
        generatePreview: () => git.generateCommitMessage(key.repoPath),
        loadGpgSignConfigured: () => git.commitGpgSignEnabled(key.repoPath),
        loadRecentSubjects: () async => [
          for (final commit in await git.log(key.repoPath, maxCount: 10))
            commit.subject,
        ],
        loadTemplate: () => git.commitTemplate(key.repoPath),
        // Gated on the pending-op probe so the common no-pending-op commit
        // never pays the extra message-file round-trip.
        loadPendingMessage: () async {
          final op = await ref.read(pendingOpProvider(key.repoPath).future);
          if (op == PendingOp.none) return null;
          return git.pendingCommitMessage(key.repoPath);
        },
      );
      ref.listen<List<String>>(
        landedCommitSubjectsProvider(assistanceKey),
        (_, next) => controller.publishLandedSubjects(next),
        fireImmediately: true,
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
