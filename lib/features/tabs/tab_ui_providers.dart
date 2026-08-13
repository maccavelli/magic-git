import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Per-tab sidebar/page UI state. These live in each tab's own root
/// [ProviderContainer], so a tab's active page and visited-page set are RETAINED
/// while the tab is backgrounded (its AppShell is unmounted under
/// single-active-mount) and restored when it's focused again — unlike widget
/// `State`, which would reset on the remount.

/// The active sidebar page (Repository / History / Branches / …) for this tab.
class PageIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) {
    if (state != index) state = index;
  }
}

final pageIndexProvider = NotifierProvider<PageIndexNotifier, int>(
  PageIndexNotifier.new,
);

/// Which sidebar pages have been visited since this tab's repo connected. A
/// visited page's panel is kept alive in the IndexedStack (preserving scroll,
/// selection, in-flight guards); an unvisited page renders a cheap placeholder.
class VisitedPagesNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {0};

  void visit(int index) {
    if (!state.contains(index)) state = {...state, index};
  }

  /// Drop back to only [keep] visited — used when the tab's repo changes so a
  /// stale panel can't carry a previous repo's state into a new one.
  void reset(int keep) {
    state = {keep};
  }
}

final visitedPagesProvider = NotifierProvider<VisitedPagesNotifier, Set<int>>(
  VisitedPagesNotifier.new,
);

/// The active tab's persisted display alias, hydrated by [TabsController]
/// from the stable saved-repository identity. It lives in the tab container so
/// the native window-title provider can react without depending on a runtime
/// tab id.
class TabAliasNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? alias) {
    final normalized = alias?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (state != next) state = next;
  }
}

final tabAliasProvider = NotifierProvider<TabAliasNotifier, String?>(
  TabAliasNotifier.new,
);
