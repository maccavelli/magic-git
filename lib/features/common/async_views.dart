import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

/// Padded, centered spinner for an in-flight section load.
class SectionLoading extends StatelessWidget {
  const SectionLoading({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(16),
    child: Center(child: ProgressCircle()),
  );
}

/// A caption-styled, colour-coded inline message (used for empty/error states).
class SectionMessage extends StatelessWidget {
  final String message;
  final Color color;

  const SectionMessage(this.message, {super.key, required this.color});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      message,
      style: MacosTheme.of(context).typography.caption1.copyWith(color: color),
    ),
  );
}

/// Red inline error text for a failed section load.
class SectionError extends StatelessWidget {
  final Object error;

  const SectionError(this.error, {super.key});

  @override
  Widget build(BuildContext context) =>
      SectionMessage('$error', color: MacosColors.systemRedColor);
}

/// Grey inline "nothing here" text for an empty section.
class SectionEmpty extends StatelessWidget {
  final String message;

  const SectionEmpty(this.message, {super.key});

  @override
  Widget build(BuildContext context) =>
      SectionMessage(message, color: MacosColors.systemGrayColor);
}

/// Centered notice for the GitLab/Project panels when the active repo has no
/// remote at all — those views are glab-backed and can't work, so this is shown
/// instead of a raw glab error dump. Mirrors the "No remote detected" label in
/// the Repository panel; [feature] names what's unavailable (e.g. "GitLab
/// features", "project features").
class NoRemoteNotice extends StatelessWidget {
  final String feature;

  const NoRemoteNotice(this.feature, {super.key});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'No remote detected',
              style: typography.headline.copyWith(
                color: MacosColors.systemYellowColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'This repository has no remote configured, so $feature are '
              'unavailable.',
              textAlign: TextAlign.center,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a list-bearing [AsyncValue] as a vertical section: a padded spinner
/// while loading, a red message on error, a grey [emptyMessage] when the list is
/// empty, otherwise the mapped [row]s stacked in a Column.
///
/// With [limit] set, only the first [limit] items are rendered and [overflow]
/// (given the hidden count) supplies a trailing row — the "Show more"
/// affordance. [skipLoadingOnReload] keeps the current rows on screen while a
/// dependency-triggered re-fetch runs (e.g. the Forge panels expanding a list
/// to full history) instead of collapsing the section to a spinner.
Widget asyncListSection<T>(
  AsyncValue<List<T>> async,
  String emptyMessage,
  Widget Function(T) row, {
  bool skipLoadingOnReload = false,
  int? limit,
  Widget Function(int hidden)? overflow,
}) {
  return async.when(
    skipLoadingOnReload: skipLoadingOnReload,
    loading: () => const SectionLoading(),
    error: (err, _) => SectionError(err),
    data: (items) {
      if (items.isEmpty) return SectionEmpty(emptyMessage);
      final visible = limit == null ? items : items.take(limit).toList();
      final hidden = items.length - visible.length;
      return Column(
        children: [
          ...visible.map(row),
          if (hidden > 0 && overflow != null) overflow(hidden),
        ],
      );
    },
  );
}
