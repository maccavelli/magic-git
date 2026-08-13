import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'palette_models.dart';

/// A one-shot command the palette dispatched at a panel it may first have had
/// to switch to.
///
/// Panel-scoped actions (fetch, cherry-pick, apply stash, …) live as handlers
/// inside their panel's State — the palette cannot call them directly, and
/// duplicating them at the shell would fork every guard those handlers carry
/// (busy gates, selection requirements, dirty-tree prompts). Instead the
/// palette switches to the owning panel and parks the action id here; the
/// panel's [PanelShortcuts] consumes it on its next build (or immediately,
/// when the panel is already active) and runs the exact same handler its
/// keyboard shortcut would.
class PaletteIntent {
  final String actionId;
  final PaletteEntry? entity;
  final String? repositoryPath;
  final int? sessionEpoch;

  /// When the intent was dispatched — see [PaletteIntentNotifier.maxAge].
  final DateTime at;

  PaletteIntent(
    this.actionId, {
    this.entity,
    this.repositoryPath,
    this.sessionEpoch,
  }) : at = DateTime.now();

  bool get expired =>
      DateTime.now().difference(at) > PaletteIntentNotifier.maxAge;
}

class PaletteIntentNotifier extends Notifier<PaletteIntent?> {
  /// An intent nobody consumed (its panel never registered the handler —
  /// e.g. a GitLab action dispatched against a GitHub repo) must not fire
  /// minutes later when circumstances change under the user; any consume
  /// attempt after this window drops it instead.
  static const Duration maxAge = Duration(seconds: 3);

  @override
  PaletteIntent? build() => null;

  void dispatch(String actionId) => state = PaletteIntent(actionId);

  void dispatchEntity({
    required String actionId,
    required PaletteEntry entity,
    required String repositoryPath,
    required int sessionEpoch,
  }) {
    state = PaletteIntent(
      actionId,
      entity: entity,
      repositoryPath: repositoryPath,
      sessionEpoch: sessionEpoch,
    );
  }

  void clear() => state = null;

  /// Consumes the pending intent against [handlers] (a panel's action-id →
  /// handler map; null values mean "known but currently unavailable", the
  /// same convention `resolveShortcuts` uses). Returns the handler to run,
  /// or null when there is nothing for this panel to do.
  ///
  /// An intent this panel OWNS is always cleared — runnable or not — so a
  /// selection-dependent action dispatched with nothing selected dies here
  /// rather than firing later against a different selection. Foreign ids are
  /// left alone for the owning panel.
  VoidCallbackOrNull consume(Map<String, void Function()?> handlers) {
    final intent = state;
    if (intent == null) return null;
    if (intent.expired) {
      state = null;
      return null;
    }
    if (!handlers.containsKey(intent.actionId)) return null;
    final handler = handlers[intent.actionId];
    state = null;
    return handler;
  }
}

typedef VoidCallbackOrNull = void Function()?;

final paletteIntentProvider =
    NotifierProvider<PaletteIntentNotifier, PaletteIntent?>(
      PaletteIntentNotifier.new,
    );
