import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/viewer/file_type.dart';

void main() {
  group('viewerFileTypeFor', () {
    test('maps common source extensions to highlight.js language ids', () {
      expect(viewerFileTypeFor('lib/main.dart').languageId, 'dart');
      expect(viewerFileTypeFor('a/b/script.py').languageId, 'python');
      expect(viewerFileTypeFor('config.yaml').languageId, 'yaml');
      expect(viewerFileTypeFor('config.yml').languageId, 'yaml');
      expect(viewerFileTypeFor('data.json').languageId, 'json');
      expect(viewerFileTypeFor('pom.xml').languageId, 'xml');
      expect(viewerFileTypeFor('styles.css').languageId, 'css');
      expect(viewerFileTypeFor('app.ts').languageId, 'typescript');
      expect(viewerFileTypeFor('run.sh').languageId, 'bash');
      expect(viewerFileTypeFor('q.sql').languageId, 'sql');
    });

    test('markdown is highlightable AND previewable as markdown', () {
      final md = viewerFileTypeFor('README.md');
      expect(md.languageId, 'markdown');
      expect(md.preview, PreviewKind.markdown);
      expect(md.hasPreview, isTrue);
      expect(
        viewerFileTypeFor('docs/GUIDE.markdown').preview,
        PreviewKind.markdown,
      );
    });

    test('html maps to the xml grammar but previews as html', () {
      final html = viewerFileTypeFor('index.html');
      expect(html.languageId, 'xml');
      expect(html.preview, PreviewKind.html);
      expect(viewerFileTypeFor('page.htm').preview, PreviewKind.html);
    });

    test('images preview as image and report isImage', () {
      for (final p in ['a.png', 'b.JPG', 'c.jpeg', 'd.gif', 'e.webp']) {
        final t = viewerFileTypeFor(p);
        expect(t.preview, PreviewKind.image, reason: p);
        expect(t.isImage, isTrue, reason: p);
      }
    });

    test('svg previews as svg (vector) and is highlightable as xml', () {
      final svg = viewerFileTypeFor('logo.svg');
      expect(svg.preview, PreviewKind.svg);
      expect(svg.languageId, 'xml');
      expect(svg.isImage, isTrue);
    });

    test('extension match is case-insensitive', () {
      expect(viewerFileTypeFor('MAIN.DART').languageId, 'dart');
      expect(viewerFileTypeFor('Read.MD').preview, PreviewKind.markdown);
    });

    test('special filenames without extensions are recognised', () {
      expect(viewerFileTypeFor('Dockerfile').languageId, 'dockerfile');
      expect(viewerFileTypeFor('deploy/Dockerfile').languageId, 'dockerfile');
      expect(viewerFileTypeFor('Makefile').languageId, 'makefile');
      expect(viewerFileTypeFor('CMakeLists.txt').languageId, 'cmake');
      expect(viewerFileTypeFor('Gemfile').languageId, 'ruby');
    });

    test('dotfiles: leading dot is not treated as an extension', () {
      // `.gitignore` is a known plain file (no crash treating "gitignore" as
      // an extension), and an unknown dotfile falls back to plain.
      final gi = viewerFileTypeFor('.gitignore');
      expect(gi.languageId, isNull);
      expect(gi.preview, PreviewKind.none);
      expect(viewerFileTypeFor('.editorconfig').languageId, 'ini');
      expect(viewerFileTypeFor('.env').languageId, 'bash');
    });

    test('multi-dot names use the final extension', () {
      expect(viewerFileTypeFor('archive.tar.gz').languageId, isNull);
      expect(viewerFileTypeFor('app.min.js').languageId, 'javascript');
    });

    test('unknown and extension-less files fall back to plain', () {
      expect(viewerFileTypeFor('mystery.qwerty'), same(ViewerFileType.plain));
      expect(viewerFileTypeFor('LICENSE'), same(ViewerFileType.plain));
      expect(viewerFileTypeFor('bin/tool').languageId, isNull);
    });
  });
}
