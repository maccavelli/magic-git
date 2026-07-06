import 'package:flutter/cupertino.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:macos_ui/macos_ui.dart';

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
    final brightness = MacosTheme.brightnessOf(context);
    final cupertino = CupertinoThemeData(brightness: brightness);
    final base = MarkdownStyleSheet.fromCupertinoTheme(cupertino);
    final typography = MacosTheme.of(context).typography;
    final styleSheet = base.copyWith(
      // Give code spans/blocks the app's monospace look and a subtle fill.
      code: typography.body.copyWith(
        fontFamily: 'Menlo',
        fontFamilyFallback: const ['SF Mono', 'Consolas', 'monospace'],
        fontSize: 12.5,
        backgroundColor: MacosColors.systemGrayColor.withValues(alpha: 0.15),
      ),
      codeblockDecoration: BoxDecoration(
        color: MacosColors.systemGrayColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
    );

    return Container(
      color: MacosColors.controlBackgroundColor.resolveFrom(context),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Markdown(
        data: source,
        selectable: true,
        styleSheet: styleSheet,
        padding: EdgeInsets.zero,
        // No navigation: tapping a link is inert.
        onTapLink: (text, href, title) {},
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
