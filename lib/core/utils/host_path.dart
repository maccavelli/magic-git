/// Host paths with their style: one canonical form per host, so a path git
/// printed and a path the app stored compare equal (MADR 0070, Amendment
/// 0070.3).
///
/// On a Windows host whose SSH shell is Git Bash, the same folder arrives in
/// three spellings — `/c/Users/u/r` from the folder browser (`pwd`) or a `~`
/// path, `C:\Users\u\r` or `C:/Users/u/r` typed — while Git for Windows
/// prints every path as `C:/Users/u/r`. The canonical Windows form is git's:
/// an upper-case drive letter, forward slashes, no trailing slash except the
/// root `C:/`. Windows compares paths case-insensitively.
///
/// Under [HostPathStyle.posix] every function behaves exactly as the POSIX
/// helpers in `posix_path.dart` and `HostFsService.joinPath` do, byte for
/// byte, so Linux and macOS hosts and the local backend are unchanged.
library;

import 'posix_path.dart' as posix;

/// How a host spells its paths. Windows means a Windows host reached through
/// Git Bash; the local backend and every other host are POSIX.
enum HostPathStyle { posix, windows }

abstract final class HostPath {
  static final _drive = RegExp(r'^([A-Za-z]):(/.*)?$');
  static final _msysDrive = RegExp(r'^/([A-Za-z])(/.*)?$');
  static final _drivePrefix = RegExp(r'^[A-Za-z]:[/\\]');
  static final _repeatedSlashes = RegExp(r'/{2,}');

  /// [path] in the host's canonical form.
  ///
  /// Windows: backslashes become `/`; `x:/a/`, `X:\a` and the MSYS drive
  /// mount `/x/a` become `X:/a`; `/x` and `X:` become `X:/`; a UNC
  /// `\\srv\share\a` becomes `//srv/share/a`. Anything else (an MSYS mount
  /// such as `/tmp`, a relative path) keeps its text: only the host can map
  /// it. POSIX: unchanged.
  static String canonical(String path, HostPathStyle style) {
    if (style == HostPathStyle.posix) return path;
    var p = path.replaceAll(r'\', '/');
    final unc = p.startsWith('//');
    if (unc) {
      p = '//${p.substring(2).replaceAll(_repeatedSlashes, '/')}';
      return _stripTrailing(p, keep: 2);
    }
    final msys = _msysDrive.firstMatch(p);
    if (msys != null) p = '${msys.group(1)}:${msys.group(2) ?? '/'}';
    final drive = _drive.firstMatch(p);
    if (drive == null) return p;
    final rest = (drive.group(2) ?? '/').replaceAll(_repeatedSlashes, '/');
    return _stripTrailing('${drive.group(1)!.toUpperCase()}:$rest', keep: 3);
  }

  /// Whether [path] is absolute on its host. POSIX: it starts with `/`.
  /// Windows: its canonical form starts with a drive root `X:/` or is UNC.
  static bool isAbsolute(String path, HostPathStyle style) {
    if (style == HostPathStyle.posix) return path.startsWith('/');
    final c = canonical(path, style);
    return c.startsWith('//') || RegExp(r'^[A-Z]:/').hasMatch(c);
  }

  /// Absolute in some style — `/…`, `X:/…`, `X:\…`, `//…`, `\\…` — for a
  /// path whose host is not known here (a saved entry of any connection, a
  /// path git printed). A drive prefix is never a POSIX absolute path, so
  /// this rejects nothing a POSIX host could mean; it also rejects what the
  /// check it replaces rejected, e.g. an old git's echoed `%(worktreepath)`.
  static bool looksAbsolute(String path) =>
      path.startsWith('/') ||
      path.startsWith(r'\\') ||
      _drivePrefix.hasMatch(path);

  /// The same path on this host: equal as given for POSIX; for Windows,
  /// equal after [canonical], ignoring case.
  static bool same(String a, String b, HostPathStyle style) {
    if (style == HostPathStyle.posix) return a == b;
    return _key(a) == _key(b);
  }

  /// [child] is [parent] or below it, under [same]'s rules.
  static bool isInside(String child, String parent, HostPathStyle style) {
    final c = style == HostPathStyle.posix ? child : _key(child);
    final p = style == HostPathStyle.posix ? parent : _key(parent);
    if (c == p) return true;
    return c.startsWith(p.endsWith('/') ? p : '$p/');
  }

  /// The last segment, for a label. Splits on `/`, and also on `\` when the
  /// path has a drive or UNC prefix, so a legacy `C:\Users\u\r` labels as
  /// `r` with no style needed. A bare drive root labels as itself.
  static String basename(String path) {
    final windowsShaped = _drivePrefix.hasMatch(path) || path.startsWith(r'\\');
    if (!windowsShaped) return posix.basename(path);
    final parts = path
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length <= 1) return path;
    return parts.last;
  }

  /// The parent directory. POSIX: `posix_path.dirname`. Windows: of the
  /// canonical form, and a drive root `X:/` is its own parent.
  static String dirname(String path, HostPathStyle style) {
    if (style == HostPathStyle.posix) return posix.dirname(path);
    final c = canonical(path, style);
    if (RegExp(r'^[A-Z]:/$').hasMatch(c)) return c;
    final slash = c.lastIndexOf('/');
    if (slash < 0) return c;
    if (RegExp(r'^[A-Z]:/').hasMatch(c) && slash <= 2) return c.substring(0, 3);
    if (c.startsWith('//') && slash <= 1) return c;
    return c.substring(0, slash);
  }

  /// [name] under [parent]. POSIX: `HostFsService.joinPath`'s rule (a root
  /// parent gives `/name`). Windows: under the canonical parent, with `\` in
  /// [name] written as `/`.
  static String join(String parent, String name, HostPathStyle style) {
    if (style == HostPathStyle.posix) {
      final p = posix.stripTrailingSlashes(parent);
      return p.isEmpty ? '/$name' : '$p/$name';
    }
    final p = canonical(parent, style);
    final n = name.replaceAll(r'\', '/');
    return p.endsWith('/') ? '$p$n' : '$p/$n';
  }

  static String _key(String path) =>
      canonical(path, HostPathStyle.windows).toLowerCase();

  static String _stripTrailing(String path, {required int keep}) {
    var end = path.length;
    while (end > keep && path[end - 1] == '/') {
      end--;
    }
    return path.substring(0, end);
  }
}
