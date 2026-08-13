import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/exec/operation_activity.dart';
import 'inline_action_button.dart';
import 'tool_icon_button.dart';

class ActivityCenterButton extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(operationActivityProvider).where((record) {
      return repositoryPath == null ||
          record.descriptor.repositoryPath == repositoryPath;
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

    return Semantics(
      button: true,
      label: label,
      child: ToolIconButton(
        icon: active > 0
            ? CupertinoIcons.arrow_2_circlepath
            : CupertinoIcons.bell,
        tooltip: label,
        onPressed: () => showMacosSheet<void>(
          context: context,
          builder: (context) => MacosSheet(
            child: SizedBox(
              width: 520,
              height: 420,
              child: ActivityCenterList(
                records: records,
                onRevealOutput: onRevealOutput,
                onUndo: onUndo,
                onOpenRecovery: onOpenRecovery,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ActivityCenterList extends StatelessWidget {
  final List<OperationRecord> records;
  final ValueChanged<OperationId>? onRevealOutput;
  final ValueChanged<OperationId>? onUndo;
  final ValueChanged<OperationId>? onOpenRecovery;

  const ActivityCenterList({
    super.key,
    required this.records,
    this.onRevealOutput,
    this.onUndo,
    this.onOpenRecovery,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Activity', style: typography.title2),
          const SizedBox(height: 12),
          if (records.isEmpty)
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
                itemCount: records.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) => _ActivityRow(
                  record: records[index],
                  onRevealOutput: onRevealOutput,
                  onUndo: onUndo,
                  onOpenRecovery: onOpenRecovery,
                ),
              ),
            ),
        ],
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
    final elapsed = record.elapsed(DateTime.now());
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
