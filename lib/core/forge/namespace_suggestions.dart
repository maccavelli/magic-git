/// What the create wizard offers for the namespace field (MADR 0032 Phase 4).
library;

/// Namespaces to offer, split by why they are being offered.
///
/// [recent] is what the user has actually been working in — local history
/// first, refined by the forge's own event feed — and is what the chips show.
/// [all] is every namespace the account may create in, and is what typing
/// searches. They overlap: [recent] is a prefix-ordered subset of [all]
/// whenever the creatable list could be read.
class NamespaceSuggestions {
  /// Most-recently-used first. Empty is normal: a new account, a quiet week,
  /// or a forge that could not be reached.
  final List<String> recent;

  /// Every creatable namespace, own-namespace first then groups.
  final List<String> all;

  const NamespaceSuggestions({this.recent = const [], this.all = const []});

  static const empty = NamespaceSuggestions();

  /// [recent] followed by everything else in [all] — the flat order the chips
  /// and the unfiltered dropdown use.
  List<String> get ordered => [
    ...recent,
    for (final ns in all)
      if (!recent.contains(ns)) ns,
  ];

  bool get isEmpty => recent.isEmpty && all.isEmpty;
}
