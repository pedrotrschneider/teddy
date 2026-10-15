import 'dart:async';
import 'package:flutter/material.dart';
import 'ted_client.dart';
import 'ted_models.dart';

typedef TedPlay = Future<void> Function(TedTitle title);

/// TED discovery and personal rows. Requests stay in TedClient; this screen
/// never uses provider URLs, creates mappings or derives episode ordering.
class TedCatalogScreen extends StatefulWidget {
  final TedClient client;
  final TedPlay onPlay;
  const TedCatalogScreen({super.key, required this.client, required this.onPlay});
  @override
  State<TedCatalogScreen> createState() => _TedCatalogScreenState();
}

class _TedCatalogScreenState extends State<TedCatalogScreen> {
  final _search = TextEditingController();
  String _section = 'home', _query = '', _catalog = 'popular';
  bool _busy = true;
  String? _error, _after;
  int? _skip;
  List<TedTitle> _titles = [];
  List<TedHomeRow> _home = [];
  List<TedCatalogIssue> _issues = [];
  @override
  void initState() {
    super.initState();
    unawaited(_work(() => _load()));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _work(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on TedFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = const TedFailure('unavailable').message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load({bool more = false}) async {
    List<TedTitle> titles = [];
    List<TedHomeRow> home = _home;
    List<TedCatalogIssue> issues = [];
    String? after;
    int? skip;
    switch (_section) {
      case 'home':
        home = await widget.client.home();
      case 'mapped':
        final page = await widget.client.mappedTitles(after: more ? _after : null);
        titles = page.titles;
        after = page.nextAfter;
      case 'continue-watching' || 'next-up':
        final page = await widget.client.personal(_section, after: more ? _after : null);
        titles = page.titles;
        after = page.nextAfter;
        issues = page.issues;
      case 'search':
        final results = await Future.wait([
          widget.client.browse('movie', search: _query),
          widget.client.browse('series', search: _query),
        ]);
        titles = results.expand((p) => p.titles).toList();
      default:
        final page = await widget.client.browse(_section, skip: more ? _skip! : 0, catalog: _catalog);
        titles = page.titles;
        skip = page.nextSkip;
    }
    if (!mounted) return;
    setState(() {
      _home = home;
      _titles = more
          ? {
              for (final title in [..._titles, ...titles]) title.media: title,
            }.values.toList()
          : titles;
      _issues = more ? [..._issues, ...issues] : issues;
      _after = after;
      _skip = skip;
    });
  }

  void _select(String section) {
    if (_busy) return;
    setState(() {
      _section = section;
      _titles = [];
      _issues = [];
      _after = null;
      _skip = null;
    });
    unawaited(_work(() => _load()));
  }

  Future<void> _detail(TedTitle title) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TedTitleScreen(client: widget.client, initial: title, onPlay: widget.onPlay),
      ),
    );
    if (mounted) await _work(() => _load());
  }

  Widget _grid(List<TedTitle> titles) => LayoutBuilder(
    builder: (context, constraints) {
      final count = (constraints.maxWidth / 170).floor().clamp(2, 8);
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: count, mainAxisExtent: 290),
        itemCount: titles.length,
        itemBuilder: (context, i) => _TedPoster(title: titles[i], onTap: _busy ? null : () => _detail(titles[i])),
      );
    },
  );
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _search,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: 'Search movies and shows',
            suffixIcon: IconButton(
              tooltip: 'Search',
              onPressed: _busy
                  ? null
                  : () {
                      _query = _search.text.trim();
                      if (_query.isNotEmpty) _select('search');
                    },
              icon: const Icon(Icons.search),
            ),
          ),
          onSubmitted: (value) {
            _query = value.trim();
            if (_query.isNotEmpty) _select('search');
          },
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final entry in const {'home': 'Home', 'movie': 'Movies', 'series': 'Shows', 'mapped': 'Mapped'}.entries)
            ChoiceChip(
              label: Text(entry.value),
              selected: _section == entry.key,
              onSelected: _busy ? null : (_) => _select(entry.key),
            ),
          if (_section == 'movie' || _section == 'series')
            DropdownButton<String>(
              value: _catalog,
              items: const [
                DropdownMenuItem(value: 'popular', child: Text('Popular')),
                DropdownMenuItem(value: 'featured', child: Text('Highly rated')),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _catalog = value);
                        unawaited(_work(() => _load()));
                      }
                    },
            ),
        ],
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null) _TedNotice(_error!, retry: _busy ? null : () => _work(() => _load())),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (_section == 'home')
              for (final row in _home) ...[
                Row(
                  children: [
                    Expanded(child: Text(_rowName(row.id), style: Theme.of(context).textTheme.titleLarge)),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _select(switch (row.id) {
                              'popular-movie' => 'movie',
                              'popular-series' => 'series',
                              _ => row.id,
                            }),
                      child: const Text('See all'),
                    ),
                  ],
                ),
                for (final issue in row.issues)
                  _TedNotice(issue.message, retry: _busy ? null : () => _work(() => _load())),
                if (row.titles.isEmpty && !row.unavailable && row.issues.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(switch (row.id) {
                      'continue-watching' => 'No unfinished playback.',
                      'next-up' => 'No released episodes waiting.',
                      _ => 'No titles returned.',
                    }),
                  ),
                if (row.titles.isNotEmpty)
                  SizedBox(
                    height: 290,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: row.titles.length,
                      itemBuilder: (_, i) => SizedBox(
                        width: 170,
                        child: _TedPoster(title: row.titles[i], onTap: _busy ? null : () => _detail(row.titles[i])),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
              ]
            else ...[
              Text(
                _section == 'search' ? 'Search: $_query' : _rowName(_section),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final issue in _issues) _TedNotice(issue.message),
              if (_titles.isEmpty && !_busy && _error == null && _issues.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('No titles returned.')),
              _grid(_titles),
              if (_after != null || _skip != null)
                TextButton(
                  onPressed: _busy ? null : () => _work(() => _load(more: true)),
                  child: const Text('Load more'),
                ),
            ],
          ],
        ),
      ),
    ],
  );
}

String _rowName(String id) => switch (id) {
  'continue-watching' => 'Continue Watching',
  'next-up' => 'Next Up',
  'popular-movie' || 'movie' => 'Movies',
  'popular-series' || 'series' => 'Shows',
  'mapped' => 'Mapped items',
  _ => 'Home',
};
String _position(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _TedPoster extends StatelessWidget {
  final TedTitle title;
  final VoidCallback? onTap;
  const _TedPoster({required this.title, required this.onTap});
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: title.poster.isEmpty
                ? Icon(title.media.kind == 'movie' ? Icons.movie : Icons.tv, size: 64)
                : Image.network(
                    title.poster,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(Icons.image_not_supported, size: 48),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(
                  title.media.kind == 'series'
                      ? title.year
                      : title.positionMs > 0
                      ? 'Resume ${_position(title.positionMs)}'
                      : title.played
                      ? 'Watched'
                      : title.year,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (title.durationMs != null && title.positionMs > 0)
            LinearProgressIndicator(value: (title.positionMs / title.durationMs!).clamp(0, 1)),
        ],
      ),
    ),
  );
}

class _TedNotice extends StatelessWidget {
  final String text;
  final VoidCallback? retry;
  const _TedNotice(this.text, {this.retry});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        Expanded(child: Text(text)),
        if (retry != null) TextButton(onPressed: retry, child: const Text('Retry')),
      ],
    ),
  );
}

class TedTitleScreen extends StatefulWidget {
  final TedClient client;
  final TedTitle initial;
  final TedPlay onPlay;
  const TedTitleScreen({super.key, required this.client, required this.initial, required this.onPlay});
  @override
  State<TedTitleScreen> createState() => _TedTitleScreenState();
}

class _TedTitleScreenState extends State<TedTitleScreen> {
  late TedTitle _title = widget.initial;
  List<TedTitle> _episodes = [];
  int? _season, _next;
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_work(_load));
  }

  Future<void> _work(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on TedFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = const TedFailure('unavailable').message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final title = await widget.client.title(_title.media);
    if (!mounted) return;
    setState(() {
      _title = title;
      if (title.media.kind == 'series' && !title.seasons.contains(_season)) {
        _season = title.seasons.where((s) => s > 0).firstOrNull ?? title.seasons.firstOrNull;
      }
    });
    if (_season != null) await _loadEpisodes();
  }

  Future<void> _loadEpisodes({bool more = false}) async {
    final page = await widget.client.episodes(_title.media.id, _season!, after: more ? _next : null);
    if (!mounted) return;
    setState(() {
      _episodes = more
          ? {
              for (final title in [..._episodes, ...page.titles]) title.media: title,
            }.values.toList()
          : page.titles;
      _next = page.nextAfter;
    });
  }

  Future<void> _play(TedTitle title) => _work(() async {
    await widget.onPlay(title);
    if (mounted) await _load();
  });
  Future<void> _watched(TedTitle title) => _work(() async {
    await widget.client.setWatched(title, !title.played);
    if (mounted) await _load();
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_title.name),
      actions: [
        IconButton(tooltip: 'Reload', onPressed: _busy ? null : () => _work(_load), icon: const Icon(Icons.refresh)),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) _TedNotice(_error!, retry: _busy ? null : () => _work(_load)),
        for (final issue in _title.issues) _TedNotice(issue.message),
        if (_title.background.isNotEmpty)
          SizedBox(
            height: 210,
            child: Image.network(
              _title.background,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        Text(_title.name, style: Theme.of(context).textTheme.headlineSmall),
        Text([_title.year, _title.runtime].where((s) => s.isNotEmpty).join(' · ')),
        const SizedBox(height: 16),
        Text(_title.description),
        const SizedBox(height: 16),
        if (_title.media.playable) ...[
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => _play(_title),
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  !_title.ready
                      ? 'Find sources'
                      : _title.positionMs > 0
                      ? 'Resume ${_position(_title.positionMs)}'
                      : 'Play',
                ),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _watched(_title),
                child: Text(_title.played ? 'Mark unwatched' : 'Mark watched'),
              ),
              if (_title.parent != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _work(() async {
                          final parent = await widget.client.title(_title.parent!);
                          if (!mounted || !context.mounted) return;
                          await Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) =>
                                  TedTitleScreen(client: widget.client, initial: parent, onPlay: widget.onPlay),
                            ),
                          );
                          if (mounted) await _load();
                        }),
                  child: const Text('Show episodes'),
                ),
            ],
          ),
          if (!_title.ready)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Find playable sources from your linked Stremio add-ons.'),
            ),
        ],
        if (_title.media.kind == 'series') ...[
          if (_title.seasons.isEmpty) const Text('No episodes in this catalog.'),
          if (_season != null)
            DropdownButton<int>(
              value: _season,
              items: [
                for (final season in _title.seasons)
                  DropdownMenuItem(value: season, child: Text(season == 0 ? 'Specials' : 'Season $season')),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() {
                          _season = value;
                          _episodes = [];
                          _next = null;
                        });
                        unawaited(_work(() => _loadEpisodes()));
                      }
                    },
            ),
          for (final episode in _episodes)
            ListTile(
              title: Text('Episode ${episode.episode ?? ''} · ${episode.name}'),
              subtitle: Text(
                episode.played
                    ? 'Watched'
                    : episode.positionMs > 0
                    ? 'Resume ${_position(episode.positionMs)}'
                    : 'Unwatched',
              ),
              onTap: _busy
                  ? null
                  : () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) =>
                              TedTitleScreen(client: widget.client, initial: episode, onPlay: widget.onPlay),
                        ),
                      );
                      if (mounted) await _work(() => _loadEpisodes());
                    },
              trailing: IconButton(
                tooltip: episode.played ? 'Mark unwatched' : 'Mark watched',
                onPressed: _busy ? null : () => _watched(episode),
                icon: Icon(episode.played ? Icons.check_circle : Icons.circle_outlined),
              ),
            ),
          if (_next != null)
            TextButton(
              onPressed: _busy ? null : () => _work(() => _loadEpisodes(more: true)),
              child: const Text('Load more episodes'),
            ),
        ],
      ],
    ),
  );
}
