import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/git/host_fs_service.dart';
import '../../core/providers/app_providers.dart';
import '../common/field_styles.dart';
import '../common/tool_icon_button.dart';

/// A navigable, dirs-only browser for the connected host's filesystem, used to
/// pick a clone/create destination's parent directory when a path isn't typed.
/// Pops with the chosen absolute directory path (or null if dismissed).
///
/// The host has no file browser elsewhere in the app; this drives the new
/// [HostFsService.listDirectories] primitive. It lists only directories (a
/// repo destination is always a folder), starting at [initialPath] or the
/// login home. A directory that can't be entered (permission denied) surfaces
/// as an inline banner and leaves the current listing in place, so a
/// mis-click never strands the browser.
class RemoteDirectoryBrowserSheet extends ConsumerStatefulWidget {
  final String? initialPath;
  const RemoteDirectoryBrowserSheet({super.key, this.initialPath});

  @override
  ConsumerState<RemoteDirectoryBrowserSheet> createState() =>
      _RemoteDirectoryBrowserSheetState();
}

class _RemoteDirectoryBrowserSheetState
    extends ConsumerState<RemoteDirectoryBrowserSheet> {
  final _pathField = TextEditingController();

  /// The directory currently listed. Null only while the first home-dir
  /// resolution is in flight.
  String? _currentPath;
  List<String> _entries = const [];
  bool _loading = true;
  bool _showHidden = false;

  /// A non-fatal message (a failed descend / initial load) shown as a banner;
  /// the current listing is retained beneath it.
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _pathField.dispose();
    super.dispose();
  }

  HostFsService get _fs => ref.read(hostFsServiceProvider);

  Future<void> _start() async {
    final initial = widget.initialPath?.trim();
    if (initial != null && initial.isNotEmpty) {
      await _navigateTo(initial);
      return;
    }
    try {
      final home = await _fs.homeDir();
      if (!mounted) return;
      await _navigateTo(home);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendly(e);
      });
    }
  }

  /// Loads [path]'s subdirectories. On success it becomes the current path; on
  /// failure the current path/listing are kept and the error is shown.
  Future<void> _navigateTo(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dirs = await _fs.listDirectories(path);
      if (!mounted) return;
      dirs.sort();
      setState(() {
        _currentPath = path;
        _entries = dirs;
        _loading = false;
        _pathField.text = path;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendly(e);
        _pathField.text = _currentPath ?? path;
      });
    }
  }

  void _goUp() {
    final current = _currentPath;
    if (current == null) return;
    final parent = _parentOf(current);
    if (parent != current) _navigateTo(parent);
  }

  List<String> get _visibleEntries => _showHidden
      ? _entries
      : [for (final e in _entries) if (!e.startsWith('.')) e];

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final atRoot = _currentPath == '/' || _currentPath == null;

    return MacosSheet(
      child: SizedBox(
        width: 560,
        height: (MediaQuery.sizeOf(context).height - 80).clamp(360.0, 560.0),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const MacosIcon(CupertinoIcons.folder, size: 18),
                  const SizedBox(width: 8),
                  Text('Choose a folder', style: typography.title2),
                  const Spacer(),
                  ToolIconButton(
                    icon: CupertinoIcons.xmark,
                    tooltip: 'Close',
                    size: 15,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ToolIconButton(
                    icon: CupertinoIcons.arrow_up,
                    tooltip: 'Parent folder',
                    size: 15,
                    onPressed: atRoot ? null : _goUp,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: MacosTextField(
                      controller: _pathField,
                      placeholder: '/absolute/path',
                      decoration: kAppTextFieldDecoration,
                      focusedDecoration: kAppTextFieldFocusedDecoration,
                      onSubmitted: (v) {
                        final p = v.trim();
                        if (p.isNotEmpty) _navigateTo(p);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  ToolIconButton(
                    icon: _showHidden
                        ? CupertinoIcons.eye_fill
                        : CupertinoIcons.eye_slash,
                    tooltip: _showHidden
                        ? 'Hiding nothing (click to hide dotfiles)'
                        : 'Hiding dotfiles (click to show)',
                    size: 15,
                    onPressed: () => setState(() => _showHidden = !_showHidden),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_error != null) ...[
                _ErrorBanner(_error!),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: MacosColors.separatorColor),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: _body(typography),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _currentPath ?? '',
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemGrayColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  PushButton(
                    controlSize: ControlSize.large,
                    onPressed: _currentPath == null
                        ? null
                        : () => Navigator.of(context).pop(_currentPath),
                    child: const Text('Choose This Folder'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(MacosTypography typography) {
    if (_loading) {
      return const Center(child: ProgressCircle());
    }
    final entries = _visibleEntries;
    if (entries.isEmpty) {
      return Center(
        child: Text(
          _error != null ? 'Could not read this folder.' : 'No subfolders here.',
          style: typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final name = entries[i];
        return _DirRow(
          name: name,
          onTap: () =>
              _navigateTo(HostFsService.joinPath(_currentPath!, name)),
        );
      },
    );
  }

  /// The parent of an absolute path: `/a/b` → `/a`, `/a` → `/`, `/` → `/`.
  static String _parentOf(String path) {
    var end = path.length;
    while (end > 0 && path[end - 1] == '/') {
      end--;
    }
    final trimmed = path.substring(0, end);
    final slash = trimmed.lastIndexOf('/');
    if (slash <= 0) return '/';
    return trimmed.substring(0, slash);
  }

  static String _friendly(Object e) {
    final raw = e is HostFsException ? e.message : e.toString();
    if (raw.toLowerCase().contains('permission')) return 'Permission denied.';
    return raw.isEmpty ? 'Could not read this folder.' : raw;
  }
}

class _DirRow extends StatefulWidget {
  final String name;
  final VoidCallback onTap;
  const _DirRow({required this.name, required this.onTap});

  @override
  State<_DirRow> createState() => _DirRowState();
}

class _DirRowState extends State<_DirRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          color: _hover
              ? MacosColors.systemBlueColor.withValues(alpha: 0.14)
              : const Color(0x00000000),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              const MacosIcon(
                CupertinoIcons.folder_fill,
                size: 15,
                color: MacosColors.systemBlueColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.name,
                  style: typography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const MacosIcon(
                CupertinoIcons.chevron_right,
                size: 12,
                color: MacosColors.systemGrayColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner(this.message);

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: MacosColors.systemOrangeColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            const MacosIcon(
              CupertinoIcons.exclamationmark_triangle,
              size: 14,
              color: MacosColors.systemOrangeColor,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: typography.caption1)),
          ],
        ),
      ),
    );
  }
}
