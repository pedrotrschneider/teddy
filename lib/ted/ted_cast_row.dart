import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../utils/platform_detector.dart';
import '../utils/media_image_helper.dart';
import '../utils/layout_constants.dart';
import '../widgets/cast_member_strip.dart';
import '../focus/input_mode_tracker.dart';
import '../widgets/app_icon.dart';
import 'ted_client.dart';
import 'ted_metadata_models.dart';

/// Plezy's cast presentation with TED-owned private portrait delivery. The
/// parent banner remains the only title-metadata poller.
class TedCastRow extends StatefulWidget {
  final TedClient client;
  final List<TedMetadataPerson> people;
  final bool loading;
  final double horizontalInset;
  final VoidCallback onUp, onLeft, onBack;
  final ValueChanged<bool> onFocusChanged;
  final ValueChanged<TedMetadataPerson>? onPerson;
  const TedCastRow({
    super.key,
    required this.client,
    required this.people,
    required this.loading,
    required this.horizontalInset,
    required this.onUp,
    required this.onLeft,
    required this.onBack,
    required this.onFocusChanged,
    this.onPerson,
  });
  @override
  State<TedCastRow> createState() => TedCastRowState();
}

class TedCastRowState extends State<TedCastRow> {
  final _strip = GlobalKey<CastMemberStripState>();
  final _section = GlobalKey();
  late _Portraits _portraits = _Portraits(widget.client);
  List<TedMetadataPerson> get _cast => widget.people.where((person) => person.type == 'Actor').toList();
  bool requestFocus() {
    if (_cast.isEmpty) return false;
    _strip.currentState?.requestFocus();
    return _strip.currentState != null;
  }

  @override
  void didUpdateWidget(TedCastRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client || !_portraits.valid) {
      _portraits.dispose();
      _portraits = _Portraits(widget.client);
    }
  }

  @override
  void dispose() {
    _portraits.dispose();
    super.dispose();
  }

  void _focusChanged(bool focused) {
    widget.onFocusChanged(focused);
    if (!focused || InputModeTracker.currentMode != InputMode.keyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final section = _section.currentContext;
      if (!mounted || InputModeTracker.currentMode != InputMode.keyboard || section == null) return;
      // Reveal the entire cast lane, rather than the strip's inner viewport.
      Scrollable.ensureVisible(section, alignment: 1, duration: const Duration(milliseconds: 200));
    });
  }

  @override
  Widget build(BuildContext context) {
    final cast = _cast;
    if (cast.isEmpty && !widget.loading) return const SizedBox.shrink();
    return Padding(
      key: _section,
      padding: const EdgeInsets.only(
        top: 24 * ContentLayoutConstants.rowGapScale,
        bottom: 16 * ContentLayoutConstants.rowGapScale,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset),
            child: Row(
              children: [
                AppIcon(Icons.people_rounded, fill: 1, size: PlatformDetector.isTV() ? 28 : null),
                SizedBox(width: PlatformDetector.isTV() ? 12 : 8),
                Text(
                  'Cast',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: PlatformDetector.isTV() ? 28 : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (cast.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.horizontalInset),
              child: const Row(
                children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Loading cast…'),
                ],
              ),
            )
          else
            Padding(
              // Preserve Plezy's three-pixel card inset and align portraits
              // with this screen's action controls and section heading.
              padding: EdgeInsets.symmetric(horizontal: (widget.horizontalInset - 3).clamp(0, double.infinity)),
              child: CastMemberStrip(
                key: _strip,
                debugLabel: 'ted_cast_row',
                imageAspectRatio: 2 / 3,
                members: [
                  for (final person in cast)
                    (name: person.name, secondary: person.role.isEmpty ? null : person.role, imagePath: null),
                ],
                imageBuilder: (context, index, size) => _Portrait(
                  key: ValueKey((cast[index].id, cast[index].imageTag)),
                  portraits: _portraits,
                  person: cast[index],
                  size: size,
                ),
                onNavigateUp: widget.onUp,
                onNavigateLeft: widget.onLeft,
                onBack: widget.onBack,
                onFocusChanged: _focusChanged,
                onMemberTap: widget.onPerson == null ? null : (index) => widget.onPerson!(cast[index]),
              ),
            ),
        ],
      ),
    );
  }
}

typedef _PortraitKey = (String, String?);

/// Realized cards only; coalesced, bounded work and an account-scoped memory
/// cache. Neither URLs nor bearer tokens enter Plezy's public disk cache.
class _Portraits {
  final TedClient client;
  final (Uri?, int?) _scope;
  final _queue = Queue<TedMetadataPerson>();
  final _pending = <_PortraitKey, Completer<Uint8List?>>{};
  final _cache = <_PortraitKey, Uint8List?>{};
  int _active = 0, _bytes = 0;
  bool _disposed = false;
  _Portraits(this.client) : _scope = (client.auth.server, client.auth.userId);
  bool get valid => !_disposed && _scope == (client.auth.server, client.auth.userId);

  Future<Uint8List?> load(TedMetadataPerson person) {
    // PrimaryImageTag is a downloaded-image digest, not an availability flag.
    // An untagged seeded portrait still needs its first artwork request; a
    // person without provider artwork returns 404 and keeps the placeholder.
    if (!valid) return Future.value();
    final key = (person.id, person.imageTag);
    if (_cache.containsKey(key)) {
      final bytes = _cache.remove(key);
      _cache[key] = bytes;
      return Future.value(bytes);
    }
    if (_pending.containsKey(key)) return _pending[key]!.future;
    final completion = Completer<Uint8List?>();
    _pending[key] = completion;
    _queue.add(person);
    _pump();
    return completion.future;
  }

  void _pump() {
    while (valid && _active < 5 && _queue.isNotEmpty) {
      _active++;
      unawaited(_run(_queue.removeFirst()));
    }
  }

  Future<void> _run(TedMetadataPerson person) async {
    Uint8List? bytes;
    final key = (person.id, person.imageTag);
    try {
      for (var attempt = 0; valid && attempt < 12; attempt++) {
        bytes = await client.personPortrait(person.id);
        if (bytes != null || !valid) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } catch (_) {
      // Missing/failed portraits retain the standard person placeholder.
      // An artwork failure cannot erase a credit or request a biography.
    } finally {
      if (valid) {
        _cache[key] = bytes;
        _bytes += bytes?.length ?? 0;
        while (_cache.length > 64 || _bytes > (20 << 20)) {
          _bytes -= _cache.remove(_cache.keys.first)?.length ?? 0;
        }
      }
      _pending.remove(key)?.complete(valid ? bytes : null);
      _active--;
      _pump();
    }
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
    _cache.clear();
    _bytes = 0;
    for (final pending in _pending.values) {
      pending.complete(null);
    }
    _pending.clear();
  }
}

class _Portrait extends StatefulWidget {
  final _Portraits portraits;
  final TedMetadataPerson person;
  final double size;
  const _Portrait({super.key, required this.portraits, required this.person, required this.size});
  @override
  State<_Portrait> createState() => _PortraitState();
}

class _PortraitState extends State<_Portrait> {
  late Future<Uint8List?> _bytes = widget.portraits.load(widget.person);
  @override
  void didUpdateWidget(_Portrait oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.portraits != widget.portraits ||
        oldWidget.person.id != widget.person.id ||
        oldWidget.person.imageTag != widget.person.imageTag) {
      _bytes = widget.portraits.load(widget.person);
    }
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: const Center(child: Icon(Icons.person, size: 48)),
    );
    final decodeSize = (widget.size * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 2048);
    return SizedBox(
      width: widget.size,
      height: widget.size * 1.5,
      child: FutureBuilder<Uint8List?>(
        future: _bytes,
        builder: (context, snapshot) => snapshot.data == null || !widget.portraits.valid
            ? placeholder
            : Image(
                image: MediaImageHelper.boundedDecode(
                  MemoryImage(snapshot.data!),
                  memWidth: decodeSize,
                  memHeight: (decodeSize * 1.5).ceil(),
                ),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}
