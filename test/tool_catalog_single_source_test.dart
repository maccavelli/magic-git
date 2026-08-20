// The tool catalog is the one definition of "an external binary Magic Git
// needs". Everything else derives from it.
//
// It did not used to be. The same five names were written out by hand in four
// places — the connect-time probe script, `kOverridableBinaries`,
// `AppSettingsNotifier.overridableBinaries`, and `kToolCatalog` — and the four
// could disagree without anything noticing. (`kOverridableBinaries` had in fact
// already rotted into dead code: defined, exported, read by nobody.) The
// failure that shape produces is quiet and confusing: a tool the user can set a
// path for in Settings that the host is never actually searched for, or a tool
// probed on the host that the doctor panel never reports on.
//
// So these tests do not check behavior — they check that the derivation is
// still a derivation. Adding a binary to `kToolCatalog` must be the *only* edit
// needed to make it probed, overridable, and visible in the doctor.

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/settings/tool_catalog.dart';
import 'package:remote_magic_git/core/ssh/environment_probe.dart';

/// The binary names the probe script actually looks for, read back out of the
/// generated script — i.e. what the *host* will really be searched for, not
/// what we believe it will be searched for.
List<String> _binariesInProbeScript() {
  final script = EnvironmentResolver.probeScriptForTest;
  final m = RegExp(r'for b in ([^;]+); do').firstMatch(script);
  expect(
    m,
    isNotNull,
    reason:
        'the probe script must still loop over a binary list; if its shape '
        'changed, this guard has to be taught the new shape rather than deleted',
  );
  return m!.group(1)!.trim().split(RegExp(r'\s+'));
}

void main() {
  test('the probe searches the host for exactly the binaries we declare', () {
    // Not a subset, not a superset — equal. A catalog tool missing here is a
    // tool the user can configure but that is never found; an extra here is a
    // tool found but never surfaced.
    expect(_binariesInProbeScript(), kProbedBinaries);
  });

  test('every catalog tool is probed', () {
    final probed = _binariesInProbeScript();
    for (final spec in kToolCatalog) {
      expect(
        probed,
        contains(spec.bin),
        reason:
            '${spec.bin} is in the catalog (so the doctor reports on it and '
            'Settings offers a path override) but the probe never looks for it',
      );
    }
  });

  test('every catalog tool is overridable, and only catalog tools are', () {
    expect(kOverridableBinaries, [for (final t in kToolCatalog) t.bin]);
  });

  test('settings does not keep its own list of overridable binaries', () {
    // Same object, not merely equal contents: an alias cannot drift, a copy can.
    expect(
      identical(AppSettingsNotifier.overridableBinaries, kOverridableBinaries),
      isTrue,
      reason:
          'AppSettingsNotifier.overridableBinaries must delegate to '
          'kOverridableBinaries, not restate it',
    );
  });

  test('capabilities are probed but never offered as overrides', () {
    // gzip/stdbuf are resolved for a capability check, not because the user
    // names them. Leaking one into the override list would put a binary in the
    // Settings UI that no command ever runs as argv[0].
    final probed = _binariesInProbeScript();
    for (final cap in kProbedCapabilities) {
      expect(probed, contains(cap), reason: '$cap must still be probed');
      expect(
        kOverridableBinaries,
        isNot(contains(cap)),
        reason: '$cap is a capability, not a user-facing tool',
      );
      expect(
        toolSpecFor(cap),
        isNull,
        reason: '$cap must not appear in the doctor panel',
      );
    }
  });

  test('the generated script is still shell-safe', () {
    // The list is interpolated unquoted into a `for` loop. That is only safe
    // while every name is a bare identifier.
    for (final bin in kProbedBinaries) {
      expect(
        RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(bin),
        isTrue,
        reason:
            '"$bin" would need quoting to be interpolated into the probe '
            'script safely',
      );
    }
  });
}
