import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/utils/display_error.dart';
import 'buttons.dart';
import 'inline_action_button.dart';

/// Consistent workspace-level loading treatment with a live-region label for
/// assistive technology. Reduced-motion policy is inherited from MediaQuery;
/// this widget does not add decorative animation.
class WorkspaceLoading extends StatelessWidget {
  final String label;

  const WorkspaceLoading({super.key, this.label = 'Loading'});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: label,
    child: const ExcludeSemantics(child: SectionLoading()),
  );
}

class WorkspaceEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const WorkspaceEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  }) : assert((actionLabel == null) == (onAction == null));

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MacosIcon(icon, color: MacosColors.systemGrayColor, size: 28),
            const SizedBox(height: 10),
            Text(title, style: typography.headline),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
            if (onAction != null) ...[
              const SizedBox(height: 12),
              AppPushButton(
                controlSize: ControlSize.regular,
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Keeps last-known-good content usable while reporting a refresh failure.
class WorkspacePartialError extends StatelessWidget {
  final Object error;
  final Widget child;
  final VoidCallback? onRetry;

  const WorkspacePartialError({
    super.key,
    required this.error,
    required this.child,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: 'Refresh failed. Existing content remains available.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: SectionError(error)),
            if (onRetry != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InlineActionButton(
                  label: 'Retry',
                  icon: CupertinoIcons.refresh,
                  onPressed: onRetry,
                ),
              ),
          ],
        ),
        Expanded(child: child),
      ],
    ),
  );
}

class WorkspaceStaleBanner extends StatelessWidget {
  final String message;

  const WorkspaceStaleBanner({
    super.key,
    this.message = 'Showing last-known data while refreshing.',
  });

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: message,
    child: ExcludeSemantics(
      child: SectionMessage(message, color: MacosColors.systemYellowColor),
    ),
  );
}

class WorkspaceUnavailable extends StatelessWidget {
  final String title;
  final String message;

  const WorkspaceUnavailable({
    super.key,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) => WorkspaceEmptyState(
    icon: CupertinoIcons.info_circle,
    title: title,
    message: message,
  );
}

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
  Widget build(BuildContext context) {
    final message = displayError(error);
    return Semantics(
      container: true,
      label: 'Error: $message',
      child: ExcludeSemantics(
        child: SectionMessage(message, color: MacosColors.systemRedColor),
      ),
    );
  }
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
///
/// [where] filters the items (the Forge panels' shared filter field). It
/// lives HERE — not in a caller-side AsyncValue transform — because mapping
/// an AsyncValue drops the previous value a reload retains, which would
/// break [skipLoadingOnReload] the moment a filter is composed with it.
Widget asyncListSection<T>(
  AsyncValue<List<T>> async,
  String emptyMessage,
  Widget Function(T) row, {
  bool skipLoadingOnReload = false,
  int? limit,
  Widget Function(int hidden)? overflow,
  bool Function(T)? where,
}) {
  List<Widget> buildRows(List<T> all) {
    final items = where == null
        ? all
        : [
            for (final e in all)
              if (where(e)) e,
          ];
    if (items.isEmpty) return [SectionEmpty(emptyMessage)];
    final visible = limit == null ? items : items.take(limit).toList();
    final hidden = items.length - visible.length;
    return [
      ...visible.map(row),
      if (hidden > 0 && overflow != null) overflow(hidden),
    ];
  }

  // A transient error *after* rows were already shown (a flaky refresh, or a
  // failed "show all") keeps the last good rows and surfaces the error inline
  // above them, rather than collapsing the whole populated section to a lone
  // red line and losing what the user was looking at. (Riverpod retains the
  // prior value on a reload that errors, so `hasValue` is true here.)
  if (async.hasError && async.hasValue) {
    return Column(
      children: [SectionError(async.error!), ...buildRows(async.requireValue)],
    );
  }

  return async.when(
    skipLoadingOnReload: skipLoadingOnReload,
    loading: () => const SectionLoading(),
    error: (err, _) => SectionError(err),
    data: (items) => Column(children: buildRows(items)),
  );
}
