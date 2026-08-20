import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'async_write_queue.dart';

/// A remote host's previously-trusted SSH host key, identified by its
/// algorithm name (e.g. `ssh-ed25519`) and OpenSSH-style SHA256 fingerprint
/// (`SHA256:<base64>`).
class KnownHostEntry {
  final String keyType;
  final String fingerprint;

  const KnownHostEntry({required this.keyType, required this.fingerprint});

  factory KnownHostEntry.fromJson(Map<String, dynamic> json) => KnownHostEntry(
    keyType: json['keyType'] as String? ?? '',
    fingerprint: json['fingerprint'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'keyType': keyType,
    'fingerprint': fingerprint,
  };
}

/// A [KnownHostEntry] paired with the `host`/`port` it was recorded for —
/// returned by [KnownHostsStore.list] so the UI (Settings' "Known Hosts"
/// section) can enumerate every trusted host and offer a per-entry "Forget".
class KnownHostRecord {
  final String host;
  final int port;
  final KnownHostEntry entry;

  const KnownHostRecord({
    required this.host,
    required this.port,
    required this.entry,
  });
}

/// Persists the SSH host key this app has trusted for each `host:port`, in
/// shared_preferences as a single JSON blob — mirroring OpenSSH's
/// `~/.ssh/known_hosts` model, but scoped to this app rather than the whole
/// system. Not secret data (a host's public key is, by definition, public),
/// so unlike connection credentials it doesn't need Keychain-backed storage.
class KnownHostsStore {
  static const _prefsKey = 'known_hosts';

  /// Serializes [remember]/[forget]'s read-modify-write against the blob —
  /// see [AsyncWriteQueue] for why this matters.
  final _writes = AsyncWriteQueue();

  // Bracket the host like a URL/IPv6 literal (`[host]:port`) rather than
  // joining with a bare colon. An IPv6 literal legitimately contains colons
  // (e.g. `::1`, `fe80::1`), so a plain `'$host:$port'` join lets two
  // distinct (host, port) pairs collide on the same serialized key — e.g.
  // host `::1` port `22` and host `::1:22`(as an unlikely but legal literal)
  // port... would both risk landing on `::1:22`. Bracketing the host removes
  // the ambiguity: the trailing `]:` unambiguously marks the host/port
  // boundary regardless of what the host itself contains.
  static String _keyFor(String host, int port) => '[$host]:$port';

  static final RegExp _keyPattern = RegExp(r'^\[(.*)\]:(\d+)$');

  /// Parses a key produced by [_keyFor] back into its `(host, port)` pair, or
  /// null if it isn't in the current bracketed format (e.g. some other/older
  /// format never written by this store). Used by [list] to enumerate
  /// entries for the Settings UI.
  static (String, int)? _parseKey(String key) {
    final match = _keyPattern.firstMatch(key);
    if (match == null) return null;
    final port = int.tryParse(match.group(2)!);
    if (port == null) return null;
    return (match.group(1)!, port);
  }

  Future<Map<String, KnownHostEntry>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, KnownHostEntry>{};
      decoded.forEach((k, v) {
        if (v is! Map<String, dynamic>) return; // skip a malformed entry
        final entry = KnownHostEntry.fromJson(v);
        if (entry.keyType.isEmpty || entry.fingerprint.isEmpty) return;
        out['$k'] = entry;
      });
      return out;
    } catch (_) {
      // A corrupt/truncated blob must not throw here: _load runs inside
      // lookup(), which is called from the onVerifyHostKey callback, so a throw
      // fails host-key verification and blocks connecting to *every* host until
      // prefs are manually cleared. Degrade to empty (trust-on-first-use).
      return {};
    }
  }

  Future<void> _save(Map<String, KnownHostEntry> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  /// The key this app previously trusted for `host:port`, or null if this
  /// host has never been connected to before.
  Future<KnownHostEntry?> lookup(String host, int port) async {
    final map = await _load();
    return map[_keyFor(host, port)];
  }

  /// Records [entry] as the trusted key for `host:port` — used both for
  /// trust-on-first-use (no prior entry existed) and for a user-approved key
  /// refresh (the presented key differed from what was previously trusted).
  Future<void> remember(String host, int port, KnownHostEntry entry) =>
      _writes.run(() async {
        final map = await _load();
        map[_keyFor(host, port)] = entry;
        await _save(map);
      });

  /// Drops any remembered key for `host:port`, so the next connection attempt
  /// is treated as trust-on-first-use again.
  Future<void> forget(String host, int port) => _writes.run(() async {
    final map = await _load();
    map.remove(_keyFor(host, port));
    await _save(map);
  });

  /// Every currently-trusted host key, host/port ascending — lets the
  /// Settings "Known Hosts" section list and selectively forget a stale or
  /// rotated entry. Previously the only way to clear one was wiping all app
  /// data, since [forget] existed but nothing enumerated entries to call it
  /// on.
  Future<List<KnownHostRecord>> list() async {
    final map = await _load();
    final out = <KnownHostRecord>[];
    for (final e in map.entries) {
      final parsed = _parseKey(e.key);
      if (parsed == null) continue; // skip a key in an unrecognized format
      out.add(
        KnownHostRecord(host: parsed.$1, port: parsed.$2, entry: e.value),
      );
    }
    out.sort((a, b) {
      final byHost = a.host.compareTo(b.host);
      return byHost != 0 ? byHost : a.port.compareTo(b.port);
    });
    return out;
  }
}
