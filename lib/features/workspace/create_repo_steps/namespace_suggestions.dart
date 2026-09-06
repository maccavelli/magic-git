/// Namespace suggestion chips under the create sheet's namespace field.
///
/// **Never a spinner, never an error.** Read through `asData?.value` on
/// purpose: the namespace field is free text and works with no list at all, so
/// a slow or unreachable forge must cost the user nothing. While the fetch is
/// in flight, and forever after it fails, this renders as empty space.
/// Rendering the `AsyncValue` through `.when()` would put a spinner where the
/// form is (MADR 0030 Phase 1).
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/forge/forge.dart';
import '../../../core/providers/app_providers.dart';
import '../../common/inline_action_button.dart';

class NamespaceSuggestions extends ConsumerWidget {
  final Forge forge;
  final String host;
  final bool isLocalTarget;

  /// The namespace already in the field — excluded from the offered chips, and
  /// what decides whether the Clear chip appears.
  final String current;

  /// A chip was tapped; null clears the field.
  final ValueChanged<String?> onSelected;

  /// How many chips to offer at most.
  static const int maxSuggestions = 8;

  const NamespaceSuggestions({
    super.key,
    required this.forge,
    required this.host,
    required this.isLocalTarget,
    required this.current,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final namespaces =
        ref
            .watch(forgeNamespacesProvider((forge, host, isLocalTarget)))
            .asData
            ?.value ??
        const <String>[];
    final offered = namespaces
        .where((String ns) => ns != current)
        .take(maxSuggestions)
        .toList();
    if (offered.isEmpty) return const SizedBox.shrink();
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
              onPressed: () => onSelected(ns),
            ),
          if (current.isNotEmpty)
            InlineActionButton(
              label: 'Clear',
              icon: CupertinoIcons.clear,
              tooltip: 'Create under your own account',
              onPressed: () => onSelected(null),
            ),
        ],
      ),
    );
  }
}
