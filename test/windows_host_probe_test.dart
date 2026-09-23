// The Windows host probe (MADR 0070, 0070-PLAN Phase 1): the script, the one
// command line that carries it past any default shell, the parser, and the
// enable command shown to the user byte-for-byte.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/windows_host_probe.dart';

/// Decodes the Base64 UTF-16LE payload of an `-EncodedCommand` line.
String _decodedScript(String commandLine) {
  final payload = commandLine.split(' ').last;
  final bytes = base64.decode(payload);
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  return String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2) data.getUint16(i, Endian.little),
  ]);
}

/// `pwsh` (PowerShell 7) runs the script here; the Windows-only parts (the
/// registry, the Windows identity) must then come back empty, not fail.
final String? _pwsh = () {
  final which = Process.runSync('which', ['pwsh']);
  final path = (which.stdout as String).trim();
  return which.exitCode == 0 && path.isNotEmpty ? path : null;
}();

void main() {
  group('the command line', () {
    test('decodes back to the exact script', () {
      final script = windowsHostProbeScript();
      expect(_decodedScript(encodedPowerShellCommand(script)), script);
    });

    test('holds nothing any Windows shell treats specially, and fits '
        "cmd.exe's 8,191-character limit", () {
      final line = encodedPowerShellCommand(
        windowsHostProbeScript(
          bashOverride: r"D:\Tools\Git's \bin\bash.exe; & | % ^ ! `$x",
        ),
      );
      expect(
        line,
        matches(
          RegExp(
            r'^powershell\.exe -NoProfile -NonInteractive '
            r'-ExecutionPolicy Bypass -EncodedCommand [A-Za-z0-9+/]+=*$',
          ),
        ),
      );
      expect(line.length, lessThan(8191));
    });

    test('a Settings override reaches the script only as a literal', () {
      const override = r"C:\it's\$(evil)\bash.exe";
      final script = windowsHostProbeScript(bashOverride: override);
      expect(script, contains(r"$candidates = @('C:\it''s\$(evil)\bash.exe')"));
      expect(
        windowsHostProbeScript(),
        contains(r'$candidates = @()'),
        reason: 'no override, no candidate',
      );
    });
  });

  group('the parser', () {
    test('reads every fact', () {
      final facts = WindowsHostFacts.parse(
        'MGW_PS=5.1.26100.2161\n'
        r'MGW_DEFAULT_SHELL=C:\Windows\System32\cmd.exe'
        '\n'
        r'MGW_GIT_ROOT=C:\Program Files\Git'
        '\n'
        r'MGW_BASH=C:\Program Files\Git\bin\bash.exe'
        '\n'
        r'MGW_GIT=C:\Program Files\Git\cmd\git.exe'
        '\n'
        'MGW_ADMIN=1\n',
      )!;
      expect(facts.powerShellVersion, '5.1.26100.2161');
      expect(facts.defaultShell, r'C:\Windows\System32\cmd.exe');
      expect(facts.gitRoot, r'C:\Program Files\Git');
      expect(facts.bashPath, r'C:\Program Files\Git\bin\bash.exe');
      expect(facts.gitPath, r'C:\Program Files\Git\cmd\git.exe');
      expect(facts.isAdmin, isTrue);
      expect(facts.bashFound, isTrue);
      expect(facts.bashIsDefaultShell, isFalse);
    });

    test('tolerates CRLF, banner lines and missing keys', () {
      final facts = WindowsHostFacts.parse(
        'Windows PowerShell banner\r\n'
        'MGW_DEFAULT_SHELL=\r\n'
        'MGW_ADMIN=0\r\n',
      )!;
      expect(facts.defaultShell, isEmpty);
      expect(facts.bashPath, isEmpty);
      expect(facts.bashFound, isFalse);
      expect(facts.isAdmin, isFalse);
    });

    test('returns null when there is no probe output at all', () {
      expect(WindowsHostFacts.parse(''), isNull);
      expect(
        WindowsHostFacts.parse("'export' is not recognized as an internal"),
        isNull,
      );
    });

    test('recognises bash as the default shell however it is spelled', () {
      for (final shell in [
        r'C:\Program Files\Git\bin\bash.exe',
        'C:/Program Files/Git/bin/BASH.EXE',
        'bash.exe',
      ]) {
        final facts = WindowsHostFacts.parse('MGW_DEFAULT_SHELL=$shell')!;
        expect(facts.bashIsDefaultShell, isTrue, reason: shell);
      }
      final pwsh = WindowsHostFacts.parse(
        r'MGW_DEFAULT_SHELL=C:\Program Files\PowerShell\7\pwsh.exe',
      )!;
      expect(pwsh.bashIsDefaultShell, isFalse);
    });
  });

  group('detection', () {
    test('a Windows banner, and only a Windows banner', () {
      expect(isWindowsBanner('SSH-2.0-OpenSSH_for_Windows_9.5'), isTrue);
      expect(
        isWindowsBanner('SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13'),
        isFalse,
      );
      expect(isWindowsBanner(null), isFalse);
    });

    test("cmd.exe's rejection of POSIX text", () {
      expect(
        looksLikeCmdExe(
          "'export' is not recognized as an internal or external command,\r\n"
          'operable program or batch file.',
        ),
        isTrue,
      );
      expect(looksLikeCmdExe('sh: 1: export: not found'), isFalse);
    });
  });

  group('the enable command', () {
    test('is the documented command, byte-for-byte', () {
      expect(
        enableGitBashCommand(r'C:\Program Files\Git\bin\bash.exe'),
        r"New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell "
        r"-Value 'C:\Program Files\Git\bin\bash.exe' -PropertyType String -Force",
      );
    });

    test("doubles an apostrophe in the path, PowerShell's literal rule", () {
      expect(
        enableGitBashCommand(r"D:\Bob's Tools\Git\bin\bash.exe"),
        contains(r"-Value 'D:\Bob''s Tools\Git\bin\bash.exe'"),
      );
    });

    test('never replaces the key', () {
      expect(enableGitBashCommand('x'), isNot(contains('New-Item ')));
      expect(
        kDisableGitBashCommand,
        r"Remove-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell",
      );
    });
  });

  group('the script under pwsh', () {
    test('parses with no errors', () {
      final dir = Directory.systemTemp.createTempSync('mgw_probe_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/probe.ps1')
        ..writeAsStringSync(windowsHostProbeScript(bashOverride: r'C:\x.exe'));
      final check = Process.runSync(_pwsh!, [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$tokens = $null; $errors = $null; '
            r'[void][System.Management.Automation.Language.Parser]::ParseFile('
            "'${file.path}', [ref]\$tokens, [ref]\$errors); "
            r'if ($tokens.Count -lt 50) { "only $($tokens.Count) tokens"; exit 99 }; '
            r'$errors | ForEach-Object { $_.Message }; exit $errors.Count',
      ], stdoutEncoding: utf8);
      expect(check.exitCode, 0, reason: '${check.stdout}${check.stderr}');
    }, skip: _pwsh == null ? 'pwsh is not installed' : false);

    test('reports every key and exits 0 where there is no registry', () {
      final run = Process.runSync(_pwsh!, [
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        encodedPowerShellCommand(windowsHostProbeScript()).split(' ').last,
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      final facts = WindowsHostFacts.parse(run.stdout as String);
      expect(facts, isNotNull, reason: '${run.stdout}');
      final keys = [
        for (final line in (run.stdout as String).split('\n'))
          if (line.startsWith('MGW_')) line.split('=').first,
      ];
      expect(keys, [
        'MGW_PS',
        'MGW_DEFAULT_SHELL',
        'MGW_GIT_ROOT',
        'MGW_BASH',
        'MGW_GIT',
        'MGW_ADMIN',
      ]);
      // The Windows-only lookups come back empty, not as failures.
      expect(facts!.defaultShell, isEmpty);
      expect(facts.gitRoot, isEmpty);
      expect(facts.bashPath, isEmpty);
      expect(facts.isAdmin, isFalse);
      expect(facts.powerShellVersion, isNotEmpty);
    }, skip: _pwsh == null ? 'pwsh is not installed' : false);
  });
}
