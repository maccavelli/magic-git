/// The create sheet's namespace field: a search bar over the namespaces this
/// account may create in (MADR 0032, decision 5B as amended 2026-09-07).
///
/// **The field is the contract, and it stays free text.** A namespace the API
/// never returned — a fresh grant, a paginated tail, an unreachable API — must
/// remain typeable, which is why option 5C (a required picker) was rejected.
/// Everything below is a convenience layered on a plain text field, and every
/// layer is allowed to fail silently. What is typed IS the namespace; the
/// search is how you avoid typing it.
///
/// **Why this is a search bar and not a row of chips.** Phase 5 first shipped
/// chips inherited from MADR 0031 — an alphabetical row of paths — and the
/// maintainer's response was that a row of buttons was never the idea. Chips
/// cannot show a tail (they capped at 8 while the service fetched 10), cannot
/// be scanned, and cannot be filtered. One search bar with a sectioned
/// dropdown does all three:
///
///  * **Focus it** and the dropdown opens on `RECENTLY ACTIVE` — the
///    namespaces this account has actually been working in, most recent first
///    — above `ALL YOU CAN CREATE IN`, which is everything else. No typing
///    reaches the recents; scrolling reaches the tail.
///  * **Type** and both sections filter, locally and instantly, with a
///    debounced server search backfilling what the cached list cannot hold.
///
/// **Recency is namespaces, not projects, and that is deliberate.** A
/// repository cannot be created *inside* a project, only inside a namespace,
/// so the forge's project-level activity is projected onto the namespaces that
/// own it — which is also what makes the list short enough to scan.
///
/// **Never a spinner, never an error.** Every provider here is read through
/// `asData?.value`: while a fetch is in flight, and forever after it fails,
/// this renders as a plain field with fewer suggestions. Rendering these
/// `AsyncValue`s through `.when()` would put a spinner where the form is
/// (MADR 0030 Phase 1).
library;

import 'dart:async';

// `OverlayVisibilityMode` is declared by both cupertino and macos_ui; this
// file wants the macos_ui one, so cupertino's is hidden rather than aliased.
import 'package:flutter/cupertino.dart' hide OverlayVisibilityMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/forge/forge.dart';
import '../../../core/forge/namespace_suggestions.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/match_tier.dart';
import '../../../core/utils/posix_path.dart';
import '../../common/labeled_text_field.dart';
import '../../common/tappable.dart';

class NamespaceField extends ConsumerStatefulWidget {
  final Forge forge;
  final String host;
  final bool isLocalTarget;

  /// The destination connection, or null for a This-Mac create. Keys the
  /// suggestion list, because a namespace is meaningless across accounts.
  final String? connectionId;

  final TextEditingController controller;

  /// Called after every edit and every selection, so the sheet re-evaluates
  /// its own step validity exactly as it does for any other field.
  final VoidCallback onChanged;

  /// The sheet's explanatory hint, rendered in [LabeledTextField]'s hint slot.
  final Widget? hint;

  /// How many recently-active namespaces the dropdown's first section offers.
  ///
  /// **Ten, because ten is what was asked for.** The previous surface capped
  /// at 8 while `recentlyActiveNamespaces` already fetched 10, so two were
  /// fetched and silently dropped.
  static const int maxRecent = 10;

  /// How many rows the dropdown builds at once across both sections. The rest
  /// are reachable by scrolling or by typing one more character.
  static const int maxDropdownRows = 50;

  /// The `CommandPalette` interval — long enough that a fast typist issues one
  /// request rather than one per key, short enough to feel immediate.
  static const Duration searchDebounce = Duration(milliseconds: 150);

  const NamespaceField({
    super.key,
    required this.forge,
    required this.host,
    required this.isLocalTarget,
    required this.connectionId,
    required this.controller,
    required this.onChanged,
    this.hint,
  });

  @override
  ConsumerState<NamespaceField> createState() => _NamespaceFieldState();
}

class _NamespaceFieldState extends ConsumerState<NamespaceField> {
  final FocusNode _focus = FocusNode();

  Timer? _debounce;

  /// Discards superseded responses: a slow request for "te" must not overwrite
  /// results for "team" the user has since typed. `command_palette.dart`
  /// establishes this shape.
  int _generation = 0;

  /// What the last completed server search returned, merged into the cached
  /// list by full path. Kept across keystrokes on purpose — narrowing a query
  /// should not blank the extra rows the previous one found.
  List<String> _fromServer = const [];

  bool _open = false;
  int _highlighted = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() {
      _open = _focus.hasFocus;
      if (!_focus.hasFocus) _highlighted = 0;
    });
  }

  String get _query => widget.controller.text.trim();

  void _onEdited() {
    // The sheet owns step validity, so it hears about every keystroke first.
    widget.onChanged();
    setState(() {
      _open = true;
      _highlighted = 0;
    });
    _scheduleSearch();
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    final query = _query;
    if (query.isEmpty) return;
    final generation = ++_generation;
    _debounce = Timer(NamespaceField.searchDebounce, () {
      unawaited(_search(query, generation));
    });
  }

  Future<void> _search(String query, int generation) async {
    final List<String> found;
    try {
      found = await ref.read(
        namespaceSearchProvider((
          widget.forge,
          widget.host,
          widget.isLocalTarget,
          query,
        )).future,
      );
    } catch (_) {
      // The service swallows its own failures, but the provider around it can
      // still fail — a local environment probe, a torn-down executor. This is
      // a suggestion: a failed search leaves the cached matches standing and
      // the user typing, never an error where the form is.
      return;
    }
    // Superseded, or the field is gone. Either way the answer is stale.
    if (!mounted || generation != _generation || found.isEmpty) return;
    setState(() {
      _fromServer = [
        ..._fromServer,
        for (final ns in found)
          if (!_fromServer.contains(ns)) ns,
      ];
    });
  }

  /// Every namespace known right now, cached list first then anything only the
  /// server search has seen, deduplicated by full path.
  List<String> _candidates(List<String> ordered) => [
    ...ordered,
    for (final ns in _fromServer)
      if (!ordered.contains(ns)) ns,
  ];

  /// [candidates] ranked against the typed query, best tier first.
  ///
  /// A namespace matches on its **full path or its last segment**, so typing
  /// `subgroup` finds `team/subgroup` without typing the parent — the wildcard
  /// behaviour the MADR asked for. Ties keep their incoming order, which is
  /// recency, so a recent namespace outranks an equally-good stale one.
  List<String> _ranked(List<String> candidates) {
    if (_query.isEmpty) return candidates;
    final scored = <(int, int, String)>[];
    for (var i = 0; i < candidates.length; i++) {
      final ns = candidates[i];
      final tier = matchTier([ns, basename(ns)], _query);
      if (tier != null) scored.add((tier, i, ns));
    }
    scored.sort((a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1 - b.$1);
    return [for (final entry in scored) entry.$3];
  }

  void _select(String? namespace) {
    if (namespace == null) {
      widget.controller.clear();
    } else {
      widget.controller.text = namespace;
      widget.controller.selection = TextSelection.collapsed(
        offset: namespace.length,
      );
    }
    setState(() {
      _open = false;
      _highlighted = 0;
    });
    widget.onChanged();
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() {
      _open = true;
      _highlighted = (_highlighted + delta) % count;
      if (_highlighted < 0) _highlighted += count;
    });
  }

  @override
  Widget build(BuildContext context) {
    final suggestions =
        ref
            .watch(
              namespaceSuggestionsProvider((
                widget.forge,
                widget.host,
                widget.isLocalTarget,
                widget.connectionId,
              )),
            )
            .asData
            ?.value ??
        NamespaceSuggestions.empty;

    // Two sections, ranked independently so a recent namespace is never
    // buried under an alphabetically-earlier one it shares a tier with.
    final recent = _ranked(
      suggestions.recent,
    ).take(NamespaceField.maxRecent).toList();
    final rest = _ranked(
      _candidates(
        suggestions.all,
      ).where((ns) => !suggestions.recent.contains(ns)).toList(),
    );

    final flat = [...recent, ...rest];
    final shown = flat.take(NamespaceField.maxDropdownRows).toList();
    if (_highlighted >= shown.length) {
      _highlighted = shown.isEmpty ? 0 : shown.length - 1;
    }
    final showDropdown = _open && shown.isNotEmpty;

    return CallbackShortcuts(
      // These win over the field's default caret shortcuts because this sits
      // closer to the focused field than the app-wide DefaultTextEditingShortcuts
      // — the mechanism `CommandPalette` and Flutter's own Autocomplete use to
      // drive option navigation from inside a text field.
      //
      // No Escape binding: dismissal is registry-based and focus-independent
      // (`EscapeDismissible` at the sheet's call site), so a focus-scoped
      // Escape here fights it and wins only sometimes. The list closes on
      // choice and on blur instead.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _move(1, shown.length),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _move(-1, shown.length),
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (showDropdown) _select(shown[_highlighted]);
        },
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledTextField(
            label: 'Namespace (optional)',
            controller: widget.controller,
            focusNode: _focus,
            // The magnifier is the whole point of the redesign: this reads as
            // a search affordance, not as one more field to fill in.
            prefix: const Padding(
              padding: EdgeInsets.only(left: 6),
              child: MacosIcon(CupertinoIcons.search, size: 13),
            ),
            // Replaces the "Clear" chip the old surface carried: emptying the
            // field is what "create under my own account" means, and that must
            // stay one click, not a select-all and delete.
            clearButtonMode: OverlayVisibilityMode.editing,
            placeholder: 'Search namespaces…',
            onChanged: _onEdited,
            padding: EdgeInsets.zero,
            hint: widget.hint,
          ),
          if (showDropdown)
            _dropdown(context, recent: recent, rest: rest, shown: shown),
        ],
      ),
    );
  }

  /// The attached list: `RECENTLY ACTIVE`, then everything else creatable.
  ///
  /// A section with nothing in it disappears entirely rather than showing an
  /// empty header — a new account has no recents, and a heading over nothing
  /// reads as a fault.
  Widget _dropdown(
    BuildContext context, {
    required List<String> recent,
    required List<String> rest,
    required List<String> shown,
  }) {
    final theme = MacosTheme.of(context);
    final rows = <Widget>[];
    if (recent.isNotEmpty) {
      rows.add(_sectionHeader(context, 'Recently active'));
      for (final ns in recent.where(shown.contains)) {
        rows.add(_row(context, ns, shown.indexOf(ns), shown.length));
      }
    }
    final restShown = rest.where(shown.contains).toList();
    if (restShown.isNotEmpty) {
      rows.add(
        _sectionHeader(
          context,
          recent.isEmpty
              ? 'You can create in'
              : 'All you can create in (${rest.length})',
        ),
      );
      for (final ns in restShown) {
        rows.add(_row(context, ns, shown.indexOf(ns), shown.length));
      }
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: theme.canvasColor,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: rows,
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String label) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Text(
        label.toUpperCase(),
        style: typography.caption2.copyWith(
          color: MacosColors.systemGrayColor,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String namespace, int position, int count) {
    final typography = MacosTheme.of(context).typography;
    final highlighted = position == _highlighted;
    // Tappable carries no semantics of its own, so without this the row reads
    // as a bare path with no indication it can be chosen (the same reason
    // `CommandPalette._row` wraps its rows).
    return Semantics(
      button: true,
      selected: highlighted,
      label: 'Create under $namespace, ${position + 1} of $count',
      child: Tappable(
        onTap: () => _select(namespace),
        child: ExcludeSemantics(
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: highlighted
                  ? MacosColors.systemBlueColor.withValues(alpha: 0.22)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                const MacosIcon(CupertinoIcons.folder, size: 13),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    namespace,
                    style: typography.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
