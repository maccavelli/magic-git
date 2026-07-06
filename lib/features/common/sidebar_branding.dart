import 'package:flutter/widgets.dart';

/// MG logo centered at the top of the navigation sidebar.
class SidebarBranding extends StatelessWidget {
  const SidebarBranding({super.key});

  static const _asset = 'assets/MG-icon.png';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            _asset,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}