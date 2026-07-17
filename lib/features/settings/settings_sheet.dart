import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/keymap.dart';
import '../../core/settings/tool_health.dart';
import '../../core/ssh/environment_probe.dart';
import '../../core/storage/known_hosts_store.dart';
import '../common/actions.dart';
import '../common/buttons.dart';
import '../common/diff_view.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';
import 'environment_health_sheet.dart';
import 'keyboard_mappings_sheet.dart';

/// Preferences sheet: command timeouts, committer identity, default sync
/// behavior, and an optional background auto-fetch interval.
class SettingsSheet extends ConsumerStatefulWidget {
  const SettingsSheet({super.key});

  @override
  ConsumerState<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<SettingsSheet> {
  late final TextEditingController _network;
  late final TextEditingController _commit;
  late final TextEditingController _name;
  late final TextEditingController _email;
  late PullMode _pullMode;
  late bool _followTags;
  late int _autoFetch;
  late final Map<String, TextEditingController> _bin;

  // Null while the initial load is in flight; populated afterward and
  // refreshed after a "Forget" so the list stays in sync with the store.
  List<KnownHostRecord>? _knownHosts;

  // Auto-fetch interval choices (minutes; 0 = off).
  static const _fetchChoices = [0, 5, 10, 15, 30];

  // Timeout floor (seconds), mirroring AppSettingsNotifier's own clamp: a
  // 0-second (or blank) timeout would kill every git command outright. The
  // `digitsOnly` fields happily accept "0", so the UI must clamp too.
  static const _minTimeoutSecs = 5;

  @override
  void initState() {
    super.initState();
    final s = ref.read(appSettingsProvider);
    _network = TextEditingController(text: '${s.networkTimeout.inSeconds}');
    _commit = TextEditingController(text: '${s.commitTimeout.inSeconds}');
    _name = TextEditingController(text: s.committerName);
    _email = TextEditingController(text: s.committerEmail);
    _pullMode = s.defaultPullMode;
    _followTags = s.pushFollowTags;
    _autoFetch = _fetchChoices.contains(s.autoFetchMinutes)
        ? s.autoFetchMinutes
        : 0;
    _bin = {
      for (final b in AppSettingsNotifier.overridableBinaries)
        b: TextEditingController(text: s.binaryOverrides[b] ?? ''),
    };
    _loadKnownHosts();
  }

  Future<void> _loadKnownHosts() async {
    final hosts = await ref.read(knownHostsStoreProvider).list();
    if (mounted) setState(() => _knownHosts = hosts);
  }

  @override
  void dispose() {
    _network.dispose();
    _commit.dispose();
    _name.dispose();
    _email.dispose();
    for (final c in _bin.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final n = int.tryParse(_network.text.trim());
    final c = int.tryParse(_commit.text.trim());
    final notifier = ref.read(appSettingsProvider.notifier);
    // Clamp up to the floor before building the Duration (a blank field parses
    // to null and leaves the value unchanged) so a persisted timeout is never 0.
    Duration? floored(int? secs) => secs == null
        ? null
        : Duration(seconds: secs < _minTimeoutSecs ? _minTimeoutSecs : secs);
    await notifier.setTimeouts(network: floored(n), commit: floored(c));
    await notifier.setPreferences(
      committerName: _name.text,
      committerEmail: _email.text,
      defaultPullMode: _pullMode,
      pushFollowTags: _followTags,
      autoFetchMinutes: _autoFetch,
    );
    await notifier.setBinaryOverrides({
      for (final e in _bin.entries) e.key: e.value.text,
    });
    // Re-resolve the remote environment so new overrides take effect at once.
    await ref.read(connectionProvider.notifier).reprobeBinaries();
    if (mounted) Navigator.of(context).pop();
  }

  static String _pullLabel(PullMode m) => switch (m) {
    PullMode.ffOnly => 'Fast-forward only',
    PullMode.rebase => 'Rebase',
    PullMode.merge => 'Merge',
  };

  static String _fetchLabel(int m) => m == 0 ? 'Off' : 'Every $m min';

  /// Settings is slightly wider than the app-wide [kSheetWidth] so section
  /// blurbs and rows breathe; text fields keep the same fixed widths as before
  /// (see [_fieldWidth], [_textFieldWidth], [_binaryFieldWidth]).
  static const double _sheetWidth = kSheetWidth + 60;

  /// Horizontal content width at the previous [kSheetWidth] with 22px padding
  /// each side — used so Expanded fields do not grow when the sheet does.
  static const double _legacyContentWidth = kSheetWidth - 44; // 376

  static const double _fieldWidth = 96; // timeouts
  static const double _textFieldWidth =
      _legacyContentWidth - 60 - 12; // name/email: 304
  static const double _binaryFieldWidth =
      _legacyContentWidth - 84 - 8; // path field without status: 284

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return SizedSheet(
      width: _sheetWidth,
      child: SizedBox(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const MacosIcon(CupertinoIcons.gear, size: 18),
                  const SizedBox(width: 8),
                  Text('Settings', style: typography.title2),
                ],
              ),
              const SheetDescription(
                'App-wide preferences: command timeouts, who commits are '
                'authored as, default pull/push behavior, background '
                'fetching, trusted SSH hosts, and keyboard shortcuts. '
                'Changes apply after Save.',
              ),
              const SizedBox(height: 18),

              _section(
                context,
                'Command timeouts',
                'How long a command may run before it is considered hung and '
                    'killed. Raise these if a legitimately slow push or commit is '
                    'being cut off.',
              ),
              _fieldRow('Network (fetch/pull/push), seconds', _network),
              const SizedBox(height: 10),
              _fieldRow('Commit, seconds', _commit),

              const SizedBox(height: 20),
              _section(
                context,
                'Committer identity',
                'Applied to every commit as name/email, so commits are '
                    'authored correctly regardless of the remote host. Leave blank '
                    'to use the remote repository\'s own git config.',
              ),
              _textRow('Name', _name, 'e.g. Jane Developer'),
              const SizedBox(height: 10),
              _textRow('Email', _email, 'e.g. jane@example.com'),

              const SizedBox(height: 20),
              _section(
                context,
                'Default sync behavior',
                'What the plain Pull and Sync buttons do, and whether a plain '
                    'Push also pushes tags.',
              ),
              _rowLabelled(
                'Pull / Sync uses',
                MacosPulldownButton(
                  title: _pullLabel(_pullMode),
                  items: [
                    for (final m in PullMode.values)
                      MacosPulldownMenuItem(
                        title: Text(_pullLabel(m)),
                        onTap: () => setState(() => _pullMode = m),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _rowLabelled(
                'Push tags by default',
                MacosSwitch(
                  value: _followTags,
                  onChanged: (v) => setState(() => _followTags = v),
                ),
              ),

              const SizedBox(height: 20),
              _section(
                context,
                'Background auto-fetch',
                'Periodically fetch the active repository so ahead/behind '
                    'counts and remote branches stay current.',
              ),
              _rowLabelled(
                'Auto-fetch',
                MacosPulldownButton(
                  title: _fetchLabel(_autoFetch),
                  items: [
                    for (final m in _fetchChoices)
                      MacosPulldownMenuItem(
                        title: Text(_fetchLabel(m)),
                        onTap: () => setState(() => _autoFetch = m),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
              _knownHostsSection(context),

              const SizedBox(height: 20),
              _section(
                context,
                'Keyboard Mappings',
                'Shortcuts for common actions across the app. Customize to '
                    'replace or add bindings.',
              ),
              _keymapSummaryRow(context),

              const SizedBox(height: 20),
              _externalTools(context),

              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppPushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 10),
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
      ),
    );
  }

  Widget _keymapSummaryRow(BuildContext context) {
    final keymap = ref.watch(keymapProvider);
    final total = kKeymapActions.length;
    final customized = kKeymapActions
        .where(
          (a) => !listEquals(
            keymap[a.id] ?? const <KeyBinding>[],
            a.defaultBindings,
          ),
        )
        .length;
    return Row(
      children: [
        Expanded(
          child: Text(
            customized == 0
                ? '$total shortcuts'
                : '$total shortcuts, $customized customized',
            style: MacosTheme.of(context).typography.body,
          ),
        ),
        DiffActionButton(
          label: 'Customize',
          icon: CupertinoIcons.keyboard,
          tooltip: 'Customize keyboard mappings',
          onPressed: () => showMacosSheet<void>(
            context: context,
            builder: (_) =>
                const EscapeDismissible(child: KeyboardMappingsSheet()),
          ),
        ),
      ],
    );
  }

  Widget _knownHostsSection(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final hosts = _knownHosts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          context,
          'Known Hosts',
          'SSH host keys this app has trusted for previously-connected '
              'servers. Forget an entry if a host\'s key has legitimately '
              'changed (e.g. a server rebuild) — the next connection will '
              'trust whatever key it presents, with no warning.',
        ),
        if (hosts == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: ProgressCircle(radius: 8),
          )
        else if (hosts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'No trusted hosts yet.',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          )
        else
          for (final host in hosts) _knownHostRow(context, host),
      ],
    );
  }

  Widget _knownHostRow(BuildContext context, KnownHostRecord record) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${record.host}:${record.port}',
              style: typography.body,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            record.entry.keyType,
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          const SizedBox(width: 4),
          ToolIconButton(
            icon: CupertinoIcons.trash,
            tooltip: 'Forget this host key',
            color: MacosColors.systemRedColor,
            onPressed: () => _forgetKnownHost(record),
          ),
        ],
      ),
    );
  }

  Future<void> _forgetKnownHost(KnownHostRecord record) async {
    final ok = await confirmAction(
      context,
      title: 'Forget host key?',
      message:
          'The next connection to ${record.host}:${record.port} will trust '
          "whatever key it presents (trust-on-first-use), with no warning "
          "if it differs from the key currently on file. Only do this if "
          "you know the host's key legitimately changed.",
      confirmLabel: 'Forget',
    );
    if (!ok || !mounted) return;
    final done = await runAction(
      context,
      () => ref.read(knownHostsStoreProvider).forget(record.host, record.port),
    );
    if (done) await _loadKnownHosts();
  }

  Widget _externalTools(BuildContext context) {
    final env = ref.watch(binaryEnvironmentProvider);
    final detected = env.os == 'unknown'
        ? 'Connect to a repository to auto-detect the host and tool paths.'
        : 'Detected host: ${env.osLabel}. Common user paths (e.g. Homebrew) are '
              'searched before system paths. Leave a field blank to auto-detect; '
              'set a path to override.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(context, 'External tools', detected),
        _healthSummaryRow(context, env),
        const SizedBox(height: 12),
        for (final bin in AppSettingsNotifier.overridableBinaries)
          _binaryRow(context, bin, env),
      ],
    );
  }

  /// A one-line health summary plus a button into the full diagnostics panel.
  Widget _healthSummaryRow(BuildContext context, RemoteEnvironment env) {
    final typography = MacosTheme.of(context).typography;
    final (text, color) = _healthSummary(env);
    return Row(
      children: [
        Expanded(
          child: Text(text, style: typography.body.copyWith(color: color)),
        ),
        DiffActionButton(
          label: 'Scan',
          icon: CupertinoIcons.search,
          tooltip: 'Scan environment',
          onPressed: () => showMacosSheet<void>(
            context: context,
            builder: (_) =>
                const EscapeDismissible(child: EnvironmentHealthSheet()),
          ),
        ),
      ],
    );
  }

  /// One-line tool-health summary. Delegates the analysis to the shared
  /// [summarizeToolHealth] (also used by the main-window banner) and just picks
  /// a color — green when connected and all good, gray when disconnected.
  (String, Color) _healthSummary(RemoteEnvironment env) {
    final report = summarizeToolHealth(env);
    final color = switch (report.level) {
      ToolHealthLevel.error => MacosColors.systemRedColor,
      ToolHealthLevel.warning => MacosColors.systemOrangeColor,
      ToolHealthLevel.ok =>
        env.os == 'unknown'
            ? MacosColors.systemGrayColor
            : MacosColors.systemGreenColor,
    };
    return (report.message, color);
  }

  Widget _binaryRow(BuildContext context, String bin, RemoteEnvironment env) {
    final typography = MacosTheme.of(context).typography;
    final resolved = env.pathOf(bin);
    final overridden = env.overridden.contains(bin);
    final (statusText, statusColor) = switch ((resolved, overridden)) {
      (final p?, true) when p.isNotEmpty => (
        'override',
        MacosColors.systemBlueColor,
      ),
      (final p?, false) when p.isNotEmpty => (
        'found',
        MacosColors.systemGreenColor,
      ),
      _ when env.os != 'unknown' => (
        'not found',
        MacosColors.systemOrangeColor,
      ),
      _ => ('', MacosColors.systemGrayColor),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 84, child: Text(bin, style: typography.body)),
          const SizedBox(width: 8),
          // Fixed width so widening the sheet does not stretch path fields.
          SizedBox(
            width: statusText.isNotEmpty
                ? _binaryFieldWidth - 8 - 64 // room for status caption
                : _binaryFieldWidth,
            child: MacosTextField(
              controller: _bin[bin],
              placeholder: resolved != null && resolved.isNotEmpty
                  ? resolved
                  : '/path/to/$bin (optional)',
              placeholderStyle: kAppPlaceholderStyle,
              decoration: kAppTextFieldDecoration,
              focusedDecoration: kAppTextFieldFocusedDecoration,
            ),
          ),
          if (statusText.isNotEmpty) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 64,
              child: Text(
                statusText,
                textAlign: TextAlign.end,
                style: typography.caption1.copyWith(color: statusColor),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, String blurb) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: typography.headline),
          const SizedBox(height: 4),
          Text(
            blurb,
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowLabelled(String label, Widget control) {
    final typography = MacosTheme.of(context).typography;
    return Row(
      children: [
        Expanded(child: Text(label, style: typography.body)),
        const SizedBox(width: 12),
        control,
      ],
    );
  }

  Widget _fieldRow(String label, TextEditingController controller) {
    final typography = MacosTheme.of(context).typography;
    return Row(
      children: [
        Expanded(child: Text(label, style: typography.body)),
        const SizedBox(width: 12),
        SizedBox(
          width: _fieldWidth,
          child: MacosTextField(
            controller: controller,
            textAlign: TextAlign.end,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
          ),
        ),
      ],
    );
  }

  Widget _textRow(String label, TextEditingController controller, String hint) {
    final typography = MacosTheme.of(context).typography;
    return Row(
      children: [
        SizedBox(width: 60, child: Text(label, style: typography.body)),
        const SizedBox(width: 12),
        // Fixed width (not Expanded) so sheet widening leaves fields unchanged.
        SizedBox(
          width: _textFieldWidth,
          child: MacosTextField(
            controller: controller,
            placeholder: hint,
            placeholderStyle: kAppPlaceholderStyle,
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
          ),
        ),
      ],
    );
  }
}
