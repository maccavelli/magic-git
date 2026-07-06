import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/shell_escaper.dart';

void main() {
  group('ShellEscaper.escape', () {
    test('empty string', () {
      expect(ShellEscaper.escape(''), "''");
    });

    test('simple literal', () {
      expect(ShellEscaper.escape('main'), "'main'");
    });

    test('embedded single quote uses POSIX close-reopen', () {
      expect(ShellEscaper.escape("it's"), "'it'\\''s'");
    });

    test('command injection attempt stays one token', () {
      const input = "'; rm -rf / #'";
      final escaped = ShellEscaper.escape(input);
      expect(escaped, startsWith("'"));
      expect(escaped, endsWith("'"));
      // Content is quoted — no unescaped shell break-out sequence.
      expect(escaped.replaceAll("'\\''", ''), isNot(endsWith(';')));
    });

    test('spaces and shell metacharacters', () {
      const input = r'a b; $(whoami)';
      expect(ShellEscaper.escape(input), r"'a b; $(whoami)'");
    });

    test('rejects an embedded NUL byte', () {
      final input = 'a${String.fromCharCode(0)}b';
      expect(() => ShellEscaper.escape(input), throwsArgumentError);
    });
  });
}
