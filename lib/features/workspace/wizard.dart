import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../common/sheet_chrome.dart';

/// The wizards' field hint is the app-wide [FieldHint] — one widget, one
/// look, whether a control lives in a wizard step or a plain sheet.
typedef WizardHint = FieldHint;

/// Shared machinery for the workspace wizards (Create repository, Clone
/// repository): the data-driven step model plus the widgets every wizard
/// renders around its steps — breadcrumb indicator, per-step instructional
/// intro, field hints, and the bottom step-progress bar.

/// One page of a wizard, described as data: the sheet's build method renders
/// whatever its step list says — indicator, Continue gating, Back navigation
/// and the progress bar are all generic over this list, so adding or
/// reordering a step is a single list entry, no navigation code changes.
class WizardStep {
  final String id;
  final String title;

  /// Instructional overview shown in an info box above the step's fields —
  /// what this step decides and what will happen with it.
  final String intro;

  /// Whether the step participates at all (e.g. Destination exists only on
  /// the landing variant). Evaluated live, so steps may come and go with
  /// earlier answers.
  final bool Function() applicable;

  /// Gates the Continue button (and, composed across all steps, the final
  /// action button).
  final bool Function() valid;

  final Widget Function(MacosTypography) body;

  const WizardStep({
    required this.id,
    required this.title,
    required this.intro,
    this.applicable = always,
    required this.valid,
    required this.body,
  });

  static bool always() => true;
}

/// Breadcrumb of the active steps with the current one highlighted. A Wrap
/// so five landing-mode steps flow onto a second line at sheet width.
class WizardStepIndicator extends StatelessWidget {
  final List<WizardStep> steps;
  final int current;

  const WizardStepIndicator({
    super.key,
    required this.steps,
    required this.current,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Wrap(
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '›',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ),
          Text(
            steps[i].title,
            style: typography.caption1.copyWith(
              color: i == current
                  ? MacosColors.systemBlueColor
                  : MacosColors.systemGrayColor,
              fontWeight: i == current ? FontWeight.w600 : null,
            ),
          ),
        ],
      ],
    );
  }
}

/// A step's instructional overview — an info box between the breadcrumb and
/// the fields.
class WizardStepIntro extends StatelessWidget {
  final String text;
  const WizardStepIntro(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: MacosColors.systemGrayColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MacosIcon(
            CupertinoIcons.info_circle,
            size: 14,
            color: MacosColors.systemGrayColor,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: typography.caption1)),
        ],
      ),
    );
  }
}

/// One label/value line of a wizard's Review step summary.
class WizardReviewRow extends StatelessWidget {
  final String label;
  final String value;
  const WizardReviewRow(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
          Expanded(child: Text(value, style: typography.body)),
        ],
      ),
    );
  }
}

/// The wizard's bottom status bar: one segment per active step, filling left
/// to right as the user advances, with a caption naming the current step.
/// Every segment turns green once the wizard's work has completed
/// successfully.
class WizardProgressBar extends StatelessWidget {
  final List<WizardStep> steps;

  /// Index of the step currently shown.
  final int current;

  /// True once the wizard's final action has succeeded — the whole bar
  /// renders green (macOS success tint) instead of the in-progress blue.
  final bool complete;

  const WizardProgressBar({
    super.key,
    required this.steps,
    required this.current,
    required this.complete,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final active = complete
        ? MacosColors.systemGreenColor
        : MacosColors.systemBlueColor;
    final track = MacosColors.systemGrayColor.withValues(alpha: 0.25);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          complete
              ? 'Complete'
              : 'Step ${current + 1} of ${steps.length} — '
                    '${steps[current].title}',
          style: typography.caption1.copyWith(
            color: complete ? MacosColors.systemGreenColor : null,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 5,
                  decoration: BoxDecoration(
                    color: complete || i <= current ? active : track,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
