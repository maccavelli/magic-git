/// The create sheet's namespace field: free text, with search and suggestions
/// attached (MADR 0032 Phase 5, decision 5B).
///
/// **The field is the contract, and it stays free text.** A namespace the API
/// never returned — a fresh grant, a paginated tail, an unreachable API — must
/// remain typeable, which is why option 5C (a required picker) was rejected.
/// Everything below is a convenience layered on top of a plain text field, and
/// every one of those layers is allowed to fail silently.
///
/// Three ways to reach a namespace, in increasing order of effort:
///
///  * **Chips** — the namespaces this account has actually been working in
///    (local history first, then the forge's event feed). Zero typing.
///  * **The dropdown** — focus the field and every creatable namespace is
///    listed, so the tail the chips omit is reachable by scrolling.
///  * **Typing** — filters that list instantly and offline, and a debounced
///    server search backfills what the cached list could not hold.
///
/// **Never a spinner, never an error.** Every provider here is read through
/// `asData?.value`: while a fetch is in flight, and forever after it fails,
/// this renders as a plain field with fewer suggestions. Rendering these
/// `AsyncValue`s through `.when()` would put a spinner where the form is
/// (MADR 0030 Phase 1).
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/forge/forge.dart';
import '../../../core/forge/namespace_suggestions.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/match_tier.dart';
import '../../../core/utils/posix_path.dart';
import '../../common/inline_action_button.dart';
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

  /// How many chips to offer at most.
  static const int maxSuggestions = 8;

  /// How many rows the dropdown offers at once. The rest are reachable by
  /// scrolling or by typing one more character.
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

    final matches = _ranked(
      _candidates(suggestions.ordered),
    ).take(NamespaceField.maxDropdownRows).toList();
    if (_highlighted >= matches.length) {
      _highlighted = matches.isEmpty ? 0 : matches.length - 1;
    }
    final showDropdown = _open && matches.isNotEmpty;

    return CallbackShortcuts(
      // These win over the field's default caret shortcuts because this sits
      // closer to the focused field than the app-wide DefaultTextEditingShortcuts
      // — the mechanism `CommandPalette` and Flutter's own Autocomplete use to
      // drive option navigation from inside a text field.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _move(1, matches.length),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _move(-1, matches.length),
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (showDropdown) _select(matches[_highlighted]);
        },
        // Escape closes the list without touching the text. The sheet's own
        // Escape handling must still reach it when the list is already shut,
        // so this only swallows the key while something is open.
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_open) setState(() => _open = false);
        },
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledTextField(
            label: 'Namespace (optional)',
            controller: widget.controller,
            focusNode: _focus,
            placeholder: 'team/subgroup',
            onChanged: _onEdited,
            padding: EdgeInsets.zero,
            hint: widget.hint,
          ),
          if (showDropdown) _dropdown(context, matches),
          _chips(suggestions),
        ],
      ),
    );
  }

  Widget _dropdown(BuildContext context, List<String> matches) {
    final theme = MacosTheme.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 168),
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: theme.canvasColor,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: matches.length,
        itemBuilder: (context, i) =>
            _row(context, matches[i], i == _highlighted, i, matches.length),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String namespace,
    bool highlighted,
    int position,
    int count,
  ) {
    final typography = MacosTheme.of(context).typography;
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

  /// The zero-typing path: what this account has recently worked in, falling
  /// back to the head of the creatable list for an account with no history yet.
  Widget _chips(NamespaceSuggestions suggestions) {
    final current = _query;
    final offered = suggestions.ordered
        .where((String ns) => ns != current)
        .take(NamespaceField.maxSuggestions)
        .toList();
    if (offered.isEmpty && current.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final ns in offered)
            InlineActionButton(
              label: ns,
              icon: CupertinoIcons.folder,
              tooltip: 'Create under $ns',
              onPressed: () => _select(ns),
            ),
          if (current.isNotEmpty)
            InlineActionButton(
              label: 'Clear',
              icon: CupertinoIcons.clear,
              tooltip: 'Create under your own account',
              onPressed: () => _select(null),
            ),
        ],
      ),
    );
  }
}
