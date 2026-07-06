import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'viewer_providers.dart';
import 'viewer_window.dart';

/// Mounts the open file-viewer windows over the whole app.
///
/// Placed as the top layer of a `Stack` at the app-shell level so a viewer
/// floats above the sidebar and content and persists across sidebar-tab
/// switches. Renders nothing (and intercepts no input) when no file is open —
/// the empty areas around a window fall through to the app beneath, so a
/// viewer is a non-modal floating tool, not a blocking overlay.
///
/// Window order in [openFileViewersProvider] is the paint/z-order: the last
/// entry is front-most.
class ViewerHost extends ConsumerWidget {
  const ViewerHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewers = ref.watch(openFileViewersProvider);
    if (viewers.isEmpty) return const SizedBox.shrink();

    final notifier = ref.read(openFileViewersProvider.notifier);
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounds = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            for (final v in viewers)
              FileViewerWindow(
                key: ValueKey(v.id),
                id: v.id,
                repoPath: v.repoPath,
                path: v.path,
                bounds: bounds,
                onClose: () => notifier.close(v.id),
                onFocus: () => notifier.focus(v.id),
              ),
          ],
        );
      },
    );
  }
}
