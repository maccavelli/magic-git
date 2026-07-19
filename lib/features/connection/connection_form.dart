import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../../core/ssh/ssh_client_manager.dart';
import '../../core/storage/saved_connection.dart';
import '../common/buttons.dart';
import '../common/field_styles.dart';
import '../common/inline_action_button.dart';
import '../common/labeled_text_field.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';

/// Connection form: collects SSH details + a remote repo path and drives
/// [ConnectionController.connect]. Profiles can be saved — metadata to
/// shared_preferences, the password to the macOS Keychain.
///
/// Sheet-hosted (via the Connections Manager's "Add connection" action, like
/// its sibling add/clone/create sheets). Connecting supersedes the current
/// session in this window — [ConnectionController.connect] owns that
/// teardown — and a successful connect dismisses the sheet, revealing the
/// workspace it just opened.
class ConnectionForm extends ConsumerStatefulWidget {
  const ConnectionForm({super.key});

  @override
  ConsumerState<ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends ConsumerState<ConnectionForm> {
  final _label = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
  final _repoPath = TextEditingController();
  final _gitDir = TextEditingController();
  final _gitlabToken = TextEditingController();
  final _githubToken = TextEditingController();

  bool _save = true;

  /// Scoped work-tree (dotfiles) repo: [_repoPath] is the work tree and
  /// [_gitDir] the external git-dir. Registers GIT_DIR/GIT_WORK_TREE and runs
  /// the watcher bounded — see `bounded_watch.dart`.
  bool _scoped = false;
  String? _saveWarning;

  // Guards the window between tapping Connect and `connect()` flipping the
  // phase to `connecting` (which swaps the button for a spinner). The pre-connect
  // Keychain save is awaited first, so without this a double-tap on a slow write
  // fires two saves and two concurrent connect attempts.
  bool _submitting = false;

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    _repoPath.dispose();
    _gitDir.dispose();
    _gitlabToken.dispose();
    _githubToken.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (_host.text.trim().isEmpty ||
        _username.text.trim().isEmpty ||
        _repoPath.text.trim().isEmpty) {
      return false;
    }
    // A scoped repo needs its external git-dir — without it there's nothing to
    // target and the toggle is meaningless.
    if (_scoped && _gitDir.text.trim().isEmpty) return false;
    // A profile with no auth method at all can never authenticate — require a
    // password or a private key before enabling Connect. A passphrase alone
    // (with no key for it to unlock) is never sufficient by itself; it only
    // matters when paired with a key, so it doesn't factor in here.
    final hasAuth =
        _password.text.isNotEmpty || _privateKey.text.trim().isNotEmpty;
    if (!hasAuth) return false;
    // Port must be a real TCP port; `int.tryParse` alone accepted any digit
    // string (and _submit silently fell back to 22 for a bad one).
    final port = int.tryParse(_port.text.trim());
    return port != null && port >= 1 && port <= 65535;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await _doSubmit();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Loads a private key from disk into the form. Prefer this over pasting PEM
  /// so users never copy key material into the clipboard. Contents stay in the
  /// text field (and Keychain when saved) — dartssh2 authenticates from PEM,
  /// not from ssh-agent.
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
        // A non-empty key enables Connect even without a password.
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saveWarning = 'Could not read key file: $e';
      });
    }
  }

  Future<void> _doSubmit() async {
    final repoPath = _repoPath.text.trim();
    final token = _gitlabToken.text.trim();
    final ghToken = _githubToken.text.trim();
    final key = _privateKey.text.trim();
    final gitDir = _scoped ? _gitDir.text.trim() : '';
    final profile = SSHConnectionProfile(
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      username: _username.text.trim(),
      password: _password.text.isEmpty ? null : _password.text,
      privateKey: key.isEmpty ? null : key,
      passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
    );

    var repoPaths = SavedConnection.dedupePaths([repoPath]);
    // The scope map passed to connect(), and persisted when saving. Starts with
    // just this repo's scope; the save branch merges in the profile's other
    // repos' scopes so a re-save never drops them.
    var scopedGitDirs = <String, String>{
      if (gitDir.isNotEmpty) repoPath: gitDir,
    };
    String? connectionId;
    String? connectionLabel;

    if (_save) {
      // Reuse an existing saved profile for the same host+user (update in
      // place) so re-connecting never piles up duplicates, and its repo list is
      // preserved.
      final existing = ref.read(savedConnectionsProvider).value ?? const [];
      SavedConnection? match;
      for (final c in existing) {
        if (c.host == profile.host && c.username == profile.username) {
          match = c;
          break;
        }
      }
      final id = match?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
      repoPaths = SavedConnection.dedupePaths([
        repoPath,
        ...?match?.allRepoPaths,
      ]);
      // Merge into the profile's existing scopes: set this repo's git-dir when
      // the toggle is on, else clear any stale scope for it.
      scopedGitDirs = Map<String, String>.from(
        match?.scopedGitDirs ?? const {},
      );
      if (gitDir.isNotEmpty) {
        scopedGitDirs[repoPath] = gitDir;
      } else {
        scopedGitDirs.remove(repoPath);
      }
      final conn = SavedConnection(
        id: id,
        label: _label.text.trim(),
        host: profile.host,
        port: profile.port,
        username: profile.username,
        repoPath: repoPath,
        repoPaths: repoPaths,
        fsmonitorPaths: match?.fsmonitorPaths ?? const [],
        repoLabels: match?.repoLabels ?? const {},
        scopedGitDirs: scopedGitDirs,
        lastConnectedAt: match?.lastConnectedAt,
      );
      // Saving is best-effort: the Keychain is unavailable on an unsigned build
      // (write throws), and that must never block the actual connection.
      try {
        final store = ref.read(connectionStoreProvider);
        // A blank field means "leave this credential untouched" — same as the
        // null-coalescing used to build `profile` above. Unlike `profile`,
        // though, `ConnectionStore.save`/`_writeSecret` treats a null secret
        // the same as an empty one (both delete the stored entry), so
        // "untouched" for an existing profile has to mean re-supplying
        // whatever is already stored rather than passing null/empty through.
        final secretToSave = _password.text.isNotEmpty
            ? _password.text
            : (match != null ? await store.secretFor(match.id) : null);
        final keyToSave = key.isNotEmpty
            ? key
            : (match != null ? await store.privateKeyFor(match.id) : null);
        final passphraseToSave = _passphrase.text.isNotEmpty
            ? _passphrase.text
            : (match != null ? await store.passphraseFor(match.id) : null);
        final tokenToSave = token.isNotEmpty
            ? token
            : (match != null ? await store.gitlabTokenFor(match.id) : null);
        final ghTokenToSave = ghToken.isNotEmpty
            ? ghToken
            : (match != null ? await store.githubTokenFor(match.id) : null);
        await store.save(
          conn,
          secret: secretToSave,
          gitlabToken: tokenToSave,
          githubToken: ghTokenToSave,
          privateKey: keyToSave,
          passphrase: passphraseToSave,
        );
        if (!mounted) return;
        ref.invalidate(savedConnectionsProvider);
        _saveWarning = null;
      } catch (e) {
        if (mounted) {
          setState(() {
            _saveWarning =
                'Could not save connection profile — proceeding to connect '
                'anyway. ($e)';
          });
        }
      }
      if (!mounted) return;
      connectionId = id;
      connectionLabel = conn.displayName;
    }

    final nav = Navigator.of(context);
    await ref
        .read(connectionProvider.notifier)
        .connect(
          profile: profile,
          repoPath: repoPath,
          gitlabToken: token,
          githubToken: ghToken,
          connectionId: connectionId,
          connectionLabel: connectionLabel,
          repoPaths: repoPaths,
          scopedGitDirs: scopedGitDirs,
        );
    if (!mounted) return;
    // Success: the workspace is live behind this sheet — dismiss it. Stay open
    // on failure (the error renders under the button) and when the profile
    // save failed (the warning must stay readable; the user closes manually).
    if (ref.read(connectionProvider).isConnected && _saveWarning == null) {
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final (phase, error) = ref.watch(
      connectionProvider.select((c) => (c.phase, c.error)),
    );
    final typography = MacosTheme.of(context).typography;

    return SizedSheet(
      width: kSheetWidth,
      // Scroll when the content exceeds the sheet's max height (SizedSheet
      // caps it near the window height) — this is the app's tallest form.
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Add SSH Remote',
                    style: typography.title2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ToolIconButton(
                  icon: CupertinoIcons.xmark,
                  tooltip: 'Close',
                  size: 16,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SheetDescription(
              'Connects to a Git repository on a remote host over SSH — '
              'the repository stays on the host and every git command '
              'runs there. Sign in with a password or a private key.',
            ),
            const SizedBox(height: 16),
            _field(
              'Host',
              _host,
              placeholder: 'gitlab.example.com',
              hint: 'Host name or IP address of the SSH server.',
            ),
            _field(
              'Port',
              _port,
              hint: '22 unless the host uses a custom SSH port.',
            ),
            _field(
              'Username',
              _username,
              hint: 'The account to sign in as on the host.',
            ),
            _field(
              'Password',
              _password,
              obscure: true,
              hint: 'For password sign-in — leave blank when using a key.',
            ),
            _field(
              'Private key (PEM)',
              _privateKey,
              placeholder: 'Load a key file or paste PEM (optional)',
              maxLines: 5,
              hint:
                  'Key-based sign-in; kept in secure storage when the '
                  'connection is saved. Prefer loading from disk over paste.',
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InlineActionButton(
                  label: 'Load private key…',
                  icon: CupertinoIcons.folder,
                  onPressed: _submitting ? null : _loadPrivateKeyFile,
                ),
              ),
            ),
            _field(
              'Key passphrase',
              _passphrase,
              obscure: true,
              hint: 'Only needed when the private key is encrypted.',
            ),
            if (_passphrase.text.isNotEmpty &&
                _privateKey.text.trim().isEmpty) ...[
              Text(
                'Passphrase requires a private key',
                style: typography.caption1.copyWith(
                  color: MacosColors.systemOrangeColor,
                ),
              ),
              const SizedBox(height: 12),
            ],
            _field(
              'Repository path',
              _repoPath,
              placeholder: '/srv/git/my-project',
              hint:
                  'Absolute path of the repository to open after '
                  'connecting.',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                MacosSwitch(
                  value: _scoped,
                  onChanged: (v) => setState(() => _scoped = v),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Scoped work-tree repo (dotfiles)',
                    style: typography.body,
                  ),
                ),
              ],
            ),
            const FieldHint(
              'For a bare / separate-git-dir repo whose work tree is the path '
              'above — e.g. a ~/.home.git dotfiles repo with \$HOME as its '
              'work tree. Targets the external git-dir and watches only '
              'tracked files, never the whole tree.',
            ),
            if (_scoped) ...[
              const SizedBox(height: 8),
              _field(
                'Git directory',
                _gitDir,
                placeholder: '/home/you/.home.git',
                hint:
                    'Absolute path of the external git-dir (GIT_DIR). The '
                    'repository path above is used as the work tree '
                    '(GIT_WORK_TREE).',
              ),
            ],
            _field(
              'GitLab token',
              _gitlabToken,
              placeholder: 'glpat-… (optional)',
              obscure: true,
              hint:
                  'Optional personal access token — signs glab in on '
                  'the host so merge requests and pipelines work.',
            ),
            _field(
              'GitHub token',
              _githubToken,
              placeholder: 'ghp_… / github_pat_… (optional)',
              obscure: true,
              hint:
                  'Optional personal access token — signs gh in on the '
                  'host so pull requests and Actions work.',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                MacosSwitch(
                  value: _save,
                  onChanged: (v) => setState(() => _save = v),
                ),
                const SizedBox(width: 8),
                Text('Save connection', style: typography.body),
                if (_save) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: MacosTextField(
                      controller: _label,
                      placeholder: 'Label (optional)',
                      placeholderStyle: kAppPlaceholderStyle,
                      decoration: kAppTextFieldDecoration,
                      focusedDecoration: kAppTextFieldFocusedDecoration,
                    ),
                  ),
                ],
              ],
            ),
            const FieldHint(
              'Stores this connection — secrets in secure storage — so it '
              'appears in the Connections list for one-click reconnects.',
            ),
            const SizedBox(height: 20),
            if (phase == ConnectionPhase.connecting)
              const Center(child: ProgressCircle())
            else
              AppPushButton(
                controlSize: ControlSize.large,
                onPressed: (_canSubmit && !_submitting) ? _submit : null,
                child: const Text('Connect'),
              ),
            if (_saveWarning != null) ...[
              const SizedBox(height: 12),
              Text(
                _saveWarning!,
                style: typography.body.copyWith(
                  color: MacosColors.systemOrangeColor,
                ),
              ),
            ],
            if (phase == ConnectionPhase.error && error != null) ...[
              const SizedBox(height: 16),
              Text(
                error,
                style: typography.body.copyWith(
                  color: MacosColors.systemRedColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
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
      // The hint supplies the bottom spacing when present.
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
}
