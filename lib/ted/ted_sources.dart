import 'package:flutter/material.dart';
import '../focus/dpad_navigator.dart';
import '../focus/input_mode_tracker.dart';
import 'ted_source_models.dart';
import 'ted_client.dart';
import 'ted_models.dart';
import 'ted_app_bar.dart';
import 'ted_focus_region.dart';

class TedAddonsScreen extends StatefulWidget {
  final TedClient client;
  const TedAddonsScreen({super.key, required this.client});
  @override
  State<TedAddonsScreen> createState() => _TedAddonsScreenState();
}

class _TedAddonsScreenState extends State<TedAddonsScreen> {
  late Future<TedAddonCollection> _collection = widget.client.addons();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: TedAppBar(
      title: const Text('Installed add-ons'),
      actions: [
        IconButton(
          tooltip: 'Refresh installed add-ons',
          onPressed: () => setState(() {
            _collection = widget.client.addons(refresh: true);
          }),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<TedAddonCollection>(
      future: _collection,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final data = snapshot.data;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'An administrator manages the server add-on account on TED’s web interface at ${widget.client.auth.server}. Then refresh here after installing or changing add-ons in Stremio.',
            ),
            const SizedBox(height: 16),
            if (snapshot.hasError)
              Text(
                snapshot.error is TedFailure
                    ? (snapshot.error as TedFailure).message
                    : const TedFailure('unavailable').message,
              ),
            if (data != null) ...[
              if (data.cached) const Text('Using saved add-ons while Stremio is unavailable.'),
              if (data.addons.isEmpty) const Text('No installed add-ons.'),
              for (final addon in data.addons)
                ListTile(
                  title: Text(addon.name),
                  subtitle: Text(
                    !addon.enabled
                        ? 'Disabled by the TED administrator'
                        : addon.supported
                        ? [if (addon.movie) 'Movies', if (addon.episode) 'Episodes'].join(' · ')
                        : 'No supported movie or episode stream resource',
                  ),
                ),
            ],
          ],
        );
      },
    ),
  );
}

Future<String?> chooseTedSource(
  BuildContext context,
  TedSourcePage page, {
  TedClient? client,
  ValueChanged<TedSourcePage>? onChanged,
  Future<TedSourcePage> Function()? onReload,
}) => showDialog<String>(
  context: context,
  builder: (_) => TedSourcePicker(page: page, client: client, onChanged: onChanged, onReload: onReload),
);

class TedSourcePickerAction {
  final String value, label;
  const TedSourcePickerAction(this.value, this.label);
}

/// Shared source cards for playback and the sequential bulk-download picker.
class TedSourcePicker extends StatefulWidget {
  final TedSourcePage page;
  final TedClient? client;
  final ValueChanged<TedSourcePage>? onChanged;
  final ValueChanged<String>? onSelected;
  final VoidCallback? onCancel;
  final Widget? title;
  final bool includeMapped;
  final Future<TedSourcePage> Function()? onReload;
  final List<TedSourcePickerAction> actions;
  const TedSourcePicker({
    super.key,
    required this.page,
    this.client,
    this.onChanged,
    this.onSelected,
    this.onCancel,
    this.title,
    this.includeMapped = false,
    this.onReload,
    this.actions = const [],
  });
  @override
  State<TedSourcePicker> createState() => _TedSourcePickerState();
}

class _TedSourcePickerState extends State<TedSourcePicker> {
  late TedSourcePage _page = widget.page;
  late String _addon = widget.includeMapped
      ? ''
      : _page.choices.any((c) => c.favorite)
      ? 'favorites'
      : _page.choices.any((c) => c.recentRank > 0)
      ? 'recent'
      : '';
  final _addonNames = <String, String>{};
  final _region = GlobalKey<TedFocusRegionState>();
  final _filterFocus = FocusNode();
  final _cancelFocus = FocusNode();
  final _reloadFocus = FocusNode();
  final _actionFocus = <String, FocusNode>{};
  final _sourceFocus = <String, FocusNode>{};
  final _starFocus = <String, FocusNode>{};
  List<TedSourceChoice> _visible = [];
  String? _busy;
  String? _error;
  List<FocusNode> get _footer => [
    if (widget.onReload != null) _reloadFocus,
    for (final action in widget.actions) _actionFocus.putIfAbsent(action.value, () => FocusNode()),
    _cancelFocus,
  ];
  void _cancel() => widget.onCancel != null ? widget.onCancel!() : Navigator.of(context).pop();
  void _select(String value) =>
      widget.onSelected != null ? widget.onSelected!(value) : Navigator.of(context).pop(value);

  KeyEventResult _navigate(FocusNode _, KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent == false || !event.isActionable) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (!key.isDpadDirection) return KeyEventResult.ignored;
    final current = FocusManager.instance.primaryFocus;
    FocusNode? target;
    if (current == _filterFocus) {
      if (key.isDownKey) target = _visible.isEmpty ? _footer.first : _sourceFocus[_visible.first.id];
    } else if (_footer.contains(current)) {
      if (key.isUpKey) target = _visible.isEmpty ? _filterFocus : _sourceFocus[_visible.last.id];
      final index = _footer.indexOf(current!);
      if (key.isLeftKey && index > 0) target = _footer[index - 1];
      if (key.isRightKey && index + 1 < _footer.length) target = _footer[index + 1];
    } else {
      final index = _visible.indexWhere((c) => current == _sourceFocus[c.id] || current == _starFocus[c.id]);
      if (index < 0) return KeyEventResult.ignored;
      final choice = _visible[index];
      final star = current == _starFocus[choice.id];
      if (key.isUpKey || key.isDownKey) {
        final next = index + (key.isUpKey ? -1 : 1);
        if (next < 0) {
          target = _filterFocus;
        } else if (next >= _visible.length) {
          target = _footer.first;
        } else {
          final c = _visible[next];
          target = star && c.favoriteKey.isNotEmpty && widget.client != null ? _starFocus[c.id] : _sourceFocus[c.id];
        }
      } else if (key.isLeftKey && star) {
        target = _sourceFocus[choice.id];
      } else if (key.isRightKey && !star && choice.favoriteKey.isNotEmpty && widget.client != null) {
        target = _starFocus[choice.id];
      }
    }
    target?.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _filterFocus.dispose();
    _cancelFocus.dispose();
    _reloadFocus.dispose();
    for (final node in _actionFocus.values) {
      node.dispose();
    }
    for (final node in [..._sourceFocus.values, ..._starFocus.values]) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _favorite(TedSourceChoice choice) async {
    if (_busy != null || widget.client == null) return;
    setState(() {
      _busy = choice.id;
      _error = null;
    });
    try {
      final key = await widget.client!.setSourceFavorite(choice.id, !choice.favorite);
      final updated = _page.withChoices([
        for (final c in _page.choices) c.favoriteKey == key ? c.withFavorite(!choice.favorite) : c,
      ]);
      widget.onChanged?.call(updated);
      if (mounted) {
        setState(() => _page = updated);
        // Reordering retains the selected star, so no focus-change callback
        // fires. Reveal its new position after the list has laid it out.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final focus = FocusManager.instance.primaryFocus;
          if (mounted &&
              InputModeTracker.currentMode == InputMode.keyboard &&
              _region.currentState?.hasFocus == true &&
              focus?.context != null) {
            Scrollable.ensureVisible(
              focus!.context!,
              alignment: .25,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
            );
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is TedFailure ? e.message : const TedFailure('unavailable').message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  int _category(TedSourceChoice c) => c.id == 'mapped'
      ? -1
      : c.favorite
      ? 0
      : c.recentRank > 0
      ? 1
      : 2;
  @override
  Widget build(BuildContext context) {
    final page = _page;
    _addonNames.addAll(<String, String>{
      for (final addon in page.addons.where((a) => a.enabled)) addon.id: addon.name,
      for (final choice in page.choices) choice.addonId.isEmpty ? choice.addon : choice.addonId: choice.addon,
    });
    final addons = _addonNames;
    final allChoices = [
      if (widget.includeMapped && page.mapped && page.ready)
        TedSourceChoice('mapped', 'TED', 'RD mapped source', page.mappedFileName),
      ...page.choices,
    ];
    final choices = allChoices
        .where(
          (c) => switch (_addon) {
            '' => true,
            'favorites' => c.favorite,
            'recent' => c.recentRank > 0,
            'mapped' => c.id == 'mapped',
            _ => (c.addonId.isEmpty ? c.addon : c.addonId) == _addon,
          },
        )
        .toList();
    // The server already deduplicates fresh account-owned streams. Keep the
    // same section ordering after a star is changed without a network refetch.
    choices.sort((a, b) {
      final kind = _category(a).compareTo(_category(b));
      if (kind != 0) return kind;
      if (_category(a) == 1) return a.recentRank.compareTo(b.recentRank);
      return allChoices.indexOf(a).compareTo(allChoices.indexOf(b));
    });
    _visible = choices;
    final colors = Theme.of(context).colorScheme;
    return TedFocusRegion(
      key: _region,
      grid: true,
      scroll: false,
      autofocus: true,
      onBack: _cancel,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _navigate,
        child: AlertDialog(
          backgroundColor: colors.surface,
          surfaceTintColor: Colors.transparent,
          title: widget.title ?? const Text('Choose a source'),
          content: SizedBox(
            width: 780,
            height: MediaQuery.sizeOf(context).height * .65,
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey('source-addon-filter'),
                  focusNode: _filterFocus,
                  initialValue: _addon,
                  decoration: const InputDecoration(labelText: 'Sources'),
                  items: [
                    if (page.choices.any((c) => c.favorite) || _addon == 'favorites')
                      DropdownMenuItem(
                        value: 'favorites',
                        child: _categoryLabel(Icons.star, 'Favorites', _accent(colors, 0)),
                      ),
                    if (page.choices.any((c) => c.recentRank > 0) || _addon == 'recent')
                      DropdownMenuItem(
                        value: 'recent',
                        child: _categoryLabel(Icons.history, 'Recent', _accent(colors, 1)),
                      ),
                    const DropdownMenuItem(value: '', child: Text('All')),
                    if (widget.includeMapped && (page.mapped && page.ready || _addon == 'mapped'))
                      const DropdownMenuItem(value: 'mapped', child: Text('RD mapped')),
                    for (final addon in addons.entries) DropdownMenuItem(value: addon.key, child: Text(addon.value)),
                  ],
                  onChanged: (value) => setState(() => _addon = value ?? ''),
                ),
                const SizedBox(height: 16),
                if (widget.includeMapped && page.mapped && !page.ready)
                  const Text('The RD mapping is not ready. You can choose an add-on source or skip this episode.'),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: colors.error)),
                  ),
                Expanded(
                  // The server bounds this text-only list to 200 sources. Lay
                  // out all controls so reordered or offscreen keyboard targets
                  // retain valid geometry instead of sliver keep-alive offsets.
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_addon.isNotEmpty)
                          for (final issue in page.addonIssues.where((issue) => issue.addonId == _addon))
                            Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(issue.message)),
                        if (choices.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(page.emptyMessage)),
                        for (var i = 0; i < choices.length; i++) ...[
                          if (_addon.isEmpty && (i == 0 || _category(choices[i - 1]) != _category(choices[i])))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                children: [
                                  Text(
                                    _category(choices[i]) < 0
                                        ? 'RD mapped'
                                        : ['Favorites', 'Recent', 'Other sources'][_category(choices[i])],
                                    style: TextStyle(color: _accent(colors, _category(choices[i]))),
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(child: Divider()),
                                ],
                              ),
                            ),
                          _card(context, choices[i], colors),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (widget.onReload != null)
              TextButton.icon(
                focusNode: _reloadFocus,
                icon: const Icon(Icons.refresh),
                label: const Text('Reload'),
                onPressed: _busy != null
                    ? null
                    : () async {
                        setState(() {
                          _busy = 'reload';
                          _error = null;
                        });
                        try {
                          final page = await widget.onReload!();
                          if (mounted) {
                            setState(() => _page = page);
                            widget.onChanged?.call(page);
                          }
                        } catch (e) {
                          if (mounted) {
                            setState(
                              () => _error = e is TedFailure ? e.message : const TedFailure('unavailable').message,
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _busy = null);
                        }
                      },
              ),
            for (final action in widget.actions)
              TextButton(
                focusNode: _actionFocus.putIfAbsent(action.value, () => FocusNode()),
                onPressed: () => _select(action.value),
                child: Text(action.label),
              ),
            TextButton(focusNode: _cancelFocus, onPressed: _cancel, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }

  Color? _accent(ColorScheme colors, int category) => switch (category) {
    0 => colors.brightness == Brightness.dark ? const Color(0xffe6c46a) : const Color(0xff8f6500),
    1 => colors.brightness == Brightness.dark ? const Color(0xff8bdce8) : const Color(0xff006b7a),
    _ => null,
  };

  Widget _categoryLabel(IconData icon, String label, Color? color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 8),
      Text(label, style: TextStyle(color: color)),
    ],
  );

  Widget _card(BuildContext context, TedSourceChoice choice, ColorScheme colors) => Padding(
    key: ValueKey('source-card-${choice.id}'),
    padding: const EdgeInsets.only(bottom: 12),
    child: Builder(
      builder: (cardContext) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (!focused || InputModeTracker.currentMode != InputMode.keyboard) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (cardContext.mounted && InputModeTracker.currentMode == InputMode.keyboard) {
              Scrollable.ensureVisible(
                cardContext,
                alignment: .25,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
              );
            }
          });
        },
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: ValueKey('source-${choice.id}'),
                focusNode: _sourceFocus.putIfAbsent(choice.id, () => FocusNode()),
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (states) => Color.alphaBlend(
                      colors.onSurface.withValues(
                        alpha: states.contains(WidgetState.focused)
                            ? .16
                            : states.contains(WidgetState.hovered)
                            ? .12
                            : .08,
                      ),
                      colors.surface,
                    ),
                  ),
                  foregroundColor: WidgetStatePropertyAll(colors.onSurface),
                  overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                  alignment: Alignment.centerLeft,
                  padding: const WidgetStatePropertyAll(EdgeInsets.all(20)),
                  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  side: WidgetStateProperty.resolveWith(
                    (states) => BorderSide(
                      color:
                          _accent(colors, _category(choice)) ??
                          colors.onSurface.withValues(alpha: states.contains(WidgetState.focused) ? .8 : .25),
                      width: states.contains(WidgetState.focused) ? 2 : 1,
                    ),
                  ),
                ),
                onPressed: () => _select(choice.id),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            choice.name,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: _accent(colors, _category(choice)),
                            ),
                          ),
                        ),
                        if (choice.rdDirectPlay || choice.inRDAccount) ...[
                          const SizedBox(width: 12),
                          Container(
                            key: ValueKey('rd-badge-${choice.id}'),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              color: choice.inRDAccount ? null : const Color(0xff287847),
                              gradient: choice.inRDAccount
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xffff9fa0),
                                        Color(0xffffda96),
                                        Color(0xffb2e8ad),
                                        Color(0xff8edbe8),
                                        Color(0xffc5b0ee),
                                      ],
                                    )
                                  : null,
                            ),
                            child: Text(
                              choice.inRDAccount ? 'In RD Account' : 'RD Direct Play',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: choice.inRDAccount ? const Color(0xff202124) : Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(choice.addon, style: Theme.of(context).textTheme.labelLarge),
                    if (choice.description.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        choice.description,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (choice.favoriteKey.isNotEmpty && widget.client != null)
              IconButton(
                key: ValueKey('favorite-${choice.id}'),
                focusNode: _starFocus.putIfAbsent(choice.id, () => FocusNode()),
                tooltip: choice.favorite ? 'Remove favorite' : 'Favorite source',
                color: _accent(colors, _category(choice)),
                // Keep the star focusable while its idempotent write is pending.
                // _favorite serializes writes; disabling this button loses TV focus.
                onPressed: () => _favorite(choice),
                icon: _busy == choice.id
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(choice.favorite ? Icons.star : Icons.star_border),
              ),
          ],
        ),
      ),
    ),
  );
}
