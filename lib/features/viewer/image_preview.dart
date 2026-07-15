import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/theme/app_theme.dart';

/// Shared chrome for the image previews: the artwork centred on a neutral
/// backdrop, pan/zoomable via [InteractiveViewer].
class _ImageStage extends StatelessWidget {
  final Widget child;

  const _ImageStage({required this.child});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: MacosTheme.brightnessOf(context).resolve(
        const Color(0xFFF2F2F5),
        AppTheme.terminalBackground,
      ),
      child: InteractiveViewer(
        maxScale: 8,
        minScale: 0.2,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Renders a raster image (png/jpg/gif/…) from its decoded [bytes].
class ImagePreview extends StatelessWidget {
  final Uint8List bytes;

  const ImagePreview({super.key, required this.bytes});

  @override
  Widget build(BuildContext context) {
    return _ImageStage(
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) => _brokenImage(context),
      ),
    );
  }

  Widget _brokenImage(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const MacosIcon(
        CupertinoIcons.exclamationmark_triangle,
        size: 36,
        color: MacosColors.systemGrayColor,
      ),
      const SizedBox(height: 8),
      Text(
        'This image could not be decoded.',
        style: MacosTheme.of(context).typography.body.copyWith(
          color: MacosColors.systemGrayColor,
        ),
      ),
    ],
  );
}

/// Renders an SVG from its XML [source] (SVG content is text, so it comes
/// through the normal text-read path rather than the bytes path).
class SvgPreview extends StatelessWidget {
  final String source;

  const SvgPreview({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    return _ImageStage(
      child: SvgPicture.string(
        source,
        fit: BoxFit.contain,
        // A malformed SVG shows a placeholder instead of throwing.
        placeholderBuilder: (context) => const MacosIcon(
          CupertinoIcons.photo,
          size: 36,
          color: MacosColors.systemGrayColor,
        ),
      ),
    );
  }
}
