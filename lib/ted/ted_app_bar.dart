import 'package:flutter/material.dart';
import '../services/fullscreen_state_manager.dart';
import '../utils/desktop_window_padding.dart';

/// Shared Plezy window-control spacing for TED's ordinary routes. The player
/// uses its own full-screen header from PlexVideoControls.
class TedAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget title;
  final List<Widget>? actions;
  const TedAppBar({super.key, required this.title, this.actions});
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: FullscreenStateManager(),
    builder: (context, _) {
      final leading = Navigator.of(context).canPop() ? const BackButton() : null;
      return AppBar(
        automaticallyImplyLeading: false,
        leading: DesktopAppBarHelper.buildAdjustedLeading(leading, context: context),
        leadingWidth: DesktopAppBarHelper.calculateLeadingWidth(leading, context: context),
        title: leading == null ? DesktopTitleBarPadding(child: title) : title,
        actions: DesktopAppBarHelper.buildAdjustedActions(actions),
      );
    },
  );
}
