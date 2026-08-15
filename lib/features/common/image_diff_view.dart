import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/file_actions.dart';
import '../viewer/remote_edit_service.dart';
import 'buttons.dart';
import 'inline_action_button.dart';

/// A compressed side is capped before transfer; pixel memory is capped before
/// Flutter decodes it. Two simultaneously shown sides therefore have explicit
/// upper bounds instead of relying only on the executor's general 50 MiB cap.
const int kImageDiffMaxEncodedBytes = 12 * 1024 * 1024;
const int kImageDiffMaxDecodedBytes = 64 * 1024 * 1024;

typedef ImageDiffBlobKey = ({String repoPath, String path, String? revision});

class ImageDiffAsset {
  final Uint8List bytes;
  final int width;
  final int height;

  const ImageDiffAsset({
    required this.bytes,
    required this.width,
    required this.height,
  });

  int get decodedBytes => width * height * 4;
}

class ImageDiffReadException implements Exception {
  final String message;
  const ImageDiffReadException(this.message);

  @override
  String toString() => message;
}

/// The signature every Git LFS pointer file starts with (the pointer spec's
/// mandatory first line). A checked-out-but-unsmudged LFS image is this tiny
/// text stub, not image data — decode would fail with a misleading "could not
/// be decoded" message (0009 M17).
const String _lfsPointerSignature = 'version https://git-lfs';

@visibleForTesting
Future<ImageDiffAsset> inspectImageDiffBytes(Uint8List bytes) async {
  if (bytes.length >= _lfsPointerSignature.length &&
      String.fromCharCodes(bytes, 0, _lfsPointerSignature.length) ==
          _lfsPointerSignature) {
    throw const ImageDiffReadException(
      'This side is a Git LFS pointer, not image data. '
      'Run `git lfs pull` on the host to fetch the real file.',
    );
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    final decodedBytes = width * height * 4;
    if (width < 1 || height < 1 || decodedBytes > kImageDiffMaxDecodedBytes) {
      throw const ImageDiffReadException(
        'This image is too large to decode safely in the comparison view.',
      );
    }
    return ImageDiffAsset(bytes: bytes, width: width, height: height);
  } catch (error) {
    if (error is ImageDiffReadException) rethrow;
    throw const ImageDiffReadException(
      'This image could not be decoded for comparison.',
    );
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

final imageDiffBlobProvider = FutureProvider.autoDispose
    .family<ImageDiffAsset, ImageDiffBlobKey>((ref, key) async {
      final git = ref.watch(gitServiceProvider);
      try {
        final encoded = key.revision == null
            ? await git.readFileBase64Bounded(
                key.repoPath,
                key.path,
                maxBytes: kImageDiffMaxEncodedBytes,
              )
            : await git.showBlobBase64(
                key.repoPath,
                key.revision!,
                key.path,
                maxBytes: kImageDiffMaxEncodedBytes,
              );
        return inspectImageDiffBytes(base64.decode(encoded));
      } on GitException catch (error) {
        if (error.result.exitCode == 75) {
          throw const ImageDiffReadException(
            'This image exceeds the 12 MiB comparison transfer budget.',
          );
        }
        throw const ImageDiffReadException(
          'This image side is unavailable. It may have moved or changed.',
        );
      } on FormatException {
        throw const ImageDiffReadException(
          'This image side returned invalid encoded data.',
        );
      }
    });

enum ImageDiffMode { sideBySide, overlay, slider }

/// A bounded two-sided raster comparison. A null path denotes a side that does
/// not exist (an added/deleted image); a null revision denotes the worktree.
class ImageDiffView extends ConsumerStatefulWidget {
  final String repoPath;
  final String displayPath;
  final String? beforePath;
  final String? beforeRevision;
  final String? afterPath;
  final String? afterRevision;
  final bool canOpenExternally;

  const ImageDiffView({
    super.key,
    required this.repoPath,
    required this.displayPath,
    this.beforePath,
    this.beforeRevision,
    this.afterPath,
    this.afterRevision,
    this.canOpenExternally = false,
  });

  @override
  ConsumerState<ImageDiffView> createState() => _ImageDiffViewState();
}

class _ImageDiffViewState extends ConsumerState<ImageDiffView> {
  ImageDiffMode _mode = ImageDiffMode.sideBySide;
  double _reveal = 0.5;

  AsyncValue<ImageDiffAsset>? _side(String? path, String? revision) =>
      path == null
      ? null
      : ref.watch(
          imageDiffBlobProvider((
            repoPath: widget.repoPath,
            path: path,
            revision: revision,
          )),
        );

  @override
  Widget build(BuildContext context) {
    final before = _side(widget.beforePath, widget.beforeRevision);
    final after = _side(widget.afterPath, widget.afterRevision);
    final failed = before?.hasError == true || after?.hasError == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(context),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: failed
              ? _fallback(context, before, after)
              : _comparison(context, before, after),
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Image comparison',
              style: MacosTheme.of(
                context,
              ).typography.caption1.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          for (final mode in ImageDiffMode.values)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: InlineActionButton(
                label: switch (mode) {
                  ImageDiffMode.sideBySide => 'Side by Side',
                  ImageDiffMode.overlay => 'Overlay',
                  ImageDiffMode.slider => 'Slider',
                },
                icon: _mode == mode
                    ? CupertinoIcons.check_mark
                    : switch (mode) {
                        ImageDiffMode.sideBySide =>
                          CupertinoIcons.square_split_2x1,
                        ImageDiffMode.overlay => CupertinoIcons.square_stack,
                        ImageDiffMode.slider =>
                          CupertinoIcons.slider_horizontal_3,
                      },
                onPressed: () => setState(() => _mode = mode),
              ),
            ),
        ],
      ),
    );
  }

  Widget _comparison(
    BuildContext context,
    AsyncValue<ImageDiffAsset>? before,
    AsyncValue<ImageDiffAsset>? after,
  ) {
    if (before?.isLoading == true || after?.isLoading == true) {
      return const Center(child: ProgressCircle());
    }
    final beforeAsset = before?.value;
    final afterAsset = after?.value;
    return switch (_mode) {
      ImageDiffMode.sideBySide => Row(
        children: [
          Expanded(child: _sideStage(context, 'Before', beforeAsset)),
          Container(width: 1, color: MacosColors.separatorColor),
          Expanded(child: _sideStage(context, 'After', afterAsset)),
        ],
      ),
      ImageDiffMode.overlay => _overlay(context, beforeAsset, afterAsset),
      ImageDiffMode.slider => _slider(context, beforeAsset, afterAsset),
    };
  }

  Widget _sideStage(BuildContext context, String label, ImageDiffAsset? asset) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _metadata(context, label, asset),
        Expanded(child: _imageStage(context, asset)),
      ],
    );
  }

  Widget _metadata(BuildContext context, String label, ImageDiffAsset? asset) {
    final detail = asset == null
        ? 'Not present'
        : '${asset.width} × ${asset.height} · ${_bytes(asset.bytes.length)}';
    return Semantics(
      label: '$label image, $detail',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          '$label  $detail',
          style: MacosTheme.of(context).typography.caption1,
        ),
      ),
    );
  }

  Widget _imageStage(BuildContext context, ImageDiffAsset? asset) {
    return ColoredBox(
      color: MacosTheme.brightnessOf(
        context,
      ).resolve(const Color(0xFFF2F2F5), AppTheme.terminalBackground),
      child: asset == null
          ? const Center(
              child: MacosIcon(
                CupertinoIcons.nosign,
                size: 34,
                color: MacosColors.systemGrayColor,
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Image.memory(
                asset.bytes,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            ),
    );
  }

  Widget _overlay(
    BuildContext context,
    ImageDiffAsset? before,
    ImageDiffAsset? after,
  ) => Stack(
    fit: StackFit.expand,
    children: [
      _imageStage(context, before),
      Opacity(opacity: 0.5, child: _imageStage(context, after)),
      Positioned(left: 12, top: 10, child: _modeLegend(context, '50% overlay')),
    ],
  );

  Widget _slider(
    BuildContext context,
    ImageDiffAsset? before,
    ImageDiffAsset? after,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final split = constraints.maxWidth * _reveal;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => setState(() {
          _reveal = (details.localPosition.dx / constraints.maxWidth).clamp(
            0.0,
            1.0,
          );
        }),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _imageStage(context, after),
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: _reveal,
                child: SizedBox(
                  width: constraints.maxWidth,
                  child: _imageStage(context, before),
                ),
              ),
            ),
            Positioned(
              left: split - 1,
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: MacosColors.systemBlueColor),
            ),
            Positioned(
              left: 12,
              top: 10,
              child: _modeLegend(context, 'Before'),
            ),
            Positioned(
              right: 12,
              top: 10,
              child: _modeLegend(context, 'After'),
            ),
          ],
        ),
      );
    },
  );

  Widget _modeLegend(BuildContext context, String label) => DecoratedBox(
    decoration: BoxDecoration(
      color: MacosTheme.of(context).canvasColor.withValues(alpha: 0.84),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      child: Text(label, style: MacosTheme.of(context).typography.caption1),
    ),
  );

  Widget _fallback(
    BuildContext context,
    AsyncValue<ImageDiffAsset>? before,
    AsyncValue<ImageDiffAsset>? after,
  ) {
    final error = before?.error ?? after?.error;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MacosIcon(
              CupertinoIcons.photo,
              size: 40,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(height: 10),
            Text(
              'Binary image change',
              style: MacosTheme.of(context).typography.title3,
            ),
            const SizedBox(height: 6),
            Text(
              error?.toString() ?? 'The image comparison is unavailable.',
              textAlign: TextAlign.center,
              style: MacosTheme.of(
                context,
              ).typography.body.copyWith(color: MacosColors.systemGrayColor),
            ),
            if (widget.canOpenExternally) ...[
              const SizedBox(height: 14),
              AppPushButton(
                controlSize: ControlSize.large,
                secondary: true,
                onPressed: _openExternally,
                child: const Text('Open in Default App'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openExternally() {
    final isLocal = ref.read(connectionProvider).isLocal;
    if (isLocal) {
      openFiles(['${widget.repoPath}/${widget.displayPath}']);
    } else {
      ref
          .read(remoteEditServiceProvider.notifier)
          .openRemoteFile(widget.repoPath, widget.displayPath);
    }
  }

  String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}
