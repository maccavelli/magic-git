import '../ssh/shell_escaper.dart';
import '../ssh/ssh_command_executor.dart';

/// A host filesystem operation failed (permission denied, missing directory,
/// …). Carries the failing result when one exists so the UI can surface
/// stderr.
class HostFsException implements Exception {
  final String message;
  final SSHCommandResult? result;
  const HostFsException(this.message, [this.result]);

  @override
  String toString() => message;
}

/// What [HostFsService.probePath] found at a path.
enum PathProbe {
  /// Something (file or directory) already exists at the path.
  exists,

  /// Nothing at the path, but its parent directory exists — safe to create.
  absent,

  /// The parent directory doesn't exist either.
  noParent,
}

/// Plain filesystem primitives on the connected host (SSH) or the local
/// machine — the pieces clone/create need that git itself doesn't provide:
/// resolving the home directory, listing directories for the remote browser,
/// probing a destination, creating parents, and the single tightly-guarded
/// delete used to clean up a failed/cancelled clone.
///
/// Everything runs through the shared [CommandExecutor], so one implementation
/// covers both backends. Commands follow the established compound-shell
/// pattern: `['sh','-c', script]` with every caller value passed through
/// [ShellEscaper.escape] (see `GitService.setFsmonitorMany`).
class HostFsService {
  final CommandExecutor _executor;
  HostFsService(this._executor);

  /// Short bound for the quick probes here — none of these should take long,
  /// and a hung `ls` must not wedge a picker.
  static const timeout = Duration(seconds: 20);

  /// The account's home directory: `pwd` run from `'.'`, which the SSH exec
  /// channel resolves to the login home. (On the local backend this is the
  /// process cwd — the local UI uses the native folder picker instead, so this
  /// is only ever a fallback there.)
  Future<String> homeDir() async {
    final result = await _executor.execute(
      repoPath: '.',
      gitArgs: const ['pwd'],
      lane: ExecLane.read,
      timeout: timeout,
    );
    final home = result.stdout.trim();
    if (!result.isSuccess || home.isEmpty) {
      throw HostFsException('could not resolve the home directory', result);
    }
    return home;
  }

  /// The names of the sub*directories* of [path] (symlinks-to-directories
  /// included via `-L`), sorted bytewise (`LC_ALL=C`). Throws [HostFsException]
  /// when the directory can't be entered at all (permission denied, gone);
  /// tolerates a partial listing (e.g. one broken symlink erroring on stat)
  /// by returning what was listed.
  ///
  /// Known limitation, acceptable for a directory picker: a name containing a
  /// newline mis-parses (the typed path field is the escape hatch).
  Future<List<String>> listDirectories(String path) async {
    final result = await _executor.execute(
      repoPath: path,
      gitArgs: const ['sh', '-c', 'LC_ALL=C ls -1ALp .'],
      lane: ExecLane.read,
      timeout: timeout,
    );
    final dirs = [
      for (final line in result.stdout.split('\n'))
        if (line.endsWith('/')) line.substring(0, line.length - 1),
    ];
    if (!result.isSuccess && result.stdout.trim().isEmpty) {
      throw HostFsException(
        result.stderr.trim().isEmpty
            ? 'could not list $path'
            : result.stderr.trim(),
        result,
      );
    }
    return dirs;
  }

  /// Probes [path] without needing it (or even its parent) to exist — run from
  /// `'.'`, unlike every other command here. Distinguishes "already taken",
  /// "free to create", and "the parent is missing too".
  Future<PathProbe> probePath(String path) async {
    final p = ShellEscaper.escape(path);
    final script =
        'p=$p; if test -e "\$p"; then echo exists; '
        'elif test -d "\$(dirname "\$p")"; then echo absent; '
        'else echo noparent; fi';
    final result = await _executor.execute(
      repoPath: '.',
      gitArgs: ['sh', '-c', script],
      lane: ExecLane.read,
      timeout: timeout,
    );
    return switch (result.stdout.trim()) {
      'exists' => PathProbe.exists,
      'absent' => PathProbe.absent,
      'noparent' => PathProbe.noParent,
      _ => throw HostFsException('could not inspect $path', result),
    };
  }

  /// `mkdir -p` for [path] (the clone sheet's "create parent folders" toggle).
  Future<void> makeDirs(String path) async {
    final result = await _executor.execute(
      repoPath: '.',
      gitArgs: ['sh', '-c', 'mkdir -p -- ${ShellEscaper.escape(path)}'],
      lane: ExecLane.exclusive,
      timeout: timeout,
    );
    if (!result.isSuccess) {
      throw HostFsException(
        result.stderr.trim().isEmpty
            ? 'could not create $path'
            : result.stderr.trim(),
        result,
      );
    }
  }

  /// Deletes the partial destination of a failed/cancelled clone — the ONLY
  /// deletion primitive in this feature, deliberately over-guarded: the path
  /// must be exactly `expectedParent/expectedName` with a standalone-valid
  /// name and a non-root absolute parent, so no code path can ever aim `rm
  /// -rf` at a user-picked directory or anything it didn't just try to create.
  /// The caller (the clone controller) additionally only invokes this when the
  /// destination did NOT exist before its own run started.
  Future<void> removeDirGuarded({
    required String path,
    required String expectedParent,
    required String expectedName,
  }) async {
    if (!isValidRepoDirName(expectedName)) {
      throw ArgumentError('refusing to delete: invalid name "$expectedName"');
    }
    if (!expectedParent.startsWith('/')) {
      throw ArgumentError('refusing to delete: parent must be absolute');
    }
    final normalizedParent = _stripTrailingSlashes(expectedParent);
    if (normalizedParent.isEmpty) {
      // expectedParent was '/' (or only slashes) — never delete at the root.
      throw ArgumentError('refusing to delete directly under /');
    }
    if (path != '$normalizedParent/$expectedName') {
      throw ArgumentError(
        'refusing to delete: path is not the expected parent/name',
      );
    }
    final result = await _executor.execute(
      repoPath: '.',
      gitArgs: ['sh', '-c', 'rm -rf -- ${ShellEscaper.escape(path)}'],
      lane: ExecLane.exclusive,
      timeout: timeout,
    );
    if (!result.isSuccess) {
      throw HostFsException(
        result.stderr.trim().isEmpty
            ? 'could not remove $path'
            : result.stderr.trim(),
        result,
      );
    }
  }

  /// Joins a parent directory and a child name into one path, tolerating a
  /// trailing slash on the parent.
  static String joinPath(String parent, String name) {
    final p = _stripTrailingSlashes(parent);
    return p.isEmpty ? '/$name' : '$p/$name';
  }

  static String _stripTrailingSlashes(String path) {
    var end = path.length;
    while (end > 0 && path[end - 1] == '/') {
      end--;
    }
    return path.substring(0, end);
  }

  /// Whether [name] is acceptable as a new repository directory name: a single
  /// path component with no shell/argv foot-guns. Leading `-` is rejected for
  /// argv safety even though callers pass `--`; NUL would be rejected by
  /// [ShellEscaper] anyway but is checked here for a friendlier error.
  static bool isValidRepoDirName(String name) {
    if (name.isEmpty || name != name.trim()) return false;
    if (name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains(String.fromCharCode(0))) {
      return false;
    }
    if (name.startsWith('-')) return false;
    return true;
  }
}
