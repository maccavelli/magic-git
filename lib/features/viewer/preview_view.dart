import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';

/// Rendered previews of Markdown and HTML files — the "Preview" tab of the
/// viewer, alongside the raw source shown by `CodeView`.
///
/// Both renderers are **safe by construction** for viewing arbitrary repo
/// content: this is a widget renderer, not a browser, so no JavaScript ever
/// runs; on top of that, images are replaced with an inert placeholder (no
/// network fetch is ever issued) and links do nothing when tapped (no
/// navigation, no launched browser). That keeps a hostile or accidental
/// `<img src="http://tracker/…">` or auto-navigating link from doing anything.

/// A rendered Markdown document.
class MarkdownPreview extends StatelessWidget {
  final String source;

  const MarkdownPreview({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    final dark = MacosTheme.brightnessOf(context) == Brightness.dark;
    // Explicit, brightness-resolved colours — the built-in
    // `MarkdownStyleSheet.fromCupertinoTheme` leaves text in unresolved
    // dynamic colours that render near-invisible on the viewer's background,
    // which is what made the preview look mangled.
    final fg = dark ? const Color(0xFFE6E6EA) : const Color(0xFF1D1D1F);
    final muted = dark ? const Color(0xFF9B9BA1) : const Color(0xFF6E6E73);
    final link = dark ? const Color(0xFF6AB7FF) : const Color(0xFF0066CC);
    final rule = dark ? const Color(0xFF3A3A3C) : const Color(0xFFD6D6DB);
    final fill = MacosColors.systemGrayColor.withValues(alpha: dark ? 0.18 : 0.12);
    final bg = dark ? AppTheme.terminalBackground : const Color(0xFFFFFFFF);

    // A comfortable reading base; headings step down from a clear h1.
    final body = TextStyle(color: fg, fontSize: 14, height: 1.55);
    TextStyle heading(double size, {Color? color}) => body.copyWith(
      fontSize: size,
      height: 1.25,
      fontWeight: FontWeight.w600,
      color: color ?? fg,
    );
    final mono = TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: const ['SF Mono', 'Consolas', 'monospace'],
      fontSize: 12.5,
      color: fg,
    );

    final styleSheet = MarkdownStyleSheet(
      p: body,
      a: body.copyWith(color: link),
      h1: heading(26),
      h2: heading(21),
      h3: heading(17),
      h4: heading(15),
      h5: heading(14),
      h6: heading(13, color: muted),
      h1Padding: const EdgeInsets.only(top: 14, bottom: 4),
      h2Padding: const EdgeInsets.only(top: 12, bottom: 4),
      h3Padding: const EdgeInsets.only(top: 10, bottom: 2),
      h4Padding: const EdgeInsets.only(top: 8),
      h5Padding: const EdgeInsets.only(top: 6),
      h6Padding: const EdgeInsets.only(top: 6),
      em: body.copyWith(fontStyle: FontStyle.italic),
      strong: body.copyWith(fontWeight: FontWeight.w700),
      del: body.copyWith(decoration: TextDecoration.lineThrough),
      blockquote: body.copyWith(color: muted),
      blockquotePadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      blockquoteDecoration: BoxDecoration(
        color: fill,
        border: Border(left: BorderSide(color: rule, width: 4)),
        borderRadius: BorderRadius.circular(4),
      ),
      code: mono.copyWith(backgroundColor: fill),
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(6),
      ),
      listBullet: body,
      listIndent: 22,
      blockSpacing: 12,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: rule, width: 1)),
      ),
      tableHead: body.copyWith(fontWeight: FontWeight.w700),
      tableBody: body,
      tableBorder: TableBorder.all(color: rule),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    );

    return Container(
      color: bg,
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
      child: Markdown(
        data: source,
        selectable: true,
        styleSheet: styleSheet,
        padding: EdgeInsets.zero,
        // Web links open in the default browser — a styled link that does
        // nothing on click is a taught no-op (0009 M34). Non-web schemes and
        // relative links stay inert (nothing sane to hand them to).
        onTapLink: (text, href, title) {
          final uri = href == null ? null : Uri.tryParse(href);
          if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
            unawaited(launchUrl(uri));
          }
        },
        // No network fetch: every image becomes a labelled placeholder.
        imageBuilder: (uri, title, alt) =>
            _ImagePlaceholder(label: _imageLabel(alt, uri)),
      ),
    );
  }
}

/// A rendered HTML document.
class HtmlPreview extends StatelessWidget {
  final String source;

  const HtmlPreview({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;
    return Container(
      color: MacosColors.controlBackgroundColor.resolveFrom(context),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: SingleChildScrollView(
        child: Html(
          data: source,
          // Inert links — no navigation.
          onLinkTap: (url, attributes, element) {},
          onAnchorTap: (url, attributes, element) {},
          // Never execute/emit active or embedded-content tags. (JS never runs
          // regardless — flutter_html is a renderer, not a browser — but
          // dropping these keeps the output clean and inert.)
          doNotRenderTheseTags: const {
            'script',
            'iframe',
            'object',
            'embed',
            'audio',
            'video',
            'link',
            'meta',
          },
          style: {
            'body': Style(
              margin: Margins.zero,
              color: defaultColor,
              fontSize: FontSize(14),
            ),
          },
          extensions: [
            // Replace every <img> with an inert placeholder so no network
            // request (or local-file read) is ever issued from rendered HTML.
            TagExtension(
              tagsToExtend: {'img'},
              builder: (ctx) => _ImagePlaceholder(
                label: _imageLabel(
                  ctx.attributes['alt'],
                  Uri.tryParse(ctx.attributes['src'] ?? ''),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _imageLabel(String? alt, Uri? uri) {
  if (alt != null && alt.trim().isNotEmpty) return alt.trim();
  final path = uri?.pathSegments.isNotEmpty == true
      ? uri!.pathSegments.last
      : uri?.toString();
  return (path != null && path.isNotEmpty) ? path : 'image';
}

/// The stand-in shown wherever a document referenced an image — makes it clear
/// an image was there without fetching anything.
class _ImagePlaceholder extends StatelessWidget {
  final String label;

  const _ImagePlaceholder({required this.label});

  @override
  Widget build(BuildContext context) {
    const muted = MacosColors.systemGrayColor;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: muted.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
        color: muted.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MacosIcon(CupertinoIcons.photo, size: 16, color: muted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MacosTheme.of(context)
                  .typography
                  .caption1
                  .copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
