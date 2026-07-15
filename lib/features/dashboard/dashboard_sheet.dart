import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/exec/command_telemetry.dart';
import '../../core/forge/auth_status.dart';
import '../../core/forge/forge.dart';
import '../../core/git/watch_event.dart';
import '../../core/providers/app_providers.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';

/// The Dashboard — a live overview of the current session: connection
/// details and uptime, link latency, repository state, commit activity,
/// command throughput and wire savings, watcher/tool/forge health, and an
/// on-demand object-store footprint.
///
/// Opened from "View → Dashboard View" (checkable), the sheet's X, and Esc
/// all route through [dashboardVisibleProvider], so the menu checkmark and
/// the sheet can never disagree. Every section renders independently — one
/// slow probe never blocks the rest.
class DashboardSheet extends ConsumerStatefulWidget {
  const DashboardSheet({super.key});

  @override
  ConsumerState<DashboardSheet> createState() => _DashboardSheetState();
}

class _DashboardSheetState extends ConsumerState<DashboardSheet> {
  bool _footprintRequested = false;

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final connection = ref.watch(connectionProvider);
    final repoPath = connection.isConnected ? connection.repoPath : null;

    return SizedSheet(
      // Wider than the standard sheet — same exemption class as the
      // file/diff views: charts and stat rows need the horizontal room.
      width: 640,
      height: (MediaQuery.sizeOf(context).height - 60).clamp(460.0, 760.0),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const MacosIcon(CupertinoIcons.gauge, size: 18),
                const SizedBox(width: 8),
                Text('Dashboard', style: typography.title2),
                const Spacer(),
                ToolIconButton(
                  icon: CupertinoIcons.xmark,
                  tooltip: 'Close',
                  size: 15,
                  onPressed: _close,
                ),
              ],
            ),
            const SheetDescription(
              'A live overview of the current session — connection health, '
              'repository state, and what the SSH layer is doing under the '
              'hood. Metrics reset when a new session connects.',
            ),
            const SizedBox(height: 12),
            Expanded(
              child: connection.isConnected
                  ? SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _connectionCard(typography, connection),
                          const SizedBox(height: 14),
                          _authSection(typography, connection),
                          const SizedBox(height: 14),
                          if (!connection.isLocal) ...[
                            _latencySection(typography),
                            const SizedBox(height: 14),
                          ],
                          if (repoPath != null) ...[
                            _repoSection(typography, repoPath),
                            const SizedBox(height: 14),
                            _activitySection(typography, repoPath),
                            const SizedBox(height: 14),
                          ],
                          _commandsSection(typography),
                          const SizedBox(height: 14),
                          if (repoPath != null) ...[
                            _watcherSection(typography, repoPath),
                            const SizedBox(height: 14),
                          ],
                          _toolsSection(typography),
                          if (repoPath != null) ...[
                            const SizedBox(height: 14),
                            _forgeSection(typography, repoPath),
                            const SizedBox(height: 14),
                            _footprintSection(typography, repoPath),
                          ],
                          const SizedBox(height: 6),
                        ],
                      ),
                    )
                  : Center(
                      child: Text(
                        'Not connected — connect to a workspace to see '
                        'session metrics.',
                        style: typography.body.copyWith(
                          color: MacosColors.systemGrayColor,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Sections -----------------------------------------------------------

  Widget _sectionTitle(MacosTypography typography, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title,
      style: typography.caption1.copyWith(
        fontWeight: FontWeight.bold,
        color: MacosColors.systemGrayColor,
      ),
    ),
  );

  Widget _connectionCard(
    MacosTypography typography,
    ConnectionState connection,
  ) {
    final rows = <(String, String)>[
      (
        'Backend',
        connection.isLocal ? 'Local (this Mac)' : 'SSH',
      ),
      if (!connection.isLocal && connection.host != null)
        ('Host', connection.host!),
      if (connection.connectionLabel != null)
        ('Connection', connection.connectionLabel!),
      if (connection.repoPath != null) ('Repository', connection.repoPath!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(typography, 'Connection'),
        for (final (label, value) in rows) _kvRow(typography, label, value),
        // Self-ticking: uptime is the only value on the whole sheet that
        // changes with wall-clock time alone, so it owns its own 1s timer —
        // a sheet-wide ticker would rebuild every section (including the
        // O(commits) activity aggregation and both charts) once per second
        // just to advance this one line.
        if (connection.connectedAt != null)
          _UptimeRow(
            connectedAt: connection.connectedAt!,
            typography: typography,
          ),
        if (connection.reconnecting)
          _kvRow(
            typography,
            'Reconnecting',
            'attempt ${connection.reconnectAttempt}',
          ),
      ],
    );
  }

  /// Auth status of git/gh/glab on this Mac and (when the active session is a
  /// remote host) that host too — so a signed-out CLI is visible here instead
  /// of surfacing only as a failed create/clone. Each target renders
  /// independently; a slow probe never blocks the rest of the dashboard.
  Widget _authSection(MacosTypography typography, ConnectionState connection) {
    final local = ref
        .watch(localAuthStatusProvider)
        .whenData<TargetAuth?>((a) => a);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(typography, 'Authentication'),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Whether git, gh, and glab are installed and signed in — on this '
            'Mac and on the connected host. A create or clone needs the '
            "target's CLI signed in to the forge host it publishes to.",
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
        ),
        _authTargetTile(typography, local, fallbackLabel: 'This Mac'),
        // Only show — and only PROBE — the session target when it is a
        // remote host: a local session is already covered by the This-Mac
        // tile, and watching the provider unconditionally would run three
        // duplicate probes (two of them network calls) for a tile that is
        // never rendered.
        if (!connection.isLocal) ...[
          const SizedBox(height: 10),
          _authTargetTile(
            typography,
            ref.watch(sessionAuthStatusProvider),
            fallbackLabel: connection.connectionLabel ??
                connection.host ??
                'Connected host',
          ),
        ],
      ],
    );
  }

  Widget _authTargetTile(
    MacosTypography typography,
    AsyncValue<TargetAuth?> value,
    {required String fallbackLabel}) {
    return value.when(
      loading: () => _authTargetHeaderRow(
        typography,
        fallbackLabel,
        trailing: const SizedBox(
          width: 14,
          height: 14,
          child: ProgressCircle(radius: 7),
        ),
      ),
      error: (err, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _authTargetHeaderRow(typography, fallbackLabel),
          Text(
            'Could not check: $err',
            style: typography.caption1.copyWith(
              color: MacosColors.systemOrangeColor,
            ),
          ),
        ],
      ),
      data: (auth) {
        if (auth == null) {
          return _authTargetHeaderRow(
            typography,
            fallbackLabel,
            trailing: Text(
              'not connected',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _authTargetHeaderRow(typography, auth.label),
            for (final tool in auth.tools)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _authToolRow(typography, tool),
              ),
          ],
        );
      },
    );
  }

  Widget _authTargetHeaderRow(
    MacosTypography typography,
    String label, {
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: typography.body.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _authToolRow(MacosTypography typography, ToolAuth tool) {
    final color = switch (tool.level) {
      ToolAuthLevel.ok => MacosColors.systemGreenColor,
      ToolAuthLevel.warn => MacosColors.systemOrangeColor,
      ToolAuthLevel.bad => MacosColors.systemRedColor,
      // The check itself didn't complete — neutral, not an accusation.
      ToolAuthLevel.unknown => MacosColors.systemGrayColor,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        MacosIcon(CupertinoIcons.circle_fill, size: 8, color: color),
        const SizedBox(width: 8),
        SizedBox(
          width: 44,
          child: Text(
            tool.tool,
            style: typography.body.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
        Expanded(
          child: Text(
            tool.detail,
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _latencySection(MacosTypography typography) {
    final samples = ref.watch(pingSamplesProvider);
    final current = samples.isEmpty ? null : samples.last;
    final avg = samples.isEmpty
        ? null
        : Duration(
            microseconds:
                samples.fold<int>(0, (n, s) => n + s.inMicroseconds) ~/
                samples.length,
          );
    // Read fresh on every rebuild (each ping sample, ≤15 s): dual-client can
    // degrade mid-session when the stream connection dies and its slot falls
    // back to the command client — a state that was previously invisible.
    final degraded = ref
        .read(sshClientManagerProvider)
        .streamClientDegraded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(typography, 'Link latency (SSH keepalive)'),
        Row(
          children: [
            _stat(
              typography,
              current == null ? '—' : '${current.inMilliseconds} ms',
              'current',
            ),
            const SizedBox(width: 24),
            _stat(
              typography,
              avg == null ? '—' : '${avg.inMilliseconds} ms',
              'average',
            ),
            const SizedBox(width: 24),
            _stat(
              typography,
              degraded ? 'single' : 'dual',
              'ssh clients',
              color: degraded ? MacosColors.systemOrangeColor : null,
            ),
            const SizedBox(width: 24),
            Expanded(
              child: SizedBox(
                height: 30,
                child: samples.length < 2
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Collecting… one sample every 15 s',
                          style: typography.caption1.copyWith(
                            color: MacosColors.systemGrayColor,
                          ),
                        ),
                      )
                    : _Sparkline(
                        values: [
                          for (final s in samples)
                            s.inMicroseconds.toDouble(),
                        ],
                        color: MacosColors.systemBlueColor,
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _repoSection(MacosTypography typography, String repoPath) {
    final status = ref.watch(statusProvider(repoPath)).value;
    if (status == null) {
      return _loadingSection(typography, 'Repository');
    }
    final branch = status.branch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(typography, 'Repository'),
        Row(
          children: [
            _stat(typography, branch.head ?? 'detached', 'branch'),
            const SizedBox(width: 24),
            _stat(
              typography,
              branch.hasUpstream
                  ? '↑${branch.ahead} ↓${branch.behind}'
                  : 'no upstream',
              'ahead / behind',
            ),
            const SizedBox(width: 24),
            _stat(typography, '${status.staged.length}', 'staged'),
            const SizedBox(width: 24),
            _stat(typography, '${status.unstaged.length}', 'unstaged'),
            const SizedBox(width: 24),
            _stat(typography, '${status.untracked.length}', 'untracked'),
            if (status.hasConflicts) ...[
              const SizedBox(width: 24),
              _stat(
                typography,
                '${status.conflicted.length}',
                'conflicts',
                color: MacosColors.systemRedColor,
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _activitySection(MacosTypography typography, String repoPath) {
    final commits = ref.watch(logProvider(repoPath)).value;
    if (commits == null) {
      return _loadingSection(typography, 'Commit activity (30 days)');
    }
    final now = DateTime.now();
    final buckets = List<double>.filled(30, 0);
    final byAuthor = <String, int>{};
    for (final c in commits) {
      final date = DateTime.tryParse(c.date);
      if (date != null) {
        final age = now.difference(date).inDays;
        if (age >= 0 && age < 30) {
          buckets[29 - age] += 1;
          byAuthor[c.authorName] = (byAuthor[c.authorName] ?? 0) + 1;
        }
      }
    }
    final total = buckets.fold<double>(0, (n, v) => n + v).toInt();
    final authors = byAuthor.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(typography, 'Commit activity (30 days)'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _stat(typography, '$total', 'commits'),
            const SizedBox(width: 24),
            Expanded(
              child: SizedBox(
                height: 36,
                child: _Bars(
                  values: buckets,
                  color: MacosColors.systemBlueColor,
                ),
              ),
            ),
          ],
        ),
        if (authors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Top authors: ${authors.take(3).map((e) => '${e.key} '
                  '(${e.value})').join(' · ')}',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _commandsSection(MacosTypography typography) {
    return ListenableBuilder(
      listenable: CommandTelemetry.instance,
      builder: (context, _) {
        final t = CommandTelemetry.instance;
        final saved = t.compressedBytes - t.compressedWireBytes;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionTitle(typography, 'Commands (this session)'),
            Row(
              children: [
                _stat(typography, '${t.commandCount}', 'commands'),
                const SizedBox(width: 24),
                _stat(
                  typography,
                  t.commandCount == 0
                      ? '—'
                      : '${t.averageDuration.inMilliseconds} ms',
                  'avg',
                ),
                const SizedBox(width: 24),
                _stat(
                  typography,
                  t.commandCount == 0
                      ? '—'
                      : '${t.p95Duration.inMilliseconds} ms',
                  'p95',
                ),
                const SizedBox(width: 24),
                _stat(typography, _fmtBytes(t.totalWireBytes), 'received'),
                const SizedBox(width: 24),
                _stat(
                  typography,
                  saved > 0 ? _fmtBytes(saved) : '—',
                  'gzip saved',
                  color: saved > 0 ? MacosColors.systemGreenColor : null,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _watcherSection(MacosTypography typography, String repoPath) {
    final event = ref.watch(repoWatchProvider(repoPath)).value;
    final mode = event?.mode;
    final (label, color) = switch (mode) {
      WatchMode.eventDriven => (
        'Live (event-driven file watcher on the host)',
        MacosColors.systemGreenColor,
      ),
      WatchMode.polling => (
        'Polling fallback — refreshing every few seconds',
        MacosColors.systemOrangeColor,
      ),
      WatchMode.stopped || null => (
        'Stopped — changes refresh manually (⌘R)',
        MacosColors.systemGrayColor,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(typography, 'Change watcher'),
        Row(
          children: [
            MacosIcon(CupertinoIcons.circle_fill, size: 9, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: typography.body)),
          ],
        ),
      ],
    );
  }

  Widget _toolsSection(MacosTypography typography) {
    final env = ref.watch(binaryEnvironmentProvider);
    String tool(String bin) {
      final path = env.found[bin];
      if (path == null) return 'not found';
      final version = env.versionOf(bin);
      return version == null ? 'found' : 'v$version';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(typography, 'Tools on the ${env.os == 'unknown' ? 'host' : env.os} target'),
        Row(
          children: [
            _stat(typography, tool('git'), 'git'),
            const SizedBox(width: 24),
            _stat(typography, tool('gh'), 'gh'),
            const SizedBox(width: 24),
            _stat(typography, tool('glab'), 'glab'),
          ],
        ),
      ],
    );
  }

  Widget _forgeSection(MacosTypography typography, String repoPath) {
    final forge = ref.watch(forgeProvider(repoPath)).value;
    if (forge != Forge.github && forge != Forge.gitlab) {
      return const SizedBox.shrink();
    }
    final openCount = forge == Forge.github
        ? ref.watch(pullRequestsProvider(repoPath)).value?.length
        : ref.watch(mergeRequestsProvider(repoPath)).value?.length;
    final requestLabel = forge == Forge.github ? 'open PRs' : 'open MRs';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(
          typography,
          forge == Forge.github ? 'GitHub' : 'GitLab',
        ),
        Row(
          children: [
            _stat(
              typography,
              openCount == null ? '…' : '$openCount',
              requestLabel,
            ),
          ],
        ),
      ],
    );
  }

  Widget _footprintSection(MacosTypography typography, String repoPath) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(typography, 'Repository footprint'),
        if (!_footprintRequested)
          Row(
            children: [
              PushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: () => setState(() => _footprintRequested = true),
                child: const Text('Measure'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Runs git count-objects on the repository (one quick '
                  'command).',
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ),
            ],
          )
        else
          ref
              .watch(repoFootprintProvider(repoPath))
              .when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ProgressCircle(radius: 8),
                  ),
                ),
                error: (err, _) => Text(
                  'Could not measure: $err',
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemOrangeColor,
                  ),
                ),
                data: (fp) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _stat(typography, fp.packSize, 'packed'),
                        const SizedBox(width: 24),
                        _stat(typography, '${fp.packs}', 'packs'),
                        const SizedBox(width: 24),
                        _stat(
                          typography,
                          '${fp.looseObjects}',
                          'loose objects',
                        ),
                        const SizedBox(width: 24),
                        _stat(typography, fp.looseSize, 'loose size'),
                      ],
                    ),
                    if (fp.wouldBenefitFromGc)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'This repository would benefit from `git gc` — '
                          'many loose objects/packs slow reads down.',
                          style: typography.caption1.copyWith(
                            color: MacosColors.systemOrangeColor,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ],
    );
  }

  Widget _loadingSection(MacosTypography typography, String title) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionTitle(typography, title),
      Text(
        'Loading…',
        style: typography.caption1.copyWith(
          color: MacosColors.systemGrayColor,
        ),
      ),
    ],
  );

  Widget _stat(
    MacosTypography typography,
    String value,
    String label, {
    Color? color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: typography.title3.copyWith(
            fontWeight: FontWeight.w600,
            color: color,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          label,
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
      ],
    );
  }

  static String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
}

/// One label/value line of the connection card.
Widget _kvRow(MacosTypography typography, String label, String value) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: typography.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

/// The "Session uptime" line, owning its own once-a-second timer so the tick
/// rebuilds exactly this row — never the whole sheet (see [_connectionCard]).
class _UptimeRow extends StatefulWidget {
  const _UptimeRow({required this.connectedAt, required this.typography});

  final DateTime connectedAt;
  final MacosTypography typography;

  @override
  State<_UptimeRow> createState() => _UptimeRowState();
}

class _UptimeRowState extends State<_UptimeRow> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uptime = DateTime.now().difference(widget.connectedAt);
    return _kvRow(
      widget.typography,
      'Session uptime',
      _DashboardSheetState._fmtDuration(uptime),
    );
  }
}

/// Minimal line sparkline — no dependencies, theme-agnostic.
class _Sparkline extends StatelessWidget {
  final List<double> values;
  final Color color;
  const _Sparkline({required this.values, required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _SparklinePainter(values, color));
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  _SparklinePainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = values.reduce(math.max);
    final minV = values.reduce(math.min);
    final span = (maxV - minV) == 0 ? 1.0 : (maxV - minV);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height * (1 - (values[i] - minV) / span);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.color != color;
}

/// Minimal bar chart for per-day counts.
class _Bars extends StatelessWidget {
  final List<double> values;
  final Color color;
  const _Bars({required this.values, required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _BarsPainter(values, color));
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  _BarsPainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce(math.max);
    final barW = size.width / values.length;
    final paint = Paint()..color = color;
    final track = Paint()..color = color.withValues(alpha: 0.15);
    for (var i = 0; i < values.length; i++) {
      final x = i * barW;
      // A hairline track so empty days still read as part of the chart.
      canvas.drawRect(
        Rect.fromLTWH(x + barW * 0.15, size.height - 1.5, barW * 0.7, 1.5),
        track,
      );
      if (maxV <= 0 || values[i] <= 0) continue;
      final h = math.max(2.0, size.height * values[i] / maxV);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x + barW * 0.15, size.height - h, barW * 0.7, h),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.values != values || old.color != color;
}
