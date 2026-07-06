import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'async_write_queue.dart';
import 'saved_connection.dart';

/// Persists connection profiles: non-secret metadata in shared_preferences,
/// secrets (SSH password/passphrase/private key, GitLab token) in the macOS
/// Keychain via flutter_secure_storage.
///
/// When the Keychain is unavailable — e.g. an unsigned build, where every
/// secure-storage call throws — secrets fall back to a JSON file under the
/// user's config dir (`$XDG_CONFIG_HOME/magic_git/credentials.json`, or
/// `~/.config/magic_git/credentials.json`), written with `0600` (owner
/// read/write only) inside a `0700` directory. This is plaintext-on-disk
/// protected only by file permissions, the same model glab and git themselves
/// use for their credential files; it is strictly a fallback for builds that
/// can't reach the Keychain.
class ConnectionStore {
  static const _metaKey = 'saved_connections';
  static String _secretKey(String id) => 'conn_secret_$id'; // SSH password
  static String _tokenKey(String id) => 'conn_gltoken_$id';
  static String _keyKey(String id) => 'conn_key_$id'; // private key PEM
  static String _passphraseKey(String id) => 'conn_pass_$id'; // key passphrase

  final FlutterSecureStorage _secure;
  final String? _dotfilePath;

  /// Serializes every read-modify-write against the metadata blob (`save`,
  /// `updateMetadata`, `touch`, `delete`). Each reads the full connection
  /// list, then writes back a modified copy — without this, two calls
  /// in-flight at once (e.g. a `touch` on connect racing a `save` from the
  /// edit sheet) interleave their read and write, and whichever writes last
  /// silently clobbers the other's change.
  final _writes = AsyncWriteQueue();

  /// Serializes read-modify-write access to the 0600 dotfile fallback — unlike
  /// the Keychain (each key is an independent entry, safe to write
  /// concurrently), the dotfile is one shared JSON blob, so concurrent secret
  /// writes (see `save`'s `Future.wait`) would otherwise interleave and
  /// silently drop each other's key.
  final _dotfileWrites = AsyncWriteQueue();

  ConnectionStore({FlutterSecureStorage? secure, String? dotfilePath})
    : _secure =
          secure ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.unlocked,
              synchronizable: false,
            ),
          ),
      _dotfilePath = dotfilePath ?? _defaultDotfilePath();

  /// The absolute path to the 0600 credentials-file fallback, or null if no
  /// config directory can be resolved (`XDG_CONFIG_HOME`, `HOME`, and
  /// `USERPROFILE` all unset). In that case the fallback is refused outright
  /// rather than defaulting to `Directory.systemTemp` — a shared,
  /// world-writable location with a fixed, predictable filename, which would be
  /// a worse place to land plaintext secrets than no fallback at all. When
  /// [_dotfilePath] is null, secrets rely on the Keychain only; if the Keychain
  /// is also unavailable, they simply aren't persisted to disk (best-effort,
  /// matching how the rest of this store treats storage that can't be reached
  /// — see [_chmod]).
  ///
  /// Honors the XDG base-directory spec: an explicit `XDG_CONFIG_HOME` wins,
  /// otherwise `~/.config`, with the app owning the `magic_git/` subdirectory.
  static String? _defaultDotfilePath() {
    final env = Platform.environment;
    final xdg = env['XDG_CONFIG_HOME'];
    final String configHome;
    if (xdg != null && xdg.isNotEmpty) {
      configHome = xdg;
    } else {
      final home = env['HOME'] ?? env['USERPROFILE'];
      if (home == null || home.isEmpty) return null;
      configHome = '$home/.config';
    }
    return '$configHome/magic_git/credentials.json';
  }

  Future<List<SavedConnection>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_metaKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <SavedConnection>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        try {
          out.add(SavedConnection.fromJson(item));
        } catch (_) {
          // Skip a single malformed entry rather than losing the whole list.
        }
      }
      return out;
    } catch (_) {
      // A corrupt/truncated blob must not throw: list() is read by the landing
      // page and called inside every save/touch/updateMetadata/delete. Degrade
      // to empty rather than breaking the saved-connections UI wholesale.
      return [];
    }
  }

  /// Persists the full connection list as the metadata blob. The single writer
  /// used by [save]/[updateMetadata]/[delete].
  Future<void> _writeMetadata(List<SavedConnection> connections) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _metaKey,
      jsonEncode(connections.map((c) => c.toJson()).toList()),
    );
  }

  Future<void> save(
    SavedConnection conn, {
    String? secret,
    String? gitlabToken,
    String? privateKey,
    String? passphrase,
  }) async {
    await _writes.run(() async {
      final existing = await list();
      await _writeMetadata([...existing.where((c) => c.id != conn.id), conn]);
    });
    // Independent Keychain entries — safe to write concurrently.
    await Future.wait([
      _writeSecret(_secretKey(conn.id), secret),
      _writeSecret(_tokenKey(conn.id), gitlabToken),
      _writeSecret(_keyKey(conn.id), privateKey),
      _writeSecret(_passphraseKey(conn.id), passphrase),
    ]);
  }

  /// Updates only the non-secret metadata of an existing profile (e.g. its
  /// repo list). Unlike [save], this never touches stored secrets.
  Future<void> updateMetadata(SavedConnection conn) => _writes.run(() async {
    final existing = await list();
    await _writeMetadata([...existing.where((c) => c.id != conn.id), conn]);
  });

  /// Stamps a profile's `lastConnectedAt` with [when] (defaults to now) so it
  /// floats to the top of the landing page's recent list. Best-effort no-op if
  /// the id isn't found.
  Future<void> touch(String id, {DateTime? when}) => _writes.run(() async {
    final existing = await list();
    final idx = existing.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    final updated = existing[idx].copyWith(
      lastConnectedAt: when ?? DateTime.now(),
    );
    await _writeMetadata([
      ...existing.where((c) => c.id != id),
      updated,
    ]);
  });

  Future<String?> secretFor(String id) => _readSecret(_secretKey(id));
  Future<String?> gitlabTokenFor(String id) => _readSecret(_tokenKey(id));
  Future<String?> privateKeyFor(String id) => _readSecret(_keyKey(id));
  Future<String?> passphraseFor(String id) => _readSecret(_passphraseKey(id));

  Future<void> delete(String id) async {
    await _writes.run(() async {
      final existing = await list();
      await _writeMetadata(existing.where((c) => c.id != id).toList());
    });
    await _deleteSecret(_secretKey(id));
    await _deleteSecret(_tokenKey(id));
    await _deleteSecret(_keyKey(id));
    await _deleteSecret(_passphraseKey(id));
  }

  // ---- Secret backend: Keychain primary, 0600 dotfile fallback -------------

  Future<void> _writeSecret(String key, String? value) async {
    try {
      if (value != null && value.isNotEmpty) {
        await _secure.write(key: key, value: value);
      } else {
        await _secure.delete(key: key);
      }
    } catch (_) {
      // Keychain unavailable — persist to the 0600 dotfile instead.
      await _dotfileWrites.run(() async {
        final map = await _readDotfile();
        if (value != null && value.isNotEmpty) {
          map[key] = value;
        } else {
          map.remove(key);
        }
        await _writeDotfile(map);
      });
      return;
    }
    // Keychain succeeded — don't leave a stale copy in the dotfile. This
    // cleanup gets its own try/catch, separate from the Keychain write above:
    // if the Keychain write succeeded but this cleanup throws (e.g. a
    // transient disk error), that must not be misclassified as "Keychain
    // unavailable" — the secret is already safely in the Keychain, so a
    // cleanup failure here is best-effort and swallowed, not a signal to
    // redundantly persist the secret into the plaintext dotfile.
    try {
      await _dotfileRemove(key);
    } catch (_) {
      // Best-effort cleanup; ignore.
    }
  }

  Future<String?> _readSecret(String key) async {
    try {
      final value = await _secure.read(key: key);
      if (value != null) return value;
    } catch (_) {
      // Fall through to the dotfile.
    }
    return (await _readDotfile())[key];
  }

  Future<void> _deleteSecret(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (_) {
      // ignore
    }
    await _dotfileRemove(key);
  }

  Future<void> _dotfileRemove(String key) => _dotfileWrites.run(() async {
    final map = await _readDotfile();
    if (map.remove(key) != null) await _writeDotfile(map);
  });

  Future<Map<String, String>> _readDotfile() async {
    final path = _dotfilePath;
    if (path == null) return {}; // no home directory — no dotfile fallback
    try {
      final file = File(path);
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {
      // Corrupt/unreadable dotfile — treat as empty.
    }
    return {};
  }

  Future<void> _writeDotfile(Map<String, String> map) async {
    final path = _dotfilePath;
    if (path == null) return; // no home directory — refuse to persist

    final file = File(path);
    if (map.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    // Ensure the config subdirectory exists and is owner-only (0700) before
    // landing secrets in it — under the XDG default (`~/.config/magic_git/`)
    // the app owns this dir, so it may not exist on first save.
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      await _chmod(dir.path, '700');
    }
    // Write to a uniquely-named sibling temp file in the same directory,
    // chmod *that* to 0600, then atomically rename it over the target. Never
    // write straight to `path`: `writeAsString` would create the file at
    // default/umask permissions and only chmod it afterward, leaving a brief
    // window where a freshly-written secrets file is world-readable.
    // `File.rename` is atomic within the same directory, so the target path
    // itself never observably exists in that state.
    final tmp = File(
      '$path.${pid}_${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tmp.writeAsString(jsonEncode(map), flush: true);
    await _chmod(tmp.path, '600');
    await tmp.rename(file.path);
  }

  /// Restrict [path] to POSIX [mode] (e.g. `600` for the secrets file, `700`
  /// for its containing dir). No-op on platforms without POSIX permissions.
  Future<void> _chmod(String path, String mode) async {
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        await Process.run('chmod', [mode, path]);
      } catch (_) {
        // Best effort.
      }
    }
  }
}
