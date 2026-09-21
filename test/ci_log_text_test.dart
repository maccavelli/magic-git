// Unit coverage for sanitizeGhJobLog (MADR 0064, F4-A). The fixtures are
// verbatim lines from two public job logs captured with gh 2.99.0:
// percona/percona-postgresql-operator job 104212484924 and cli/cli job
// 106365973017. The real-ESC line is the same job fetched with
// `gh api --allow-escape-sequences`.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/ci_log_text.dart';

// Fixtures 1–9: captured lines. Fixture 10: literal `^[` text that must
// survive.
const _f1BomLine =
    "Dependabot\tUNKNOWN STEP\t\uFEFF2026-09-15T01:02:15.6924263Z Current runner version: '2.337.0'";
const _f2GroupLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6967489Z ##[group]GITHUB_TOKEN Permissions';
const _f3ContentsLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6969706Z Contents: read';
const _f4EndgroupLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6971640Z ##[endgroup]';
const _f5RunGroupLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1855744Z ##[group]Run mkdir -p  ./dependabot-job-1576676050-1789434129';
const _f6CaretLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1856861Z ^[[36;1mmkdir -p  ./dependabot-job-1576676050-1789434129^[[0m';
const _f7RealEscLine =
    '2026-09-15T01:02:17.1856861Z \x1B[36;1mmkdir -p  ./dependabot-job-1576676050-1789434129\x1B[0m';
const _f8WarningLine =
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:43.4700318Z updater | rehash: warning: skipping ca-certificates.crt,it does not contain exactly one certificate or CRL';
const _f9CliCaretLine =
    'build (ubuntu-latest)\tUNKNOWN STEP\t2026-09-21T14:06:20.6170077Z ^[[36;1mgo test -race -tags=integration ./...^[[0m';
const _f10Guards = [
  r"grep -E '^[[:digit:]]+$' file",
  r"sed 's/^[[:space:]]*//'",
];

const _mkdirContent =
    '2026-09-15T01:02:17.1856861Z mkdir -p  ./dependabot-job-1576676050-1789434129';

// Lines 1, 21–25 and 33–36 of the Dependabot capture, with gh's trailing
// newline.
const _capturedLog =
    "Dependabot\tUNKNOWN STEP\t\uFEFF2026-09-15T01:02:15.6924263Z Current runner version: '2.337.0'\n"
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6967489Z ##[group]GITHUB_TOKEN Permissions\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6969706Z Contents: read\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6970355Z Metadata: read\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6970925Z Packages: read\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:15.6971640Z ##[endgroup]\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1855744Z ##[group]Run mkdir -p  ./dependabot-job-1576676050-1789434129\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1856861Z ^[[36;1mmkdir -p  ./dependabot-job-1576676050-1789434129^[[0m\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1897711Z shell: /usr/bin/bash -e {0}\n'
    'Dependabot\tUNKNOWN STEP\t2026-09-15T01:02:17.1898643Z ##[endgroup]\n';

const _capturedLogClean =
    "2026-09-15T01:02:15.6924263Z Current runner version: '2.337.0'\n"
    '2026-09-15T01:02:15.6967489Z ##[group]GITHUB_TOKEN Permissions\n'
    '2026-09-15T01:02:15.6969706Z Contents: read\n'
    '2026-09-15T01:02:15.6970355Z Metadata: read\n'
    '2026-09-15T01:02:15.6970925Z Packages: read\n'
    '2026-09-15T01:02:15.6971640Z ##[endgroup]\n'
    '2026-09-15T01:02:17.1855744Z ##[group]Run mkdir -p  ./dependabot-job-1576676050-1789434129\n'
    '2026-09-15T01:02:17.1856861Z mkdir -p  ./dependabot-job-1576676050-1789434129\n'
    '2026-09-15T01:02:17.1897711Z shell: /usr/bin/bash -e {0}\n'
    '2026-09-15T01:02:17.1898643Z ##[endgroup]\n';

void main() {
  group('escape sequences', () {
    test('a caret SGR line comes out clean', () {
      expect(sanitizeGhJobLog(_f6CaretLine), _mkdirContent);
    });

    test('a caret SGR line from a second repository comes out clean', () {
      expect(
        sanitizeGhJobLog(_f9CliCaretLine),
        '2026-09-21T14:06:20.6170077Z go test -race -tags=integration ./...',
      );
    });

    test('a real-ESC line (older gh, or gh api) comes out clean', () {
      expect(sanitizeGhJobLog(_f7RealEscLine), _mkdirContent);
    });

    test('the caret EL form is removed', () {
      expect(sanitizeGhJobLog('progress^[[K done'), 'progress done');
    });

    test('an OSC string is removed with either terminator', () {
      expect(
        sanitizeGhJobLog('a\x1B]0;window title\x07b\x1B]8;;https://x\x1B\\c'),
        'abc',
      );
    });

    test('a two-byte Fe escape is removed', () {
      expect(sanitizeGhJobLog('one\x1BMtwo\x1B7three'), 'onetwo\x1B7three');
    });

    test('CSI with intermediate bytes and a non-SGR final is removed', () {
      expect(sanitizeGhJobLog('x\x1B[2 qy\x1B[?25lz'), 'xyz');
    });

    for (final guard in _f10Guards) {
      test('literal caret text survives unchanged: $guard', () {
        expect(sanitizeGhJobLog(guard), guard);
      });
    }

    test('a caret sequence gh never emits for SGR/EL is left alone', () {
      expect(sanitizeGhJobLog('echo ^[[A pressed'), 'echo ^[[A pressed');
    });
  });

  group('column prefix', () {
    test('a prefix identical on every line is removed', () {
      const log = '$_f2GroupLine\n$_f3ContentsLine\n$_f4EndgroupLine';
      expect(
        sanitizeGhJobLog(log),
        '2026-09-15T01:02:15.6967489Z ##[group]GITHUB_TOKEN Permissions\n'
        '2026-09-15T01:02:15.6969706Z Contents: read\n'
        '2026-09-15T01:02:15.6971640Z ##[endgroup]',
      );
    });

    test('empty lines do not block the prefix and are kept', () {
      const log = '$_f3ContentsLine\n\n$_f8WarningLine\n';
      expect(
        sanitizeGhJobLog(log),
        '2026-09-15T01:02:15.6969706Z Contents: read\n'
        '\n'
        '2026-09-15T01:02:43.4700318Z updater | rehash: warning: skipping '
        'ca-certificates.crt,it does not contain exactly one certificate or '
        'CRL\n',
      );
    });

    test('the prefix is kept when one line names a different step', () {
      const other =
          'Dependabot\tSet up job\t2026-09-15T01:02:15.6969706Z Contents: read';
      const log = '$_f2GroupLine\n$other';
      expect(sanitizeGhJobLog(log), log);
    });

    test('the prefix is kept when one line lacks the tabs', () {
      const log = '$_f5RunGroupLine\n$_f7RealEscLine';
      expect(
        sanitizeGhJobLog(log),
        '$_f5RunGroupLine\n'
        '2026-09-15T01:02:17.1856861Z mkdir -p  '
        './dependabot-job-1576676050-1789434129',
      );
    });

    test('a single-tab line has no prefix to remove', () {
      expect(sanitizeGhJobLog('a\tb'), 'a\tb');
    });
  });

  group('byte-order mark', () {
    test('a BOM at the start of a line\'s content is removed', () {
      expect(
        sanitizeGhJobLog(_f1BomLine),
        "2026-09-15T01:02:15.6924263Z Current runner version: '2.337.0'",
      );
    });

    test('a BOM is removed without a prefix too', () {
      expect(sanitizeGhJobLog('\uFEFFplain'), 'plain');
    });

    test('a BOM in the middle of a line survives', () {
      expect(sanitizeGhJobLog('before\uFEFFafter'), 'before\uFEFFafter');
    });

    test('a BOM before the prefix blocks the prefix but is removed', () {
      const log = '\uFEFF$_f3ContentsLine\n$_f4EndgroupLine';
      expect(sanitizeGhJobLog(log), '$_f3ContentsLine\n$_f4EndgroupLine');
    });
  });

  group('whole log', () {
    test('an empty string stays empty', () {
      expect(sanitizeGhJobLog(''), '');
    });

    test('line endings are preserved and nothing is trimmed', () {
      expect(sanitizeGhJobLog('  a  \r\n\n b\n'), '  a  \r\n\n b\n');
    });

    test('a captured excerpt comes out exactly clean', () {
      expect(sanitizeGhJobLog(_capturedLog), _capturedLogClean);
    });

    test('sanitizing is idempotent on the captured excerpt', () {
      final once = sanitizeGhJobLog(_capturedLog);
      expect(sanitizeGhJobLog(once), once);
    });
  });
}
