import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

/// The standard width for every pop-up sheet/card in the app, except the
/// file/diff viewers (which need room for content). One constant so the
/// chrome stays visually consistent and a future retune is a one-line edit.
const double kSheetWidth = 420;

/// Brief informational header shown directly under a sheet's title row —
/// one or two lines telling the user what the sheet does and what will
/// happen, before any fields appear.
class SheetDescription extends StatelessWidget {
  final String text;
  const SheetDescription(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: typography.caption1.copyWith(color: MacosColors.systemGrayColor),
      ),
    );
  }
}

/// A one-line explanation under a field or control group — the app-wide
/// affordance for making every input self-describing.
class FieldHint extends StatelessWidget {
  final String text;
  const FieldHint(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: typography.caption1.copyWith(color: MacosColors.systemGrayColor),
      ),
    );
  }
}
