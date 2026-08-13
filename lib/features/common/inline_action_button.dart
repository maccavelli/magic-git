import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import 'tappable.dart';
import 'workspace_appearance.dart';

/// How an action reads: an ordinary one, or one that throws work away.
enum InlineActionTone { normal, destructive }

/// THE small/inline action button — the app-wide standard for a compact
/// labelled action embedded in content: a hunk header's Stage/Unstage/Discard,
/// a banner's Continue/Abort, a settings row's Scan, a form's
/// Load-private-key. Enforced by `inline_button_canon_test.dart`, which bans
/// small `PushButton`s outright ([ControlSize.small]/`mini` never appear in
/// lib/). `AppPushButton` at regular/large remains the instrument for a
/// sheet's primary Cancel/Save row — this widget is for actions that live
/// *inside* content, not at the foot of a form.
///
/// Born in the diff views (as `DiffActionButton`): these sit *inside*
/// content, often on a coloured band, at 18px tall, and the stock
/// [PushButton] was the wrong instrument for that — a chrome-grey slab with a
/// hard border that reads as a Windows dialog button dropped into a code
/// listing. It also gave no hover feedback at all and left the pointer a
/// plain arrow, so the only way to discover the thing was live was to click
/// it and see.
///
/// So: a capsule that is nearly invisible at rest and lights up in the
/// action's own colour under the pointer — the accent for ordinary actions
/// (the *system* accent, so it matches whatever the user picked in System
/// Settings), red for the ones that destroy work. The pointer becomes a hand,
/// the surface brightens, the border finds its colour and the whole thing
/// lifts a hair; pressing it presses *in*. Every one of those is a separate,
/// redundant signal that this is a live control, because the complaint that
/// produced this widget was that it looked dead.
///
/// A null [onPressed] disables it: the capsule stays visible but dims, stops
/// reacting to the pointer, and the cursor stays an arrow (Tappable's
/// contract) — present, legible, inert.
class InlineActionButton extends StatefulWidget {
  const InlineActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tone = InlineActionTone.normal,
    this.tooltip,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final InlineActionTone tone;

  /// Optional hover tooltip — used where the short label alone doesn't say
  /// what the action operates on (e.g. "Scan" → "Scan environment").
  final String? tooltip;

  @override
  State<InlineActionButton> createState() => _InlineActionButtonState();
}

class _InlineActionButtonState extends State<InlineActionButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness.isDark;
    final enabled = widget.onPressed != null;
    final minimumTarget =
        WorkspaceAppearanceScope.maybeOf(
          context,
        )?.tokens.metrics.minimumTargetSize ??
        28;
    final accent = switch (widget.tone) {
      InlineActionTone.normal => theme.primaryColor,
      InlineActionTone.destructive => MacosColors.systemRedColor,
    };

    // At rest the capsule is just a faint pane of glass over whatever it sits
    // on — present, legible, but not competing with the content. Under the
    // pointer it becomes the accent; held down, more of it. Disabled, it
    // keeps the resting surface but dims the face and answers to nothing.
    final (Color fill, Color border, Color fg) = switch ((
      _pressed && enabled,
      _hovered && enabled,
    )) {
      (true, _) => (
        accent.withValues(alpha: dark ? 0.55 : 0.85),
        accent,
        MacosColors.white,
      ),
      (_, true) => (
        accent.withValues(alpha: dark ? 0.32 : 0.16),
        accent.withValues(alpha: dark ? 0.75 : 0.55),
        dark ? MacosColors.white : accent,
      ),
      _ => (
        dark
            ? MacosColors.white.withValues(alpha: 0.10)
            : MacosColors.white.withValues(alpha: 0.75),
        dark
            ? MacosColors.white.withValues(alpha: 0.16)
            : MacosColors.black.withValues(alpha: 0.14),
        enabled
            ? (theme.typography.body.color ?? MacosColors.textColor)
            : MacosColors.systemGrayColor,
      ),
    };

    // The hand cursor is the signal the old button never gave. Note Tappable's
    // MouseRegion has to sit *outside* everything: a Text under a
    // SelectionArea wraps itself in an I-beam MouseRegion, and the deepest
    // annotation under the pointer is the one that wins — which is exactly how
    // the pointer stayed an I-beam over a perfectly live button. Callers keep
    // these out of the selection scope (see SelectionContainer.disabled); this
    // is the belt to that's braces.
    final button = Tappable(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.onPressed,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minimumTarget),
        child: Center(
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 110),
            curve: Curves.easeOut,
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              // A vertical sheen rather than a flat fill — the thing that makes a
              // small macOS control look like a physical surface catching light
              // from above instead of a rectangle of colour.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(
                    MacosColors.white.withValues(alpha: dark ? 0.08 : 0.35),
                    fill,
                  ),
                  fill,
                ],
              ),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: border, width: 0.5),
              boxShadow: [
                // Lifted while hovered, sunk while pressed, resting otherwise —
                // and flat while disabled, which never lifts.
                if (!_pressed)
                  BoxShadow(
                    color: MacosColors.black.withValues(
                      alpha: _hovered && enabled ? 0.22 : 0.10,
                    ),
                    blurRadius: _hovered && enabled ? 3 : 1,
                    offset: Offset(0, _hovered && enabled ? 1 : 0.5),
                  ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MacosIcon(widget.icon, size: 9, color: fg),
                const SizedBox(width: 4),
                Text(
                  widget.label,
                  style: theme.typography.body.copyWith(
                    fontSize: 11,
                    height: 1.0,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.1,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final tooltip = widget.tooltip;
    if (tooltip == null) return button;
    return MacosTooltip(message: tooltip, child: button);
  }
}
