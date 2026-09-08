/// The tab half of the lifecycle every workspace entry point runs: claim a tab
/// to work in, and give it back if the work is abandoned.
///
/// **Plain and widget-free on purpose.** `WorkspaceProvisioning` was extracted
/// as `mixin … on ConsumerState<T>`, which means it cannot be constructed
/// without a widget, which is why it has no direct test — and why the tab
/// lifecycle beside it was hand-copied into all three sheets anyway rather
/// than shared (MADR 0038 F7). The copies were byte-identical between the
/// create and add-existing sheets and differed from the clone sheet only by
/// its routed-job teardown, which is now [abandon]'s `releaseSession`
/// callback.
///
/// This object owns the **tab**. The session in it stays with
/// `WorkspaceProvisioning`: `ensureProvisioned` interleaves three `mounted`
/// checks and three `setState` calls with a mid-dial guard that re-reads live
/// sheet state after an await (the MADR 0022 H4 fix), so it is not splittable
/// and — being a single implementation already — is not part of the
/// duplication this file removes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local/scoped_access.dart';
import '../tabs/tabs_controller.dart';

class WorkspaceFlow {
  WorkspaceFlow({required this.origin, this.tabsOverride, this.accessOverride});

  /// The container the sheet itself was opened in — the fallback when no tab
  /// is claimed (the landing page, and any context with no [TabsController]).
  final ProviderContainer origin;

  /// Test injection points. Null in production, where the statics below are
  /// the real ones.
  final TabsController? tabsOverride;
  final ScopedAccess? accessOverride;

  /// Resolved at each use, never captured at construction.
  ///
  /// **Behaviour preservation, not a test requirement.** The code this file
  /// replaces read `TabsController.current` on every call, so a sheet mounted
  /// before a `TabsHost` exists picks the controller up later; capturing in
  /// the constructor would silently change that. (The tests that swap these
  /// statics all assign before the pump, so they would pass either way — which
  /// is exactly why they are not the justification.)
  TabsController? get tabs => tabsOverride ?? TabsController.current;

  /// The registry tab grants are taken from. Same lazy-resolution reasoning.
  ScopedAccess get scopedAccess => accessOverride ?? ScopedAccess.instance;

  /// The tab this flow claimed, or null when it is working in [origin].
  RepoTab? get tab => _tab;
  RepoTab? _tab;

  /// The tab to return to after an abandon.
  String? _originTabId;

  /// The tab this flow was opened from, for a caller that closes a tab of its
  /// own and wants to land the user back where they started. The add-existing
  /// sheet uses it when a local open turns out not to be a repository.
  String? get originTabId => _originTabId;

  /// Where this flow's work runs: the claimed tab if there is one, else the
  /// container the sheet was opened in. Captured either way — there is no
  /// ambient `ref` here to drift onto whichever tab happens to be active
  /// (MADR 0038 F3).
  ProviderContainer get container => _tab?.container ?? origin;

  /// Whether the work must be refused before it starts.
  ///
  /// A flow that ends by opening a tab cannot run at the cap: `openOrFocus`
  /// would silently never run `connect` (`tabs_controller.dart:289-292`), and
  /// for a host with no session there is no current-tab fallback that does not
  /// destroy the workspace the user is in (MADR 0036, 7A).
  ///
  /// [opensNewTab] is the caller's, because the three sheets spell it in their
  /// own fields — `!_isLocalTarget || _saveLocal` in the wizards,
  /// `!_isLocal || _save` in the add-existing sheet. Same meaning, different
  /// state; only the rule below is shared.
  bool refusedAtTabCap({required bool opensNewTab}) =>
      opensNewTab && _tab == null && !(tabs?.canOpenTab ?? true);

  /// Claims a tab to work in. Returns false **only** when refused at the cap.
  ///
  /// With no tab host at all the sheet's own container is used — the landing
  /// behaviour, which is also what `newTab()` yields there: the active tab is
  /// blank and is reused rather than duplicated.
  Future<bool> ensureTab() async {
    if (_tab != null) return true;
    final controller = tabs;
    if (controller == null) return true;
    if (!controller.canOpenTab) return false;
    _originTabId = controller.activeId;
    _tab = controller.newTab();
    return true;
  }

  /// Relinquishes ownership of the claimed tab **without closing it**: the work
  /// succeeded and the tab is the workspace now, so there is nothing left to
  /// abort or close. A later [abandon] — from `dispose()`, say — then finds
  /// nothing to give back, which is the point.
  void keep() {
    _tab = null;
    _originTabId = null;
  }

  /// Gives the tab back: releases the session, then closes the tab this flow
  /// opened and returns to the one the sheet came from. A blank tab merely
  /// reused (the landing page) is left as it was.
  ///
  /// [releaseSession] is what hangs up whatever was dialled — the sheets pass
  /// `resetProvisioning`, and the clone sheet closes its routed job first.
  /// Called **after** the tab reference is cleared and **before** the tab is
  /// closed, which is the order all three copies used.
  ///
  /// Safe from `dispose()`: nothing here touches a `ref` or a `BuildContext`.
  Future<void> abandon({
    required Future<void> Function() releaseSession,
  }) async {
    final claimed = _tab;
    _tab = null;
    await releaseSession();
    if (claimed == null) return;
    final controller = tabs;
    if (controller == null || claimed.id == _originTabId) return;
    await controller.close(claimed.id);
    final origin = _originTabId;
    if (origin != null) controller.activate(origin);
  }
}
