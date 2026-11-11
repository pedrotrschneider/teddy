import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'ted_profile_avatar.dart';
import '../widgets/app_menu.dart';
import '../widgets/navigation_rail_item.dart';
import '../widgets/clickable_cursor.dart';

/// Artwork remains at the top edge; chrome no longer owns controls here.
class TedBrowseHeader extends StatelessWidget {
  const TedBrowseHeader({super.key});
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox(
      width: double.infinity,
      height: MediaQuery.paddingOf(context).top + 112,
      child: const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x99000000), Color(0x4D000000), Colors.transparent],
            stops: [0, .55, 1],
          ),
        ),
      ),
    ),
  );
}

/// The profile is the final control in both navigation layouts.
class TedSidebarControls extends StatefulWidget {
  // The sidebar uses the desktop width in both desktop and TV layouts.
  static const collapsedContentWidth = NavigationRailLayout.collapsedWidth - 8;
  final String displayName;
  final Uint8List? profilePicture;
  final VoidCallback? onReload, onSettings, onSignOut, onSwitchProfile, onChangeServer;
  final bool compact, collapsed;
  final ValueChanged<bool>? onAccountMenuChanged;
  const TedSidebarControls({
    super.key,
    required this.displayName,
    this.profilePicture,
    this.onReload,
    this.onSettings,
    this.onSignOut,
    this.onSwitchProfile,
    this.onChangeServer,
    this.compact = false,
    this.collapsed = false,
    this.onAccountMenuChanged,
  });
  @override
  State<TedSidebarControls> createState() => _TedSidebarControlsState();
}

class _TedSidebarControlsState extends State<TedSidebarControls> {
  final _account = FocusNode(debugLabel: 'ted_account');

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TedAccountMenu(
    displayName: widget.displayName,
    profilePicture: widget.profilePicture,
    focusNode: _account,
    onReload: widget.onReload,
    onSettings: widget.onSettings,
    onSignOut: widget.onSignOut,
    onSwitchProfile: widget.onSwitchProfile,
    onChangeServer: widget.onChangeServer,
    compact: widget.compact,
    collapsed: widget.compact || widget.collapsed,
    onMenuChanged: widget.onAccountMenuChanged,
    collapsedContentWidth: widget.compact ? null : TedSidebarControls.collapsedContentWidth,
  );
}

enum _AccountAction { reload, settings, profiles, server, logout }

class TedAccountMenu extends StatelessWidget {
  final String displayName;
  final Uint8List? profilePicture;
  final FocusNode focusNode;
  final VoidCallback? onReload, onSettings, onSignOut, onSwitchProfile, onChangeServer;
  final bool compact, collapsed;
  final double? collapsedContentWidth;
  final ValueChanged<bool>? onMenuChanged;
  const TedAccountMenu({
    super.key,
    required this.displayName,
    this.profilePicture,
    required this.focusNode,
    this.onReload,
    this.onSettings,
    required this.onSignOut,
    this.onSwitchProfile,
    this.onChangeServer,
    this.compact = false,
    this.collapsed = false,
    this.collapsedContentWidth,
    this.onMenuChanged,
  });

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Navigator.of(context, rootNavigator: true).overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    // The popup is laid out in the navigator's logical coordinates at every UI scale.
    final anchor = MatrixUtils.transformRect(box.getTransformTo(overlay), Offset.zero & box.size);
    onMenuChanged?.call(true);
    _AccountAction? selected;
    try {
      selected = await showAppMenu<_AccountAction>(
        context,
        anchorRect: anchor,
        anchorAlignment: compact ? AppMenuAnchorAlignment.end : AppMenuAnchorAlignment.start,
        openAbove: true,
        focusFirstItem: true,
        entries: [
          AppMenuHeader(label: displayName),
          AppMenuItem(value: _AccountAction.reload, label: 'Reload', icon: Icons.refresh, enabled: onReload != null),
          AppMenuItem(
            value: _AccountAction.settings,
            label: 'Settings',
            icon: Icons.settings_outlined,
            enabled: onSettings != null,
          ),
          const AppMenuDivider(),
          AppMenuItem(
            value: _AccountAction.profiles,
            label: 'Switch Profile',
            icon: Icons.people,
            enabled: onSwitchProfile != null,
          ),
          AppMenuItem(
            value: _AccountAction.server,
            label: 'Change server',
            icon: Icons.dns,
            enabled: onChangeServer != null,
          ),
          AppMenuItem(value: _AccountAction.logout, label: 'Sign out', icon: Icons.logout, enabled: onSignOut != null),
        ],
      );
    } finally {
      if (context.mounted) onMenuChanged?.call(false);
    }
    if (!context.mounted) return;
    focusNode.requestFocus();
    if (selected == _AccountAction.reload) onReload?.call();
    if (selected == _AccountAction.settings) onSettings?.call();
    if (selected == _AccountAction.profiles) onSwitchProfile?.call();
    if (selected == _AccountAction.server) onChangeServer?.call();
    if (selected == _AccountAction.logout) onSignOut?.call();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Profile: $displayName',
    child: ClickableCursor(
      child: NavigationRailItem(
        icon: Icons.person_outline,
        iconWidget: TedProfileAvatar(name: displayName, image: profilePicture, diameter: 32),
        iconSize: 32,
        label: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
        isSelected: false,
        mouseCursor: SystemMouseCursors.click,
        isCollapsed: collapsed,
        collapsedLabel: displayName,
        onTap: () => _open(context),
        focusNode: focusNode,
        expandedContentWidth: 196,
        collapsedContentWidth: collapsedContentWidth,
      ),
    ),
  );
}
