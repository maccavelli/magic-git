// Guards the rule that real-world identity never gets committed to this repo:
// no account names, no host names, no home directories belonging to an actual
// person or an actual company. Placeholders and obviously-fictional domains
// are what documentation and fixtures are for.
//
// This exists because the rule was already written down and was still broken —
// sixteen files carried a maintainer's account name, an employer's internal
// host, and one internal FQDN, largely because each was pasted in as genuine
// evidence and nothing ever looked again. A convention that lives only in
// prose is not enforced; this is the enforcement.
//
// Deliberately shape-based. It does NOT carry a list of the identifiers it is
// looking for — hardcoding a maintainer's account name into a test to check
// that the maintainer's account name is absent would recreate the leak inside
// the guard. It matches the *form* of a real identifier and allows only
// spellings that are transparently fictional.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Home-directory owners that are transparently not a person.
///
/// Two kinds live here and both must justify themselves, because the whole
/// failure mode this guard exists for is an entry nobody looked at twice:
/// spelled-out placeholder conventions, and real system accounts a toolchain
/// actually creates. A short fixture name is fine; a plausible human account
/// name is not, and must be renamed rather than registered — the maintainer's
/// own first name was a fixture in three files until this scan flagged it.
const _placeholderAccounts = <String, String>{
  '<user>': 'The documented redaction spelling.',
  'you':
      "The app's own UI placeholder path (connection_form, "
      'local_repo_form, add_worktree_sheet).',
  'me': 'Generic.',
  'user': 'Generic.',
  'username': 'Generic.',
  'testuser': 'The fixture-account convention for this repo.',
  'test': 'Generic.',
  'dev': 'Generic.',
  'developer': 'Generic.',
  'runner': 'GitHub Actions runner home; names a CI role, not a person.',
  'ci': 'Names a CI role.',
  'root': 'System account.',
  'linuxbrew':
      r'Homebrew-on-Linux creates /home/linuxbrew; a real path '
      'shipped by a toolchain, not by anyone here (environment_probe.dart).',
  'u': 'One-letter watch-spec fixture (bounded_watch_test).',
  'x': 'One-letter fixture.',
  'sam':
      'Short fixture in local_repo_store_test; paired with an @x.com '
      'address, so it reads as invented rather than as an account.',
  'other': 'Names the negative case in a relativize test, not a person.',
  '.home.git': 'A bare-repo directory name under a temp dir, not an account.',
};

/// Shell/CI expansions that cannot be a literal account name.
final _accountIsExpansion = RegExp(r'^(\$\{?\w+\}?|<[a-z-]+>|~|\.{1,2})$');

bool _accountIsPlaceholder(String account) =>
    _placeholderAccounts.containsKey(account) ||
    _accountIsExpansion.hasMatch(account);

/// Host suffixes that cannot resolve to a real machine, plus the public forge
/// and toolchain hosts this project legitimately names.
const _fictionalOrPublicHosts = <String>[
  // RFC 2606 / RFC 6761 reserved — cannot be registered.
  '.example', '.example.com', '.example.org', '.example.net',
  '.test', '.invalid', '.localhost',
  'localhost',
  // Transparently fictional stand-ins used across the docs and fixtures.
  '.mycorp.com', 'ghe.corp', 'gitlab.corp', 'ghe.corp.example',
  // Real, public, and not anyone's private infrastructure.
  'github.com', 'gitlab.com', 'pub.dev', 'dart.dev', 'flutter.dev',
  'openssh.com', 'libssh.org', 'ietf.org', 'adr.github.io',
];

/// `user@host` in a position that reads as a real login: an `ssh`/`scp`/`rsync`
/// argument, or a git SSH remote. Skips the `git@` forge remotes, which name a
/// service account rather than a person.
final _loginPattern = RegExp(
  r'(?:ssh|scp|rsync|sftp)\b[^\n]{0,80}?\b([A-Za-z0-9._-]+)@([A-Za-z0-9.-]+)',
);

/// Absolute home directories.
final _homePattern = RegExp(r'/(?:Users|home)/([A-Za-z0-9._-]+)');

bool _hostIsFictionalOrPublic(String host) {
  final h = host.toLowerCase();
  for (final safe in _fictionalOrPublicHosts) {
    if (h == safe || h.endsWith(safe)) return true;
  }
  // A bare word with no dot is a local alias, not a resolvable identity, only
  // when it is an obvious placeholder.
  return RegExp(
    r'^(host|hostname|remote|server|devhost|myhost|<[a-z-]+>)$',
  ).hasMatch(h);
}

Iterable<File> _scannedFiles() sync* {
  const roots = ['lib', 'test', 'docs', 'scripts', 'integration_test'];
  const extensions = ['.dart', '.md', '.sh', '.yaml', '.yml', '.json'];
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (!extensions.any(entity.path.endsWith)) continue;
      // This file describes the patterns; it cannot scan itself.
      if (entity.path.endsWith('no_real_identifiers_scan_test.dart')) continue;
      yield entity;
    }
  }
}

void main() {
  test('no real account name appears in an absolute home path', () {
    final offenders = <String>[];
    for (final file in _scannedFiles()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final m in _homePattern.allMatches(lines[i])) {
          final account = m.group(1)!;
          if (_accountIsPlaceholder(account)) continue;
          offenders.add('${file.path}:${i + 1}: /…/$account');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'An absolute home directory names a real account. Write '
          '/Users/<user> or /home/<user> instead.\n${offenders.join('\n')}',
    );
  });

  test('no real login or host appears in an ssh-style command', () {
    final offenders = <String>[];
    for (final file in _scannedFiles()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final m in _loginPattern.allMatches(lines[i])) {
          final account = m.group(1)!;
          final host = m.group(2)!;
          if (account == 'git') continue; // forge service account
          final accountOk = _accountIsPlaceholder(account);
          final hostOk = _hostIsFictionalOrPublic(host);
          if (accountOk && hostOk) continue;
          offenders.add('${file.path}:${i + 1}: $account@$host');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'An ssh-style command names a real account or host. Use '
          '<user>@<host>, or a .example/.invalid/.test domain.\n'
          '${offenders.join('\n')}',
    );
  });
}
