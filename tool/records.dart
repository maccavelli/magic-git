// Documentation records checker — MADR 0054
// (0054-MADR-docs-link-checker-and-standard-layout-migration.md).
//
// Nothing compiles a relative Markdown link, so nothing noticed when one broke:
// a link can sit dead for months until a reader follows it. This checks every
// link, anchor and `docs/` path mention in the repository, the record
// numbering, and the documentation layout, and `test/docs_records_test.dart`
// runs it under `flutter test`, the gate every change already passes.
//
//     dart run tool/records.dart check [--root <dir>] [--rules links,anchors,...]
//     dart run tool/records.dart next [--root <dir>]
//
// Rules (the MADR's R1–R6): links, anchors, paths, numbering, frontmatter,
// layout. `dart:io` only, so it runs without `pub get`.

import 'dart:io';

/// One problem, located.
class Finding {
  const Finding(this.rule, this.path, this.line, this.message);

  final String rule;

  /// Repository-relative, POSIX separators.
  final String path;

  /// 1-based; 0 when the finding is about the file as a whole.
  final int line;
  final String message;

  @override
  String toString() => '$path:$line: $rule: $message';
}

/// Every rule, in report order.
const allRules = [
  'links',
  'anchors',
  'paths',
  'numbering',
  'frontmatter',
  'layout',
];

/// Records whose number deliberately carries two unrelated MADRs. They predate
/// the numbering rule and may not be renumbered (CLAUDE.md); `docs/README.md`
/// names each twin. A third MADR on either number is still a finding.
const twinMadrNumbers = {'0011', '0012'};

// ---------------------------------------------------------------------------
// Files.

/// The files the checker looks at: tracked plus untracked-but-not-ignored, so
/// a record is checked before it is staged, and ignored trees (a vendored SDK,
/// `node_modules`) are not. Symlinks are skipped: `AGENTS.md` and
/// `.goosehints` point at `CLAUDE.md`, which is checked once, as itself.
List<String> checkedFiles(Directory root) {
  final result = Process.runSync('git', [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ], workingDirectory: root.path);
  if (result.exitCode != 0) {
    throw StateError('git ls-files failed in ${root.path}: ${result.stderr}');
  }
  final seen = <String>{};
  final files = <String>[];
  for (final rel in (result.stdout as String).split('\u0000')) {
    if (rel.isEmpty || !seen.add(rel)) continue;
    final type = FileSystemEntity.typeSync(
      _join(root.path, rel),
      followLinks: false,
    );
    if (type == FileSystemEntityType.file) files.add(rel);
  }
  files.sort();
  return files;
}

String _join(String a, String b) => a.endsWith('/') ? '$a$b' : '$a/$b';

/// Collapses `.` and `..` segments. Returns null for a path that climbs above
/// the root it is relative to.
String? _normalize(String path) {
  final out = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isEmpty) return null;
      out.removeLast();
    } else {
      out.add(part);
    }
  }
  return out.join('/');
}

String _dirname(String rel) {
  final i = rel.lastIndexOf('/');
  return i < 0 ? '' : rel.substring(0, i);
}

String _basename(String rel) => rel.substring(rel.lastIndexOf('/') + 1);

bool _exists(Directory root, String rel) =>
    FileSystemEntity.typeSync(
      rel.isEmpty ? root.path : _join(root.path, rel),
    ) !=
    FileSystemEntityType.notFound;

// ---------------------------------------------------------------------------
// Markdown.

/// One source line and the context the rules need about it.
class MdLine {
  const MdLine(
    this.number,
    this.text,
    this.code, {
    required this.parsed,
    required this.blockquote,
  });

  final int number;

  /// The raw line.
  final String text;

  /// The line with inline code spans removed — what links are read from.
  final String code;

  /// False inside a fence or the YAML frontmatter: nothing there is parsed.
  final bool parsed;
  final bool blockquote;
}

final _fenceOpen = RegExp(r'^ {0,3}(`{3,}|~{3,})');
final _blockquote = RegExp(r'^ {0,3}>');

/// Splits Markdown into lines, marking fences, frontmatter and blockquotes.
List<MdLine> scanMarkdown(String text) {
  final lines = text.split('\n');
  final out = <MdLine>[];
  var inFrontmatter = lines.isNotEmpty && lines.first.trimRight() == '---';
  String? fence; // the opening run while inside a fence
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    var parsed = true;
    if (inFrontmatter) {
      parsed = false;
      if (i > 0 && line.trimRight() == '---') inFrontmatter = false;
    } else if (fence != null) {
      parsed = false;
      final close = _fenceOpen.firstMatch(line);
      if (close != null &&
          close.group(1)![0] == fence[0] &&
          close.group(1)!.length >= fence.length &&
          line.substring(close.end).trim().isEmpty) {
        fence = null;
      }
    } else {
      final open = _fenceOpen.firstMatch(line);
      if (open != null) {
        fence = open.group(1);
        parsed = false;
      }
    }
    out.add(
      MdLine(
        i + 1,
        line,
        parsed ? stripInlineCode(line) : '',
        parsed: parsed,
        blockquote: _blockquote.hasMatch(line),
      ),
    );
  }
  return out;
}

/// Removes inline code spans: a backtick run closed by a run of exactly the
/// same length. An unclosed run is literal text, as in CommonMark.
String stripInlineCode(String line) {
  final buf = StringBuffer();
  var i = 0;
  while (i < line.length) {
    if (line[i] != '`') {
      buf.write(line[i]);
      i++;
      continue;
    }
    var n = 0;
    while (i + n < line.length && line[i + n] == '`') {
      n++;
    }
    final close = _findRun(line, i + n, n);
    if (close < 0) {
      buf.write(line.substring(i, i + n));
      i += n;
    } else {
      i = close + n;
    }
  }
  return buf.toString();
}

int _findRun(String line, int from, int n) {
  var i = from;
  while (i < line.length) {
    if (line[i] != '`') {
      i++;
      continue;
    }
    var m = 0;
    while (i + m < line.length && line[i + m] == '`') {
      m++;
    }
    if (m == n) return i;
    i += m;
  }
  return -1;
}

final _inlineLink = RegExp(
  r'''!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*(<[^>]*>|[^\s)]+)'''
  r'''(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)''',
);
final _refDefinition = RegExp(r'^ {0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)');
final _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');

/// Link targets on one parsed line, as written.
List<String> linkTargets(MdLine line) {
  if (!line.parsed) return const [];
  String unwrap(String t) =>
      t.startsWith('<') && t.endsWith('>') ? t.substring(1, t.length - 1) : t;
  final targets = [
    for (final m in _inlineLink.allMatches(line.code)) unwrap(m.group(1)!),
  ];
  final ref = _refDefinition.firstMatch(line.code);
  if (ref != null) targets.add(unwrap(ref.group(1)!));
  return targets;
}

bool isExternal(String target) =>
    _scheme.hasMatch(target) || target.startsWith('//');

/// A relative link, resolved: the repository-relative path (null when it
/// climbs out of the repository) and the fragment ('' when absent).
class ResolvedLink {
  const ResolvedLink(this.path, this.fragment);
  final String? path;
  final String fragment;
}

ResolvedLink resolveLink(String source, String target) {
  final hash = target.indexOf('#');
  final rawPath = hash < 0 ? target : target.substring(0, hash);
  final fragment = hash < 0 ? '' : target.substring(hash + 1);
  String decoded;
  try {
    decoded = Uri.decodeComponent(rawPath);
  } on ArgumentError {
    decoded = rawPath;
  }
  if (decoded.isEmpty) return ResolvedLink(source, fragment);
  final joined = decoded.startsWith('/')
      ? decoded
      : '${_dirname(source)}/$decoded';
  return ResolvedLink(_normalize(joined), fragment);
}

// ---------------------------------------------------------------------------
// Anchors.

final _atxHeading = RegExp(r'^ {0,3}#{1,6}\s+(.*?)\s*#*\s*$');
final _htmlAnchor = RegExp(
  r'''<a\s[^>]*?(?:id|name)\s*=\s*["']([^"']+)["']''',
  caseSensitive: false,
);
final _slugDrop = RegExp(r'[^\p{L}\p{M}\p{N}\p{Pc}\- ]', unicode: true);
final _mdLinkText = RegExp(r'!?\[([^\]]*)\]\([^)]*\)');
final _htmlTag = RegExp(r'<[^>]+>');

/// GitHub's heading slug: links reduced to their text and HTML tags removed,
/// lowercased, everything but letters, digits, `-`, `_` and spaces dropped
/// (which takes code and emphasis marks with it), spaces turned into `-`.
String githubSlug(String heading) {
  final text = heading
      .replaceAllMapped(_mdLinkText, (m) => m.group(1)!)
      .replaceAll(_htmlTag, '')
      .toLowerCase();
  return text.replaceAll(_slugDrop, '').replaceAll(' ', '-');
}

/// Every anchor a Markdown file offers: heading slugs (repeats suffixed `-1`,
/// `-2`, …) and explicit `<a id>` / `<a name>` anchors.
Set<String> anchorsOf(String text) {
  final counts = <String, int>{};
  final anchors = <String>{};
  for (final line in scanMarkdown(text)) {
    if (!line.parsed) continue;
    final heading = _atxHeading.firstMatch(line.text);
    if (heading != null) {
      final slug = githubSlug(heading.group(1)!);
      final n = counts[slug] ?? 0;
      anchors.add(n == 0 ? slug : '$slug-$n');
      counts[slug] = n + 1;
    }
    for (final m in _htmlAnchor.allMatches(line.text)) {
      anchors.add(m.group(1)!.toLowerCase());
    }
  }
  return anchors;
}

// ---------------------------------------------------------------------------
// Rules.

typedef Rule = List<Finding> Function(Directory root, List<String> files);

String _read(Directory root, String rel) =>
    File(_join(root.path, rel)).readAsStringSync();

Iterable<String> _markdown(List<String> files) =>
    files.where((f) => f.endsWith('.md'));

/// R1 — every relative link resolves to an existing file or directory.
List<Finding> checkLinks(Directory root, List<String> files) {
  final findings = <Finding>[];
  for (final file in _markdown(files)) {
    for (final line in scanMarkdown(_read(root, file))) {
      for (final target in linkTargets(line)) {
        if (isExternal(target) || target.startsWith('#')) continue;
        final resolved = resolveLink(file, target);
        final path = resolved.path;
        if (path == null) {
          findings.add(
            Finding(
              'links',
              file,
              line.number,
              '$target leaves the repository',
            ),
          );
        } else if (!_exists(root, path)) {
          findings.add(
            Finding('links', file, line.number, '$target does not exist'),
          );
        }
      }
    }
  }
  return findings;
}

/// R2 — a fragment on a link to a Markdown file names one of its anchors.
List<Finding> checkAnchors(Directory root, List<String> files) {
  final findings = <Finding>[];
  final cache = <String, Set<String>>{};
  for (final file in _markdown(files)) {
    for (final line in scanMarkdown(_read(root, file))) {
      for (final target in linkTargets(line)) {
        if (isExternal(target)) continue;
        final resolved = resolveLink(file, target);
        final path = resolved.path;
        if (resolved.fragment.isEmpty ||
            path == null ||
            !path.endsWith('.md') ||
            FileSystemEntity.typeSync(_join(root.path, path)) !=
                FileSystemEntityType.file) {
          continue;
        }
        final anchors = cache.putIfAbsent(
          path,
          () => anchorsOf(_read(root, path)),
        );
        String fragment;
        try {
          fragment = Uri.decodeComponent(resolved.fragment).toLowerCase();
        } on ArgumentError {
          fragment = resolved.fragment.toLowerCase();
        }
        if (!anchors.contains(fragment)) {
          findings.add(
            Finding(
              'anchors',
              file,
              line.number,
              '$target: no heading or anchor "#${resolved.fragment}" in $path',
            ),
          );
        }
      }
    }
  }
  return findings;
}

final _docsMention = RegExp(r'(?<![\w/.-])docs/[\w./-]*[\w-]\.md');
final _linkTargetPart = RegExp(r'\]\([^)]*\)');

/// R3 — every `docs/….md` path mentioned in prose or a code comment exists.
/// Fences, blockquotes and frontmatter are verbatim or historical and are not
/// read; link targets are R1's.
List<Finding> checkPathMentions(Directory root, List<String> files) {
  final findings = <Finding>[];
  void check(String file, int number, String text) {
    for (final m in _docsMention.allMatches(text)) {
      if (!_exists(root, m.group(0)!)) {
        findings.add(
          Finding('paths', file, number, '${m.group(0)} does not exist'),
        );
      }
    }
  }

  for (final file in files) {
    if (file.endsWith('.md')) {
      for (final line in scanMarkdown(_read(root, file))) {
        if (!line.parsed || line.blockquote) continue;
        check(file, line.number, line.text.replaceAll(_linkTargetPart, ']'));
      }
    } else if (file.endsWith('.dart')) {
      final lines = _read(root, file).split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) check(file, i + 1, lines[i]);
      }
    }
  }
  return findings;
}

final _recordName = RegExp(r'^(\d{4})-([A-Z]+(?:-[A-Z]+)*)-.*\.md$');
final _strictRecordName = RegExp(
  r'^\d{4}-(MADR|PLAN|REPORT|GATES)-[a-z0-9]+(-[a-z0-9]+)*\.md$',
);

/// A numbered record file: its path, number and kind.
class Record {
  const Record(this.path, this.number, this.kind);
  final String path;
  final String number;
  final String kind;
}

List<Record> recordsIn(List<String> files) => [
  for (final f in files)
    if (_recordName.firstMatch(_basename(f)) case final m?)
      Record(f, m.group(1)!, m.group(2)!),
];

/// R4 — one MADR per number (the pinned twins aside), and every PLAN beside
/// its MADR.
List<Finding> checkNumbering(Directory root, List<String> files) {
  final findings = <Finding>[];
  final byNumber = <String, List<Record>>{};
  for (final r in recordsIn(files)) {
    byNumber.putIfAbsent(r.number, () => []).add(r);
  }
  for (final MapEntry(key: number, value: records) in byNumber.entries) {
    final madrs = records.where((r) => r.kind == 'MADR').toList();
    final allowed = twinMadrNumbers.contains(number) ? 2 : 1;
    if (madrs.length > allowed) {
      for (final m in madrs) {
        findings.add(
          Finding(
            'numbering',
            m.path,
            0,
            '$number carries ${madrs.length} MADRs; renumber the newest '
                '(the next free number is `dart run tool/records.dart next`)',
          ),
        );
      }
    }
    final madrDirs = {for (final m in madrs) _dirname(m.path)};
    for (final plan in records.where((r) => r.kind == 'PLAN')) {
      if (madrDirs.isNotEmpty && !madrDirs.contains(_dirname(plan.path))) {
        findings.add(
          Finding(
            'numbering',
            plan.path,
            0,
            'PLAN is not in the directory of its MADR (${madrDirs.join(', ')})',
          ),
        );
      }
    }
  }
  return findings;
}

/// The next free record number over the whole repository.
String nextNumber(Directory root, List<String> files) {
  var max = 0;
  for (final r in recordsIn(files)) {
    final n = int.parse(r.number);
    if (n > max) max = n;
  }
  return (max + 1).toString().padLeft(4, '0');
}

/// The keys every record's frontmatter carries: its state, and when that
/// state was last checked against the code (CLAUDE.md).
final _requiredKeys = {
  for (final key in ['status', 'verified'])
    key: RegExp('^$key:\\s*\\S', multiLine: true),
};

/// R5 — every record opens with YAML frontmatter carrying `status:` and
/// `verified:`.
List<Finding> checkFrontmatter(Directory root, List<String> files) {
  final findings = <Finding>[];
  for (final r in recordsIn(files)) {
    final text = _read(root, r.path);
    final lines = text.split('\n');
    if (lines.isEmpty || lines.first.trimRight() != '---') {
      findings.add(Finding('frontmatter', r.path, 1, 'no YAML frontmatter'));
      continue;
    }
    final end = lines.indexWhere((l) => l.trimRight() == '---', 1);
    final frontmatter = lines
        .sublist(1, end < 0 ? lines.length : end)
        .join('\n');
    for (final MapEntry(key: key, value: pattern) in _requiredKeys.entries) {
      if (!pattern.hasMatch(frontmatter)) {
        findings.add(
          Finding('frontmatter', r.path, 1, 'frontmatter has no $key:'),
        );
      }
    }
  }
  return findings;
}

const _docsChildren = {
  'README.md',
  'architecture.md',
  'decisions',
  'reports',
  'guides',
};

/// R6 — the documentation tree has the standard's shape, and its index links
/// every record.
List<Finding> checkLayout(Directory root, List<String> files) {
  final findings = <Finding>[];

  final children = {
    for (final f in files)
      if (f.startsWith('docs/')) f.substring(5).split('/').first,
  };
  for (final child in children.difference(_docsChildren)) {
    findings.add(
      Finding(
        'layout',
        'docs/$child',
        0,
        'docs/ holds only README.md, architecture.md, decisions/, reports/ '
            'and guides/',
      ),
    );
  }
  for (final required in ['docs/README.md', 'docs/architecture.md']) {
    if (!files.contains(required)) {
      findings.add(Finding('layout', required, 0, 'missing'));
    }
  }

  for (final r in recordsIn(files)) {
    final name = _basename(r.path);
    if (!_strictRecordName.hasMatch(name)) {
      findings.add(
        Finding(
          'layout',
          r.path,
          0,
          'record names are NNNN-(MADR|PLAN|REPORT|GATES)-kebab-title.md',
        ),
      );
      continue;
    }
    final dir = _dirname(r.path);
    final want = r.kind == 'MADR' || r.kind == 'PLAN' ? 'decisions' : 'reports';
    if (dir != 'docs/$want' && !dir.endsWith('/docs/$want')) {
      findings.add(
        Finding('layout', r.path, 0, '${r.kind} records live in docs/$want/'),
      );
    }
  }

  for (final f in files) {
    final parts = f.split('/');
    final g = parts.indexOf('guides');
    if (g > 0 &&
        parts[g - 1] == 'docs' &&
        RegExp(r'^\d{4}-').hasMatch(parts.last)) {
      findings.add(
        Finding(
          'layout',
          f,
          0,
          'guides are unnumbered; a record belongs '
              'in decisions/ or reports/',
        ),
      );
    }
  }

  Set<String> linksFrom(String file) => {
    if (files.contains(file))
      for (final line in scanMarkdown(_read(root, file)))
        for (final target in linkTargets(line))
          if (!isExternal(target)) ?resolveLink(file, target).path,
  };

  if (!linksFrom('README.md').contains('docs/README.md')) {
    findings.add(
      const Finding('layout', 'README.md', 0, 'does not link docs/README.md'),
    );
  }

  final indexLinks = <String, Set<String>>{};
  for (final r in recordsIn(files)) {
    final dir = _dirname(r.path);
    if (!dir.endsWith('decisions') && !dir.endsWith('reports')) continue;
    final index = '${_dirname(dir)}/README.md';
    final links = indexLinks.putIfAbsent(index, () => linksFrom(index));
    if (!links.contains(r.path)) {
      findings.add(Finding('layout', r.path, 0, 'not linked from $index'));
    }
  }
  return findings;
}

const Map<String, Rule> ruleFunctions = {
  'links': checkLinks,
  'anchors': checkAnchors,
  'paths': checkPathMentions,
  'numbering': checkNumbering,
  'frontmatter': checkFrontmatter,
  'layout': checkLayout,
};

/// Runs the named rules over [root].
List<Finding> check(Directory root, {List<String> rules = allRules}) {
  final files = checkedFiles(root);
  return [for (final rule in rules) ...ruleFunctions[rule]!(root, files)];
}

// ---------------------------------------------------------------------------
// CLI.

void main(List<String> args) {
  String? option(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final root = Directory(option('--root') ?? Directory.current.path);
  final command = args.isEmpty ? '' : args.first;
  switch (command) {
    case 'next':
      stdout.writeln(nextNumber(root, checkedFiles(root)));
    case 'check':
      final rules = option('--rules')?.split(',') ?? allRules;
      final unknown = rules.where((r) => !ruleFunctions.containsKey(r));
      if (unknown.isNotEmpty) {
        stderr.writeln('unknown rule(s): ${unknown.join(', ')}');
        exitCode = 2;
        return;
      }
      final findings = check(root, rules: rules);
      findings.forEach(stdout.writeln);
      stdout.writeln('${findings.length} finding(s)');
      exitCode = findings.isEmpty ? 0 : 1;
    default:
      stderr.writeln(
        'usage: dart run tool/records.dart check [--root <dir>] '
        '[--rules ${allRules.join(',')}]\n'
        '       dart run tool/records.dart next [--root <dir>]',
      );
      exitCode = 2;
  }
}
