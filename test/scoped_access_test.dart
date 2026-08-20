// ScopedAccess refcount: the native security-scoped grant is single-slot
// last-wins per path, so concurrent tabs on one folder must be balanced by an
// app-level refcount — native access starts on the first acquire and is
// released only on the last.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/local/scoped_access.dart';

void main() {
  late List<String> starts;
  late List<String> stops;
  late ScopedAccess access;

  // Maps a bookmark to its resolved path so two different bookmarks can point
  // at the same folder (the cross-tab hazard).
  ScopedAccess make(Map<String, String?> resolve) => ScopedAccess(
    startAccessing: (data) async {
      starts.add(data);
      return resolve[data];
    },
    stopAccessing: (path) async => stops.add(path),
  );

  setUp(() {
    starts = [];
    stops = [];
  });

  test('a single acquire/release starts then stops native access', () async {
    access = make({'bm': '/repo'});
    final p = await access.acquire('bm');
    expect(p, '/repo');
    expect(starts, ['bm']);
    expect(access.holdCount('/repo'), 1);

    await access.release('/repo');
    expect(stops, ['/repo']);
    expect(access.holdCount('/repo'), 0);
  });

  test(
    'concurrent holders on the same path release only on the last',
    () async {
      // Two saved repos, different bookmark data, same resolved folder.
      access = make({'bmA': '/shared', 'bmB': '/shared'});
      await access.acquire('bmA');
      await access.acquire('bmB');
      expect(access.holdCount('/shared'), 2);
      expect(starts, ['bmA', 'bmB']); // native start is idempotent (last-wins)

      // First tab closes — access must stay alive for the second.
      await access.release('/shared');
      expect(stops, isEmpty, reason: 'the other tab still holds the folder');
      expect(access.holdCount('/shared'), 1);

      // Last tab closes — now the grant is released exactly once.
      await access.release('/shared');
      expect(stops, ['/shared']);
      expect(access.holdCount('/shared'), 0);
    },
  );

  test('a failed resolve does not increment the count', () async {
    access = make({'bad': null});
    expect(await access.acquire('bad'), isNull);
    expect(starts, ['bad']);
    // No path resolved → nothing to track, nothing to release.
    expect(stops, isEmpty);
  });

  test('releasing an untracked path is a harmless no-op', () async {
    access = make({});
    // An ad-hoc, picker-granted folder was never acquired through here.
    await access.release('/never/acquired');
    expect(stops, isEmpty);
    expect(access.holdCount('/never/acquired'), 0);
  });
}
