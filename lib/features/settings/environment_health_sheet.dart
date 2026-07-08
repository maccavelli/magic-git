import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/install_planner.dart';
import '../../core/settings/tool_catalog.dart';
import '../../core/ssh/environment_probe.dart';
import '../common/actions.dart';
import '../common/tool_icon_button.dart';

/// The health state of one tool for the current host.
enum _Health { ok, outdated, overridden, missing, unknown }

class _ToolStatus {
  final _Health health;
  final String? version; // detected x.y.z, when known
  const _ToolStatus(this.health, {this.version});
}

/// "Doctor" panel: for each external tool Magic Git uses, shows whether it's
/// present on the connected host, its version against the minimum we rely on,
/// and — when something's missing — either a one-click install (when a safe,
/// non-interactive command exists on this host) or copy-pasteable, platform-
/// aware commands to run manually. Re-check re-probes the live connection.
class EnvironmentHealthSheet extends ConsumerStatefulWidget {
  const EnvironmentHealthSheet({super.key});

  @override
  ConsumerState<EnvironmentHealthSheet> createState() =>
      _EnvironmentHealthSheetState();
}

class _EnvironmentHealthSheetState
    extends ConsumerState<EnvironmentHealthSheet> {
  /// What the host can install for us without prompts. Null until probed (or
  /// when disconnected); a null value simply hides the one-click affordance and
  /// leaves copy-paste guidance in place.
  HostCapabilities? _caps;

  /// The tool whose install is currently running, so its button shows progress
  /// and the others are disabled (installs serialize on the executor anyway).
  String? _runningBin;

  /// The tool whose sideload drop zone is currently under a file drag, so it
  /// can highlight and invite the drop.
  String? _dragOverBin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeCaps());
  }

  Future<void> _probeCaps() async {
    final conn = ref.read(connectionProvider);
    if (!conn.isConnected || conn.repoPath == null) return;
    try {
      final caps = await ref
          .read(installServiceProvider)
          .probeCapabilities(conn.repoPath!);
      if (mounted) setState(() => _caps = caps);
    } catch (_) {
      // Best-effort: leave _caps null and fall back to copy-paste guidance.
    }
  }

  Future<void> _recheck() async {
    await ref.read(connectionProvider.notifier).reprobeBinaries();
    await _probeCaps();
  }

  static _ToolStatus _statusFor(ToolSpec spec, RemoteEnvironment env) {
    if (env.os == 'unknown') return const _ToolStatus(_Health.unknown);
    if (!env.has(spec.bin)) return const _ToolStatus(_Health.missing);
    final vStr = env.versionOf(spec.bin);
    final v = vStr == null ? null : ToolVersion.parse(vStr);
    if (spec.minVersion != null && v != null && v < spec.minVersion!) {
      return _ToolStatus(_Health.outdated, version: v.display);
    }
    if (env.overridden.contains(spec.bin)) {
      return _ToolStatus(_Health.overridden, version: v?.display);
    }
    return _ToolStatus(_Health.ok, version: v?.display);
  }

  Future<void> _install(ToolSpec spec, InstallCommand plan) async {
    final ok = await confirmAction(
      context,
      title: 'Install ${spec.bin}?',
      message:
          '${plan.describe}\n\n'
          'This runs on the host; output appears in the Output view.',
      confirmLabel: 'Install',
    );
    if (!ok || !mounted) return;

    final conn = ref.read(connectionProvider);
    final repoPath = conn.repoPath;
    if (repoPath == null) return;
    final log = ref.read(outputLogProvider.notifier);
    log.setVisible(true);

    setState(() => _runningBin = spec.bin);
    try {
      final result = await ref
          .read(installServiceProvider)
          .run(repoPath, plan.command);
      log.logResult(plan.describe, result);
      if (result.isSuccess) {
        await ref.read(connectionProvider.notifier).reprobeBinaries();
        await _probeCaps();
      }
    } catch (e) {
      log.logError(plan.describe, e.toString());
    } finally {
      if (mounted) setState(() => _runningBin = null);
    }
  }

  /// Sideload flow: pick a binary/tarball from this machine, confirm, upload it
  /// to the host and install into ~/.local/bin. For air-gapped hosts that can't
  /// download for themselves.
  Future<void> _sideload(ToolSpec spec) async {
    final file = await openFile(
      acceptedTypeGroups: const [XTypeGroup(label: 'Binary or .tar.gz')],
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    await _sideloadBytes(spec, bytes, file.name);
  }

  /// A file dropped onto a tool's sideload zone: read it and run the same
  /// upload path as the file picker. Only the first item is used.
  Future<void> _onSideloadDrop(ToolSpec spec, DropDoneDetails detail) async {
    setState(() => _dragOverBin = null);
    if (_runningBin != null || detail.files.isEmpty) return;
    final dropped = detail.files.first;
    final log = ref.read(outputLogProvider.notifier);
    final Uint8List bytes;
    try {
      bytes = await dropped.readAsBytes();
    } catch (e) {
      log.logError(
        'sideload ${spec.bin}',
        "couldn't read the dropped file (a folder can't be sideloaded): $e",
      );
      return;
    }
    if (!mounted) return;
    // Fall back to the path's basename if the drop didn't carry a name.
    final name = dropped.name.isNotEmpty
        ? dropped.name
        : dropped.path.split(RegExp(r'[\\/]')).last;
    await _sideloadBytes(spec, bytes, name);
  }

  /// Shared tail of both sideload entry points (picker and drop): confirm the
  /// upload, stream it to the host, install to ~/.local/bin, then re-probe.
  Future<void> _sideloadBytes(
    ToolSpec spec,
    Uint8List bytes,
    String name,
  ) async {
    if (_runningBin != null) return; // an install is already in flight

    final ok = await confirmAction(
      context,
      title: 'Install ${spec.bin} from file?',
      message:
          'Upload "$name" (${_fmtSize(bytes.length)}) to the host and install '
          'it to ~/.local/bin.\n\n'
          'Output appears in the Output view.',
      confirmLabel: 'Install',
    );
    if (!ok || !mounted) return;

    final repoPath = ref.read(connectionProvider).repoPath;
    if (repoPath == null) return;
    final log = ref.read(outputLogProvider.notifier);
    log.setVisible(true);

    setState(() => _runningBin = spec.bin);
    try {
      final result = await ref
          .read(installServiceProvider)
          .sideload(
            repoPath: repoPath,
            bin: spec.bin,
            bytes: bytes,
            filename: name,
          );
      log.logResult('sideload ${spec.bin} ($name)', result);
      if (result.isSuccess) {
        await ref.read(connectionProvider.notifier).reprobeBinaries();
        await _probeCaps();
      }
    } catch (e) {
      log.logError('sideload ${spec.bin}', e.toString());
    } finally {
      if (mounted) setState(() => _runningBin = null);
    }
  }

  static String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final env = ref.watch(binaryEnvironmentProvider);
    final connected = ref.watch(connectionProvider).isConnected;
    final tools = kToolCatalog.where((t) => t.relevantOn(env.os)).toList();

    return MacosSheet(
      child: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 12),
              child: Row(
                children: [
                  const MacosIcon(CupertinoIcons.wrench, size: 18),
                  const SizedBox(width: 8),
                  Text('Environment health', style: typography.title2),
                  const Spacer(),
                  Text(
                    env.os == 'unknown'
                        ? 'Not connected'
                        : 'Host: ${env.osLabel}',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (env.os == 'unknown')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Connect to a repository to detect the host and check '
                          'which tools are installed.',
                          style: typography.caption1.copyWith(
                            color: MacosColors.systemGrayColor,
                          ),
                        ),
                      ),
                    for (final spec in tools)
                      _toolCard(
                        context,
                        spec,
                        _statusFor(spec, env),
                        env.os,
                        connected,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'File watchers (fswatch / inotifywait) are optional — '
                      'without one, Magic Git refreshes by polling every few '
                      'seconds instead of instantly. git is required; glab and '
                      'gh unlock GitLab and GitHub features.',
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemGrayColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: connected && _runningBin == null
                        ? _recheck
                        : null,
                    child: const Text('Re-check'),
                  ),
                  const SizedBox(width: 10),
                  PushButton(
                    controlSize: ControlSize.large,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolCard(
    BuildContext context,
    ToolSpec spec,
    _ToolStatus status,
    String os,
    bool connected,
  ) {
    final typography = MacosTheme.of(context).typography;
    final (badge, color) = _badge(spec, status);
    // Guidance is shown only when there's action to take, to keep healthy
    // tools quiet.
    final needsAction =
        status.health == _Health.missing || status.health == _Health.outdated;
    final hints = needsAction
        ? installHints(spec.bin, os)
        : const <InstallHint>[];

    // One-click install is offered only for a *missing* tool (upgrades are
    // messier and stay copy-paste), and only once we know the host can do it
    // without prompting.
    final plan = (status.health == _Health.missing && _caps != null)
        ? planInstall(spec.bin, os, _caps!)
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MacosColors.systemGrayColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(spec.bin, style: typography.headline),
              const SizedBox(width: 8),
              _tierChip(context, spec.tier),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  badge,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: typography.body.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            spec.purpose,
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          if (plan != null) _installAffordance(context, spec, plan),
          if (status.health == _Health.missing &&
              connected &&
              (os == 'linux' || os == 'macos') &&
              canSideload(spec.bin))
            _sideloadRow(context, spec, os),
          for (final hint in hints) _hintRow(context, hint),
        ],
      ),
    );
  }

  /// The one-click install row (when runnable) or the manual-only reason.
  Widget _installAffordance(
    BuildContext context,
    ToolSpec spec,
    InstallAction plan,
  ) {
    final typography = MacosTheme.of(context).typography;
    if (plan is InstallManual) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          plan.reason,
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
      );
    }
    final cmd = plan as InstallCommand;
    final running = _runningBin == spec.bin;
    final busy = _runningBin != null;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          PushButton(
            controlSize: ControlSize.regular,
            onPressed: busy ? null : () => _install(spec, cmd),
            child: running
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: ProgressCircle(radius: 7),
                  )
                : Text('Install with ${cmd.label}'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Runs: ${cmd.describe}',
              overflow: TextOverflow.ellipsis,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Air-gapped fallback: upload a binary/tarball from this machine, either by
  /// picking it or by dropping it onto this zone.
  Widget _sideloadRow(BuildContext context, ToolSpec spec, String os) {
    final typography = MacosTheme.of(context).typography;
    final busy = _runningBin != null;
    final dragging = _dragOverBin == spec.bin;
    const accent = MacosColors.systemBlueColor;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: DropTarget(
        enable: !busy,
        onDragEntered: (_) {
          if (!busy) setState(() => _dragOverBin = spec.bin);
        },
        onDragExited: (_) {
          if (_dragOverBin == spec.bin) setState(() => _dragOverBin = null);
        },
        onDragDone: (detail) => _onSideloadDrop(spec, detail),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: dragging ? accent.withValues(alpha: 0.10) : null,
            border: Border.all(
              color: dragging
                  ? accent
                  : MacosColors.systemGrayColor.withValues(alpha: 0.30),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              PushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: busy ? null : () => _sideload(spec),
                child: const Text('Install from file…'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  dragging
                      ? 'Drop to install ${spec.bin} on the host'
                      : 'Drag a file here, or no network on the host? '
                            '${sideloadAssetHint(spec.bin, os, _caps?.arch ?? '')}',
                  style: typography.caption1.copyWith(
                    color: dragging ? accent : MacosColors.systemGrayColor,
                    fontWeight: dragging ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hintRow(BuildContext context, InstallHint hint) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  hint.label,
                  style: typography.caption1.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ToolIconButton(
                icon: CupertinoIcons.doc_on_clipboard,
                tooltip: 'Copy command',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: hint.command)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: MacosColors.black.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              hint.command,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tierChip(BuildContext context, ToolTier tier) {
    final color = switch (tier) {
      ToolTier.essential => MacosColors.systemRedColor,
      ToolTier.feature => MacosColors.systemBlueColor,
      ToolTier.optional => MacosColors.systemGrayColor,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        tier.label,
        style: MacosTheme.of(
          context,
        ).typography.caption2.copyWith(color: color),
      ),
    );
  }

  /// The status badge text + color for a tool.
  (String, Color) _badge(ToolSpec spec, _ToolStatus status) {
    switch (status.health) {
      case _Health.ok:
        return (
          status.version != null ? 'OK · ${status.version}' : 'Installed',
          MacosColors.systemGreenColor,
        );
      case _Health.outdated:
        return (
          'Update · ${status.version} < ${spec.minVersion!.display}',
          MacosColors.systemOrangeColor,
        );
      case _Health.overridden:
        return (
          status.version != null ? 'Override · ${status.version}' : 'Override',
          MacosColors.systemBlueColor,
        );
      case _Health.missing:
        final color = switch (spec.tier) {
          ToolTier.essential => MacosColors.systemRedColor,
          ToolTier.feature => MacosColors.systemOrangeColor,
          ToolTier.optional => MacosColors.systemGrayColor,
        };
        return ('Not installed', color);
      case _Health.unknown:
        return ('Connect to check', MacosColors.systemGrayColor);
    }
  }
}
