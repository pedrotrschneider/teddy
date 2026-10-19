import 'package:flutter/material.dart';
import 'dart:typed_data';
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

/// Bottom sidebar actions share Plezy's destination sizing and focus chrome.
class TedSidebarControls extends StatefulWidget {
  // The sidebar uses the desktop width in both desktop and TV layouts.
  static const collapsedContentWidth = NavigationRailLayout.collapsedWidth - 8;
  final String displayName;
  final Uint8List? profilePicture;
  final VoidCallback? onReload, onSettings, onSignOut, onSwitchProfile, onChangeServer;
  final bool compact, collapsed;
  final bool settingsSelected;
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
    this.settingsSelected = false,
    this.onAccountMenuChanged,
  });
  @override
  State<TedSidebarControls> createState() => _TedSidebarControlsState();
}

class _TedSidebarControlsState extends State<TedSidebarControls> {
  final _reload = FocusNode(debugLabel: 'ted_reload');
  final _settings = FocusNode(debugLabel: 'ted_settings');
  final _account = FocusNode(debugLabel: 'ted_account');
  @override
  void dispose() {
    _reload.dispose();
    _settings.dispose();
    _account.dispose();
    super.dispose();
  }

  Widget _action(String label, IconData icon, FocusNode node, VoidCallback? action) => Tooltip(
    message: label,
    child: Semantics(
      enabled: action != null,
      child: ExcludeFocus(
        excluding: action == null,
        child: Opacity(
          opacity: action == null ? .5 : 1,
          child: ClickableCursor(
            enabled: action != null,
            child: NavigationRailItem(
              icon: icon,
              label: Text(label),
              isSelected: node == _settings && widget.settingsSelected,
              mouseCursor: action != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
              isCollapsed: widget.compact || widget.collapsed,
              collapsedLabel: label,
              onTap: action ?? () {},
              focusNode: node,
              expandedContentWidth: 196,
              collapsedContentWidth: widget.compact ? null : TedSidebarControls.collapsedContentWidth,
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final children = [
      _action('Reload', Icons.refresh, _reload, widget.onReload),
      _action('Settings', Icons.settings_outlined, _settings, widget.onSettings),
      TedAccountMenu(
        displayName: widget.displayName,
        profilePicture: widget.profilePicture,
        focusNode: _account,
        onSignOut: widget.onSignOut,
        onSwitchProfile: widget.onSwitchProfile,
        onChangeServer: widget.onChangeServer,
        collapsed: widget.collapsed,
        onMenuChanged: widget.onAccountMenuChanged,
        collapsedContentWidth: widget.compact ? null : TedSidebarControls.collapsedContentWidth,
      ),
    ];
    return widget.compact
        ? Row(
            children: [
              children[0],
              children[1],
              Expanded(child: children[2]),
            ],
          )
        : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

enum _AccountAction { profiles, server, logout }

/// Account identity and sign out; Settings is a separate sidebar action.
class TedAccountMenu extends StatelessWidget {
  final String displayName;
  final Uint8List? profilePicture;
  final FocusNode focusNode;
  final VoidCallback? onSignOut, onSwitchProfile, onChangeServer;
  final bool collapsed;
  final double? collapsedContentWidth;
  final ValueChanged<bool>? onMenuChanged;
  const TedAccountMenu({
    super.key,
    required this.displayName,
    this.profilePicture,
    required this.focusNode,
    required this.onSignOut,
    this.onSwitchProfile,
    this.onChangeServer,
    this.collapsed = false,
    this.collapsedContentWidth,
    this.onMenuChanged,
  });

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    onMenuChanged?.call(true);
    _AccountAction? selected;
    try {
      selected = await showAppMenu<_AccountAction>(
        context,
        anchorRect: box.localToGlobal(Offset.zero) & box.size,
        focusFirstItem: true,
        entries: [
          AppMenuHeader(label: displayName),
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
