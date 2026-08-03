import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/merge_plan.dart';
import '../common/buttons.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';

/// Result of [showMergeOptionsSheet].
class MergeOptionsResult {
  final MergeMethod method;
  final bool deleteSource;
  final String? subject;
  final String? body;

  const MergeOptionsResult({
    required this.method,
    required this.deleteSource,
    this.subject,
    this.body,
  });
}

/// Phase-3 merge options sheet: method, delete-source, optional commit messages.
Future<MergeOptionsResult?> showMergeOptionsSheet(
  BuildContext context, {
  required MergePlan plan,
  required String title,
  required String summary,
  MergeMethod? initialMethod,
  bool showCommitMessages = true,
}) {
  return showMacosSheet<MergeOptionsResult>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => EscapeDismissible(
      child: _MergeOptionsBody(
        plan: plan,
        title: title,
        summary: summary,
        initialMethod: initialMethod ?? plan.defaultMethod,
        showCommitMessages: showCommitMessages,
      ),
    ),
  );
}

class _MergeOptionsBody extends StatefulWidget {
  final MergePlan plan;
  final String title;
  final String summary;
  final MergeMethod initialMethod;
  final bool showCommitMessages;

  const _MergeOptionsBody({
    required this.plan,
    required this.title,
    required this.summary,
    required this.initialMethod,
    required this.showCommitMessages,
  });

  @override
  State<_MergeOptionsBody> createState() => _MergeOptionsBodyState();
}

class _MergeOptionsBodyState extends State<_MergeOptionsBody> {
  late MergeMethod _method;
  late bool _deleteSource;
  final _subject = TextEditingController();
  final _body = TextEditingController();

  @override
  void initState() {
    super.initState();
    _method = widget.plan.allowedMethods.contains(widget.initialMethod)
        ? widget.initialMethod
        : widget.plan.defaultMethod;
    _deleteSource = widget.plan.defaultDeleteSource;
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final methods = widget.plan.allowedMethods;
    return SizedSheet(
      width: kSheetWidth,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: typography.title2),
            const SizedBox(height: 8),
            Text(widget.summary, style: typography.body),
            const SizedBox(height: 16),
            Text('Merge method', style: typography.headline),
            const SizedBox(height: 8),
            for (final m in methods)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    MacosRadioButton<MergeMethod>(
                      value: m,
                      groupValue: _method,
                      onChanged: (v) {
                        if (v != null) setState(() => _method = v);
                      },
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(mergeMethodLabel(m))),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                MacosCheckbox(
                  value: _deleteSource,
                  onChanged: (v) => setState(() => _deleteSource = v),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Delete source branch after merge'),
                ),
              ],
            ),
            if (widget.showCommitMessages) ...[
              const SizedBox(height: 16),
              Text(
                'Commit message (optional)',
                style: typography.headline,
              ),
              const SizedBox(height: 8),
              MacosTextField(
                controller: _subject,
                placeholder: 'Title',
                placeholderStyle: kAppPlaceholderStyle,
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
              ),
              const SizedBox(height: 8),
              MacosTextField(
                controller: _body,
                placeholder: 'Body',
                maxLines: 4,
                minLines: 2,
                placeholderStyle: kAppPlaceholderStyle,
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppPushButton(
                  controlSize: ControlSize.large,
                  secondary: true,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                AppPushButton(
                  controlSize: ControlSize.large,
                  onPressed: () {
                    final subj = _subject.text.trim();
                    final body = _body.text.trim();
                    Navigator.of(context).pop(
                      MergeOptionsResult(
                        method: _method,
                        deleteSource: _deleteSource,
                        subject: subj.isEmpty ? null : subj,
                        body: body.isEmpty ? null : body,
                      ),
                    );
                  },
                  child: const Text('Merge'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
