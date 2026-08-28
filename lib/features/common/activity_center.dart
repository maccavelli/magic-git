import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/exec/operation_activity.dart';
import '../../core/providers/app_providers.dart';
import 'escape_dismissible.dart';
import 'inline_action_button.dart';
import 'menu_bar_bridge.dart';
import 'tool_icon_button.dart';

class ActivityCenterButton extends ConsumerStatefulWidget {
  final String? repositoryPath;
  final ValueChanged<OperationId>? onRevealOutput;
  final ValueChanged<OperationId>? onUndo;
  final ValueChanged<OperationId>? onOpenRecovery;

  const ActivityCenterButton({
    super.key,
    this.repositoryPath,
    this.onRevealOutput,
    this.onUndo,
    this.onOpenRecovery,
  });

  @override
  ConsumerState<ActivityCenterButton> createState() =>
      _ActivityCenterButtonState();
}

class _ActivityCenterButtonState extends ConsumerState<ActivityCenterButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final records = ref.watch(operationActivityProvider).where((record) {
      return widget.repositoryPath == null ||
          record.descriptor.repositoryPath == widget.repositoryPath;
    }).toList();
    final active = records.where((record) => !record.isTerminal).length;
    final failed = records
        .where((record) => record.phase == OperationPhase.failed)
        .length;
    final label = active > 0
        ? '$active active operation${active == 1 ? '' : 's'}'
        : failed > 0
        ? '$failed failed operation${failed == 1 ? '' : 's'}'
        : 'Activity';

    final shouldSpin = active > 0;
    if (shouldSpin != _spin.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (shouldSpin) {
          if (!_spin.isAnimating) unawaited(_spin.repeat());
        } else if (_spin.isAnimating || _spin.value != 0) {
          _spin
            ..stop()
            ..reset();
        }
      });
    }

    final iconButton = ToolIconButton(
      icon: active > 0
          ? CupertinoIcons.arrow_2_circlepath
          : CupertinoIcons.bell,
      tooltip: label,
      onPressed: () => showMacosSheet<void>(
        context: context,
        builder: (context) => EscapeDismissible(
          child: MacosSheet(
            child: SizedBox(
              width: 520,
              height: 420,
              // A live sheet, not a tap-time snapshot (0009 M3): the sheet
              // itself watches the provider, so a fetch that finishes while
              // it is open updates in place.
              child: ActivityCenterSheet(
                repositoryPath: widget.repositoryPath,
                onRevealOutput: widget.onRevealOutput,
              ),
            ),
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      label: label,
      child: active > 0
          ? RotationTransition(turns: _spin, child: iconButton)
          : iconButton,
    );
  }
}

/// The sheet body: watches [operationActivityProvider] live and wires the
/// actions the tap-time snapshot never could (0009 M3). Undo re-enters
/// through the same `global.undo` route the keyboard and menu use — with all
/// of its stale/dirty guards — and is only offered on the newest undoable
/// record, since the journal is a stack. Recovery toggles the shared
/// provider-driven sheet.
class ActivityCenterSheet extends ConsumerWidget {
  final String? repositoryPath;
  final ValueChanged<OperationId>? onRevealOutput;

  const ActivityCenterSheet({
    super.key,
    this.repositoryPath,
    this.onRevealOutput,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(operationActivityProvider).where((record) {
      return repositoryPath == null ||
          record.descriptor.repositoryPath == repositoryPath;
    }).toList();
    final newestUndoable = records
        .where((record) => record.undoable)
        .firstOrNull;
    return ActivityCenterList(
      records: records,
      undoableRecordId: newestUndoable?.id,
      // Reveal pops the sheet first so the Output pane isn't buried under it.
      onRevealOutput: onRevealOutput == null
          ? null
          : (id) {
              Navigator.of(context).pop();
              onRevealOutput!(id);
            },
      onUndo: newestUndoable == null
          ? null
          : (id) {
              Navigator.of(context).pop();
              ref
                  .read(menuActionRequestProvider.notifier)
                  .request('global.undo');
            },
      onOpenRecovery: (id) {
        Navigator.of(context).pop();
        ref.read(recoveryVisibleProvider.notifier).setVisible(true);
      },
    );
  }
}

class ActivityCenterList extends StatefulWidget {
  final List<OperationRecord> records;
  final ValueChanged<OperationId>? onRevealOutput;
  final ValueChanged<OperationId>? onUndo;
  final ValueChanged<OperationId>? onOpenRecovery;

  /// The only record whose row may offer Undo — the journal is a stack, so
  /// anything but its newest undoable entry would be a lying button.
  final OperationId? undoableRecordId;

  const ActivityCenterList({
    super.key,
    required this.records,
    this.onRevealOutput,
    this.onUndo,
    this.onOpenRecovery,
    this.undoableRecordId,
  });

  @override
  State<ActivityCenterList> createState() => _ActivityCenterListState();
}

class _ActivityCenterListState extends State<ActivityCenterList> {
  Timer? _elapsedTicker;

  bool get _hasLive => widget.records.any((record) => !record.isTerminal);

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ActivityCenterList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    if (_hasLive) {
      _elapsedTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _elapsedTicker?.cancel();
      _elapsedTicker = null;
    }
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return TickerMode(
      enabled: _hasLive,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Activity', style: typography.title2),
            const SizedBox(height: 12),
            if (widget.records.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    'No repository operations yet.',
                    style: typography.body.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: widget.records.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _ActivityRow(
                    record: widget.records[index],
                    onRevealOutput: widget.onRevealOutput,
                    onUndo: widget.records[index].id == widget.undoableRecordId
                        ? widget.onUndo
                        : null,
                    onOpenRecovery: widget.onOpenRecovery,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final OperationRecord record;
  final ValueChanged<OperationId>? onRevealOutput;
  final ValueChanged<OperationId>? onUndo;
  final ValueChanged<OperationId>? onOpenRecovery;

  const _ActivityRow({
    required this.record,
    this.onRevealOutput,
    this.onUndo,
    this.onOpenRecovery,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final phaseLabel = switch (record.phase) {
      OperationPhase.queued => 'Queued',
      OperationPhase.running => 'Running',
      OperationPhase.succeeded => 'Completed',
      OperationPhase.failed => 'Failed',
      OperationPhase.canceled => 'Canceled',
    };
    final elapsed = record.elapsed(clock.now());
    final elapsedLabel = elapsed.inMinutes > 0
        ? '${elapsed.inMinutes}m ${elapsed.inSeconds.remainder(60)}s'
        : '${elapsed.inSeconds}s';
    return Semantics(
      container: true,
      label: '${record.descriptor.label}, $phaseLabel',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: MacosColors.systemGrayColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      record.descriptor.label,
                      style: typography.body,
                    ),
                  ),
                  Text(
                    '$phaseLabel · $elapsedLabel',
                    style: typography.caption1,
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                [
                  ?record.descriptor.hostLabel,
                  record.descriptor.repositoryPath,
                  ?record.result,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
              if (record.outputAnchorId != null ||
                  record.undoable ||
                  record.recoveryAvailable) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (record.outputAnchorId != null && onRevealOutput != null)
                      InlineActionButton(
                        label: 'Output',
                        icon: CupertinoIcons.chevron_left_slash_chevron_right,
                        onPressed: () => onRevealOutput!(record.id),
                      ),
                    if (record.undoable && onUndo != null)
                      InlineActionButton(
                        label: 'Undo',
                        icon: CupertinoIcons.arrow_uturn_left,
                        onPressed: () => onUndo!(record.id),
                      ),
                    if (record.recoveryAvailable && onOpenRecovery != null)
                      InlineActionButton(
                        label: 'Recovery',
                        icon: CupertinoIcons.bandage,
                        onPressed: () => onOpenRecovery!(record.id),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
