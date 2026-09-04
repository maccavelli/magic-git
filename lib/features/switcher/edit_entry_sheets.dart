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
                      placeholder:
                          '${widget.conn.username}@${widget.conn.host}',
                      hint:
                          'Shown in the Connections list; falls back to '
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

/// Card for editing one repository entry of a saved SSH connection — its
/// friendly label, its path on the host, and its fsmonitor preference. Unlike a
/// local repo (whose folder is pinned by a security-scoped grant), a remote
/// entry is just a path string, so the path itself is editable here: repointing
/// it at a moved/renamed directory carries the label and fsmonitor across.
/// Pops `(label, path, fsmonitor)`; the caller persists and applies fsmonitor.
/// What [EditRemoteRepoSheet] returns. A named record rather than a positional
/// tuple: it grew a fourth member (gitDir), and positional members are exactly
/// how a caller silently swaps two same-typed fields.
typedef EditRemoteRepoResult = ({
  String label,
  String path,
  bool fsmonitor,
  String gitDir,
});

class EditRemoteRepoSheet extends StatefulWidget {
  final SavedConnection conn;
  final String repo;

  const EditRemoteRepoSheet({
    super.key,
    required this.conn,
    required this.repo,
  });

  @override
  State<EditRemoteRepoSheet> createState() => _EditRemoteRepoSheetState();
}

class _EditRemoteRepoSheetState extends State<EditRemoteRepoSheet> {
  late final _label = TextEditingController(
    text: widget.conn.repoLabelFor(widget.repo),
  );
  late final _path = TextEditingController(text: widget.repo);
  late final _gitDir = TextEditingController(
    text: widget.conn.scopedGitDirFor(widget.repo),
  );
  late bool _fsmonitor = widget.conn.fsmonitorEnabledFor(widget.repo);

  /// Whether this entry is a scoped (bare/dotfiles) repo. Only such an entry
  /// has a git-dir to edit, so the field is hidden otherwise rather than
  /// offering an input that would mean nothing.
  bool get _scoped => widget.conn.scopedGitDirFor(widget.repo).isNotEmpty;

  @override
  void dispose() {
    _label.dispose();
    _path.dispose();
    _gitDir.dispose();
    super.dispose();
  }

  // A repo entry must point at an absolute path on the host, same rule the
  // old path-only prompt enforced.
  bool get _canSave {
    if (!_path.text.trim().startsWith('/')) return false;
    // A scoped entry without a git-dir is not scoped at all — every command
    // for it would run unscoped and fail "not a git repository". Blank is only
    // valid for an ordinary repo.
    if (_scoped && !_gitDir.text.trim().startsWith('/')) return false;
    return true;
  }

  void _save() {
    if (!_canSave) return;
    Navigator.of(context).pop<EditRemoteRepoResult>((
      label: _label.text.trim(),
      path: _path.text.trim(),
      fsmonitor: _fsmonitor,
      gitDir: _gitDir.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return SizedSheet(
      width: kSheetWidth,
      child: Padding(
        padding: const EdgeInsets.all(20),
        // Scrolls because this sheet grew a conditional git-dir field and
        // overflowed its fixed height for scoped repos. Same remedy
        // AddExistingRepoSheet took when it gained its scoped rows — the
        // sheet keeps one size and the content fits inside it.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Edit repository', style: typography.title2),
              const SheetDescription(
                'Changes apply to the saved connection. Repointing the path aims '
                'this entry at a different directory on the host — nothing is '
                'moved or renamed there, and an active session keeps running '
                'until the next connect.',
              ),
              const SizedBox(height: 12),
              LabeledTextField(
                label: 'Label',
                controller: _label,
                placeholder: widget.conn.repoDisplayName(widget.repo),
                onChanged: () => setState(() {}),
                padding: EdgeInsets.zero,
              ),
              const FieldHint(
                'Shown in the Connections list; falls back to the folder name '
                'when empty.',
              ),
              const SizedBox(height: 12),
              LabeledTextField(
                label: 'Path on the host',
                controller: _path,
                placeholder: '/srv/git/my-project',
                onChanged: () => setState(() {}),
                padding: EdgeInsets.zero,
              ),
              FieldHint(
                _scoped
                    // Scope-aware: for a dotfiles repo the work tree does NOT
                    // contain .git, so the old wording described the wrong thing.
                    ? 'Absolute path to the work tree on the host — for this '
                          'scoped repo, the folder the tracked files live in.'
                    : 'Absolute path to the repository\'s root folder on the '
                          'host (the one containing .git).',
              ),
              if (_scoped) ...[
                const SizedBox(height: 12),
                LabeledTextField(
                  label: 'Git directory',
                  controller: _gitDir,
                  placeholder: '/home/you/.home.git',
                  onChanged: () => setState(() {}),
                  padding: EdgeInsets.zero,
                ),
                const FieldHint(
                  'Absolute path to this scoped repo\'s git directory. Applies '
                  'on the next connect, like the path itself. Previously a '
                  'git-dir that had genuinely moved could only be corrected by '
                  'deleting the entry and adding it again.',
                ),
              ],
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
                    onPressed: _canSave ? _save : null,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
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
