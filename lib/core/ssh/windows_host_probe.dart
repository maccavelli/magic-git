/// Detects a Windows SSH host and whether Git Bash is its OpenSSH default
/// shell (MADR 0070, Amendment 0070.1; 0070-PLAN D-a to D-e).
///
/// Everything else the app sends is POSIX shell text, which a Windows host
/// runs through `cmd.exe` by default and rejects. This probe must work before
/// the shell is known, so it is one PowerShell script sent as
/// `-EncodedCommand`: Base64 has no character that `cmd.exe`, PowerShell or
/// bash treats specially, so every default shell runs the line the same way.
/// It reports facts only, as `MGW_KEY=value` lines the script writes itself;
/// nothing Git prints passes through PowerShell.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Replaced by a PowerShell literal holding the Settings override for `bash`,
/// or by nothing, so the candidate list becomes `@()`.
const String _overrideSlot = '{{BASH_OVERRIDE}}';

/// Windows PowerShell 5.1 syntax throughout: it is the version every
/// supported Windows ships. A missing registry key or file is an empty value,
/// never a failure, and the script always exits 0.
const String kWindowsHostProbeScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$out = New-Object System.Text.StringBuilder
function Emit([string]$key, [string]$value) { [void]$out.Append("MGW_$key=$value`n") }
Emit 'PS' $PSVersionTable.PSVersion.ToString()
$shell = ''
try { $shell = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction Stop).DefaultShell } catch {}
Emit 'DEFAULT_SHELL' $shell
$root = ''
foreach ($hive in @('HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows')) {
  if (-not $root) { try { $root = (Get-ItemProperty -Path $hive -Name InstallPath -ErrorAction Stop).InstallPath } catch {} }
}
Emit 'GIT_ROOT' $root
$candidates = @({{BASH_OVERRIDE}})
if ($root) { $candidates += (Join-Path $root 'bin\bash.exe') }
if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
$bash = ''
foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $bash = $c; break } }
Emit 'BASH' $bash
$git = ''
$cmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmd) { $git = $cmd.Source }
Emit 'GIT' $git
$admin = '0'
try {
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $admin = '1' }
} catch {}
Emit 'ADMIN' $admin
[Console]::Out.Write($out.ToString())
exit 0
''';

/// A PowerShell single-quoted literal: no expansion, `'` doubled.
String powerShellLiteral(String value) => "'${value.replaceAll("'", "''")}'";

/// The probe script with [bashOverride] (a Settings path, or null) in place.
String windowsHostProbeScript({String? bashOverride}) {
  final override = bashOverride?.trim() ?? '';
  return kWindowsHostProbeScript.replaceFirst(
    _overrideSlot,
    override.isEmpty ? '' : powerShellLiteral(override),
  );
}

/// The one command line that runs [script] under any Windows default shell:
/// Windows PowerShell with the script as Base64 of UTF-16LE, as
/// `-EncodedCommand` requires.
String encodedPowerShellCommand(String script) {
  final utf16 = ByteData(script.length * 2);
  for (var i = 0; i < script.length; i++) {
    utf16.setUint16(i * 2, script.codeUnitAt(i), Endian.little);
  }
  final payload = base64.encode(utf16.buffer.asUint8List());
  return 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass '
      '-EncodedCommand $payload';
}

/// Whether the SSH identification string names Windows OpenSSH, e.g.
/// `SSH-2.0-OpenSSH_for_Windows_9.5`.
bool isWindowsBanner(String? remoteVersion) =>
    remoteVersion != null && remoteVersion.toLowerCase().contains('windows');

/// Whether [stderr] is `cmd.exe` rejecting POSIX text — the fallback signal
/// when a host's banner does not name Windows.
bool looksLikeCmdExe(String stderr) =>
    stderr.contains('is not recognized as an internal or external command');

/// The documented command that makes [bashPath] the OpenSSH default shell
/// (Microsoft Learn, "OpenSSH Server configuration for Windows"). It must run
/// elevated. Shown byte-for-byte as run, so a user can paste it into an
/// elevated PowerShell. Deliberately not `New-Item -Force` on the key, which
/// in the registry provider would replace the key's other values.
String enableGitBashCommand(String bashPath) =>
    "New-ItemProperty -Path 'HKLM:\\SOFTWARE\\OpenSSH' -Name DefaultShell "
    '-Value ${powerShellLiteral(bashPath)} -PropertyType String -Force';

/// What Enable runs: [enableGitBashCommand] exactly, told to stop on error and
/// to report it, so the exit code says whether the value was set (0) or not
/// (1, with the host's own message on stderr — typically access denied for
/// an account that is not an administrator).
String enableGitBashScript(String bashPath) =>
    'try { ${enableGitBashCommand(bashPath)} -ErrorAction Stop | Out-Null; '
    'exit 0 } catch { [Console]::Error.WriteLine(\$_.Exception.Message); '
    'exit 1 }';

/// Undoes [enableGitBashCommand]: every SSH user of the host gets `cmd.exe`
/// again.
const String kDisableGitBashCommand =
    "Remove-ItemProperty -Path 'HKLM:\\SOFTWARE\\OpenSSH' -Name DefaultShell";

/// What the probe found on a Windows host.
class WindowsHostFacts {
  const WindowsHostFacts({
    required this.powerShellVersion,
    required this.defaultShell,
    required this.gitRoot,
    required this.bashPath,
    required this.gitPath,
    required this.isAdmin,
  });

  /// `$PSVersionTable.PSVersion`, e.g. `5.1.26100.2161`; empty if unreported.
  final String powerShellVersion;

  /// The `DefaultShell` registry value; empty means unset, i.e. `cmd.exe`.
  final String defaultShell;

  /// Git for Windows' `InstallPath`; empty if not installed per the registry.
  final String gitRoot;

  /// The first `bash.exe` that exists; empty if none was found.
  final String bashPath;

  /// Where `git` resolves on the session's PATH; empty if it does not.
  final String gitPath;

  /// Whether the SSH session is in the Administrators role, so Enable can
  /// set a machine-wide registry value.
  final bool isAdmin;

  /// Whether `sshd` already runs commands through a bash.
  bool get bashIsDefaultShell =>
      defaultShell.toLowerCase().replaceAll('/', r'\').split(r'\').last ==
      'bash.exe';

  bool get bashFound => bashPath.isNotEmpty;

  /// Parses the probe's output, tolerating CRLF line ends, banner lines and
  /// missing keys; returns null when no probe line is present at all.
  static WindowsHostFacts? parse(String stdout) {
    final values = <String, String>{};
    for (final raw in const LineSplitter().convert(stdout)) {
      final line = raw.trimRight();
      if (!line.startsWith('MGW_')) continue;
      final eq = line.indexOf('=');
      if (eq < 0) continue;
      values[line.substring(4, eq)] = line.substring(eq + 1).trim();
    }
    if (values.isEmpty) return null;
    return WindowsHostFacts(
      powerShellVersion: values['PS'] ?? '',
      defaultShell: values['DEFAULT_SHELL'] ?? '',
      gitRoot: values['GIT_ROOT'] ?? '',
      bashPath: values['BASH'] ?? '',
      gitPath: values['GIT'] ?? '',
      isAdmin: values['ADMIN'] == '1',
    );
  }
}
