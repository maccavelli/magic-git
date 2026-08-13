import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';

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
  }) : this._(
         repoPath: repoPath,
         generatePreview: generatePreview,
         loadGpgSignConfigured: loadGpgSignConfigured,
       );

  CommitComposerController._({
    required this.repoPath,
    required this._generatePreview,
    required this._loadGpgSignConfigured,
  });

  final String repoPath;
  final Future<String?> Function() _generatePreview;
  final Future<bool> Function() _loadGpgSignConfigured;
  final Set<String> _previewedSignatures = {};

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
  String? error;

  bool get canAccept =>
      stagedCount > 0 && !committing && message.trim().isNotEmpty;

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
    generated = false;
    editable = true;
    previewStale = false;
    error = null;
    _previewedSignatures.clear();
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
      error = 'Could not generate a message. Enter one manually.\n$caught';
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
    final trimmed = message.trim();
    if (trimmed.isEmpty || stagedCount == 0) {
      return const CommitComposerOutcome(localCommitted: false);
    }
    committing = true;
    error = null;
    notifyListeners();
    try {
      final committed = await commit(trimmed);
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
      final controller = CommitComposerController(
        repoPath: key.repoPath,
        generatePreview: () => git.generateCommitMessage(key.repoPath),
        loadGpgSignConfigured: () => git.commitGpgSignEnabled(key.repoPath),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
