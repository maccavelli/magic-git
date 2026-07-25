import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/label_colors.dart';

void main() {
  group('tryParseLabelColor', () {
    test('parses a full RRGGBB hex with #', () {
      final c = tryParseLabelColor('#ff8800');
      expect(c, isNotNull);
      expect(c!.red, 0xFF);
      expect(c.green, 0x88);
      expect(c.blue, 0x00);
    });

    test('parses hex without #', () {
      final c = tryParseLabelColor('aabbcc');
      expect(c, isNotNull);
      expect(c!.red, 0xAA);
      expect(c.green, 0xBB);
      expect(c.blue, 0xCC);
    });

    test('returns null for 3-digit shorthand (#abc)', () {
      expect(tryParseLabelColor('#abc'), isNull);
    });

    test('returns null for short hex without #', () {
      expect(tryParseLabelColor('abc'), isNull);
    });

    test('returns null for long hex', () {
      expect(tryParseLabelColor('#aabbccdd'), isNull);
    });

    test('returns null for non-hex characters', () {
      expect(tryParseLabelColor('#gggggg'), isNull);
    });

    test('returns null for empty string', () {
      expect(tryParseLabelColor(''), isNull);
    });

    test('trims whitespace', () {
      final c = tryParseLabelColor('  #112233  ');
      expect(c, isNotNull);
      expect(c!.value, 0xFF112233);
    });

    test('alpha byte is always forced to 0xFF', () {
      // Even if someone passes a full 0xAARRGGBB, only RGB is read.
      final c = tryParseLabelColor('#ff0000');
      expect(c!.alpha, 0xFF);
    });
  });

  group('parseLabelColor', () {
    test('valid hex returns the color', () {
      final c = parseLabelColor('#00ff00');
      expect(c.green, 0xFF);
    });

    test('invalid hex falls back to system gray', () {
      final c = parseLabelColor('invalid');
      expect(c, equals(MacosColors.systemGrayColor));
    });
  });

  group('labelTextColor', () {
    test('light background returns dark text', () {
      expect(labelTextColor(const Color(0xFFFFFFFF)), const Color(0xFF000000));
      expect(labelTextColor(const Color(0xFFFFEE88)), const Color(0xFF000000));
    });

    test('dark background returns light text', () {
      expect(labelTextColor(const Color(0xFF000000)), const Color(0xFFFFFFFF));
      expect(labelTextColor(const Color(0xFF440000)), const Color(0xFFFFFFFF));
    });
  });
}
