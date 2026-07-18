import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/storage/saved_connection.dart';
import '../../core/storage/saved_local_repo.dart';
import '../common/buttons.dart';
import '../common/inline_action_button.dart';
import '../common/labeled_text_field.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';

/// What [EditConnectionSheet] pops on Save: the updated metadata, plus each
/// secret as typed — null meaning "the field was left blank, keep whatever is
/// stored". The caller resolves the keeps against the store and persists;
/// the sheet itself never reads or writes storage.
typedef EditConnectionResult = ({
  SavedConnection conn,
  String? password,
  String? privateKey,
  String? passphrase,
  String? gitlabToken,
  String? githubToken,
});

/// Card for editing a saved SSH connection — every profile field is editable.
/// Secrets are never shown back; a blank secret field keeps the stored value
/// (the same "blank means untouched" contract the connection form uses when
/// re-saving an existing profile).
class EditConnectionSheet extends StatefulWidget {
  final SavedConnection conn;

  const EditConnectionSheet({super.key, required this.conn});

  @override
  State<EditConnectionSheet> createState() => _EditConnectionSheetState();
}

class _EditConnectionSheetState extends State<EditConnectionSheet> {
  late final _label = TextEditingController(text: widget.conn.label);
  late final _host = TextEditingController(text: widget.conn.host);
  late final _port = TextEditingController(text: '${widget.conn.port}');
  late final _username = TextEditingController(text: widget.conn.username);
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
  final _gitlabToken = TextEditingController();
  final _githubToken = TextEditingController();

  String? _keyLoadError;

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    _gitlabToken.dispose();
    _githubToken.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_host.text.trim().isEmpty || _username.text.trim().isEmpty) {
      return false;
    }
    // Same port rule as the connection form: a real TCP port or nothing.
    final port = int.tryParse(_port.text.trim());
    return port != null && port >= 1 && port <= 65535;
  }

  /// Loads a private key from disk into the form — same rationale as the
  /// connection form: never route key material through the clipboard.
  Future<void> _loadPrivateKeyFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'SSH private key',
          // Any file is selectable — key files often have no extension.
        ),
      ],
    );
    if (file == null || !mounted) return;
    try {
      final contents = await File(file.path).readAsString();
      if (!mounted) return;
      setState(() {
        _privateKey.text = contents.trimRight();
        _keyLoadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _keyLoadError = 'Could not read key file: $e');
    }
  }

  void _save() {
    if (!_canSave) return;
    String? secret(String text) => text.isEmpty ? null : text;
    Navigator.of(context).pop<EditConnectionResult>((
      conn: widget.conn.copyWith(
        label: _label.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _username.text.trim(),
      ),
      password: secret(_password.text),
      privateKey: secret(_privateKey.text.trim()),
      passphrase: secret(_passphrase.text),
      gitlabToken: secret(_gitlabToken.text.trim()),
      githubToken: secret(_githubToken.text.trim()),
    ));
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? placeholder,
    bool obscure = false,
    int maxLines = 1,
    String? hint,
  }) {
    final field = LabeledTextField(
      label: label,
      controller: controller,
      placeholder: placeholder,
      obscure: obscure,
      maxLines: maxLines,
      onChanged: () => setState(() {}),
      padding: hint == null
          ? const EdgeInsets.only(bottom: 12)
          : EdgeInsets.zero,
    );
    if (hint == null) return field;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [field, FieldHint(hint)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return SizedSheet(
      width: kSheetWidth,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Edit connection', style: typography.title2),
            const SheetDescription(
              'Changes apply to the saved profile and take effect on the '
              'next connect — an active session is not interrupted. Secret '
              'fields are never shown back; leave one blank to keep what is '
              'stored.',
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _field(
                      'Label',
                      _label,
                      placeholder: '${widget.conn.username}@${widget.conn.host}',
                      hint: 'Shown in the Connections list; falls back to '
                          'user@host when empty.',
                    ),
                    _field('Host', _host, placeholder: 'gitlab.example.com'),
                    _field('Port', _port),
                    _field('Username', _username),
                    _field(
                      'Password',
                      _password,
                      obscure: true,
                      placeholder: 'Leave blank to keep current',
                    ),
                    _field(
                      'Private key (PEM)',
                      _privateKey,
                      maxLines: 4,
                      placeholder: 'Leave blank to keep current',
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        // The canonical inline action capsule (the diff views'
                        // Stage/Unstage/Discard button).
                        child: InlineActionButton(
                          label: 'Load private key…',
                          icon: CupertinoIcons.folder,
                          onPressed: _loadPrivateKeyFile,
                        ),
                      ),
                    ),
                    if (_keyLoadError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _keyLoadError!,
                          style: typography.caption1.copyWith(
                            color: MacosColors.systemOrangeColor,
                          ),
                        ),
                      ),
                    _field(
                      'Key passphrase',
                      _passphrase,
                      obscure: true,
                      placeholder: 'Leave blank to keep current',
                    ),
                    _field(
                      'GitLab token',
                      _gitlabToken,
                      obscure: true,
                      placeholder: 'Leave blank to keep current',
                    ),
                    _field(
                      'GitHub token',
                      _githubToken,
                      obscure: true,
                      placeholder: 'Leave blank to keep current',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
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
                  onPressed: _canSave ? _save : null,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Card for editing a saved local repository. The label (and fsmonitor) are
/// the editable fields; the folder itself is fixed by its security-scoped
/// access grant, so pointing at a different folder means removing and
/// re-adding the repository through the Finder picker.
class EditLocalRepoSheet extends StatefulWidget {
  final SavedLocalRepo repo;

  const EditLocalRepoSheet({super.key, required this.repo});

  @override
  State<EditLocalRepoSheet> createState() => _EditLocalRepoSheetState();
}

class _EditLocalRepoSheetState extends State<EditLocalRepoSheet> {
  late final _label = TextEditingController(text: widget.repo.label);
  late bool _fsmonitor = widget.repo.fsmonitorEnabled;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop<(String, bool)>((_label.text.trim(), _fsmonitor));
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return SizedSheet(
      width: kSheetWidth,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Edit repository', style: typography.title2),
            const SheetDescription(
              'Renames how this repository appears in the list — the folder '
              'on disk is not touched.',
            ),
            const SizedBox(height: 12),
            LabeledTextField(
              label: 'Label',
              controller: _label,
              placeholder: widget.repo.displayName,
              onChanged: () => setState(() {}),
              padding: EdgeInsets.zero,
            ),
            const FieldHint(
              'Shown in the Connections list; falls back to the folder name '
              'when empty.',
            ),
            const SizedBox(height: 12),
            Text('Folder', style: typography.caption1),
            const SizedBox(height: 4),
            Text(
              widget.repo.repoPath,
              style: typography.body.copyWith(
                color: MacosColors.systemGrayColor,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const FieldHint(
              'Fixed by its access grant — to use a different folder, remove '
              'this repository and add it again.',
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                ToolIconButton(
                  icon: _fsmonitor
                      ? CupertinoIcons.bolt_fill
                      : CupertinoIcons.bolt,
                  tooltip: _fsmonitor
                      ? 'Git fsmonitor on (click to disable)'
                      : 'Git fsmonitor off (click to enable)',
                  size: 15,
                  color: _fsmonitor
                      ? MacosColors.systemBlueColor
                      : MacosColors.systemGrayColor,
                  onPressed: () => setState(() => _fsmonitor = !_fsmonitor),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Enable git fsmonitor (faster status on large repos)',
                    style: typography.caption1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
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
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
