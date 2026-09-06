/// The wizard's segmented selector: a row of push buttons where the active one
/// is filled and the rest are secondary.
///
/// The create sheet had this twice — `_sourceButton` and `_remoteButton` — as
/// the same shape parameterised differently (MADR 0033 Phase 5). Generic over
/// the choice type so both the source mode and the remote mode use one widget.
library;

import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../common/buttons.dart';

class SegmentedChoice<T> extends StatelessWidget {
  final String label;

  /// The value this button selects.
  final T value;

  /// The currently selected value; `value == selected` fills the button.
  final T selected;

  final ValueChanged<T> onSelected;

  const SegmentedChoice({
    super.key,
    required this.label,
    required this.value,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final active = value == selected;
    return AppPushButton(
      controlSize: ControlSize.regular,
      secondary: !active,
      onPressed: () => onSelected(value),
      child: Text(label),
    );
  }
}
