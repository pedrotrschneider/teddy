import 'package:flutter/material.dart';
import 'dart:typed_data';
import '../focus/card_focus_scope.dart';
import '../focus/focusable_wrapper.dart';
import '../utils/initials_palette.dart';
import 'ted_profiles.dart';
import 'ted_focus_region.dart';
import 'ted_profile_avatar.dart';

class TedProfileScreen extends StatelessWidget {
  final TedProfileSnapshot snapshot;
  final Map<String, Uint8List> pictures;
  final String? server, error;
  final bool busy;
  final ValueChanged<TedSavedProfile> onSelect;
  final ValueChanged<String?> onServer;
  final VoidCallback onAdd, onChangeServer;
  const TedProfileScreen({
    super.key,
    required this.snapshot,
    this.pictures = const {},
    required this.server,
    required this.busy,
    required this.error,
    required this.onSelect,
    required this.onServer,
    required this.onAdd,
    required this.onChangeServer,
  });
  @override
  Widget build(BuildContext context) {
    final profiles = snapshot.profiles.where((p) => !p.purging && (server == null || p.server == server)).toList();
    final servers = snapshot.profiles.where((p) => !p.purging).map((p) => p.server).toSet();
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        children: [
          SizedBox(height: 4, child: busy ? const LinearProgressIndicator() : null),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 600;
                final diameter = compact ? 104.0 : 144.0;
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: (constraints.maxHeight - 48).clamp(0, double.infinity)),
                    child: Center(
                      child: TedFocusRegion(
                        key: ValueKey((busy, server)),
                        autofocus: !busy,
                        grid: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Who’s watching?',
                              textAlign: TextAlign.center,
                              style: (compact ? theme.textTheme.headlineMedium : theme.textTheme.headlineLarge)
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 24),
                                child: Semantics(liveRegion: true, child: Text(error!, textAlign: TextAlign.center)),
                              ),
                            SizedBox(height: compact ? 32 : 48),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: compact ? 20 : 32,
                              runSpacing: 24,
                              children: [
                                for (final profile in profiles)
                                  _ProfileChoice(
                                    key: ValueKey(profile.key),
                                    label: profile.name,
                                    diameter: diameter,
                                    color: colorForName(profile.name, theme),
                                    onSelect: busy ? null : () => onSelect(profile),
                                    child: TedProfileAvatar(
                                      name: profile.name,
                                      image: pictures[profile.scope],
                                      diameter: diameter - 8,
                                    ),
                                  ),
                                _ProfileChoice(
                                  label: 'Add profile',
                                  diameter: diameter,
                                  color: theme.colorScheme.surfaceContainerHighest,
                                  onSelect: busy ? null : onAdd,
                                  child: Icon(
                                    Icons.add_rounded,
                                    size: diameter * .45,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 36),
                            if (servers.length > 1)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: SizedBox(
                                  width: 360,
                                  child: DropdownButtonFormField<String>(
                                    initialValue: servers.contains(server) ? server : null,
                                    isExpanded: true,
                                    decoration: const InputDecoration(labelText: 'Saved server'),
                                    items: servers
                                        .map(
                                          (s) => DropdownMenuItem(
                                            value: s,
                                            child: Text(s, overflow: TextOverflow.ellipsis),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: busy ? null : onServer,
                                  ),
                                ),
                              ),
                            TextButton(onPressed: busy ? null : onChangeServer, child: const Text('Change server')),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileChoice extends StatefulWidget {
  final String label;
  final double diameter;
  final Color color;
  final Widget child;
  final VoidCallback? onSelect;
  const _ProfileChoice({
    super.key,
    required this.label,
    required this.diameter,
    required this.color,
    required this.child,
    this.onSelect,
  });

  @override
  State<_ProfileChoice> createState() => _ProfileChoiceState();
}

class _ProfileChoiceState extends State<_ProfileChoice> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => FocusableWrapper(
    semanticLabel: widget.label,
    onSelect: widget.onSelect,
    canRequestFocus: widget.onSelect != null,
    autoScroll: false, // The containing region reveals the whole tile, including its name.
    delegateFocusBorder: true,
    child: MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: SizedBox(
          width: widget.diameter + 24,
          child: Column(
            children: [
              Builder(
                builder: (context) {
                  final focused = CardFocusScope.maybeOf(context) == true;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: widget.diameter,
                    height: widget.diameter,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color,
                      border: Border.all(
                        color: focused
                            ? Colors.white
                            : Theme.of(context).colorScheme.onSurface.withValues(
                                alpha: _hovered && widget.onSelect != null ? .65 : .18,
                              ),
                        width: focused ? 3 : 1.5,
                      ),
                    ),
                    child: Center(child: widget.child),
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(
                widget.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
