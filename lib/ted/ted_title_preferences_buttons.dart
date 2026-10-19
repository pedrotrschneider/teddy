import 'ted_focus_region.dart';
import 'package:flutter/material.dart';
import 'ted_client.dart';
import 'ted_rating.dart';
import 'ted_rating_icon.dart';
import 'ted_models.dart';

class TedTitlePreferencesButtons extends StatefulWidget {
  final TedClient client;
  final TedTitle title;
  final ValueChanged<TedTitlePreferences> onChanged;
  final VoidCallback? onFocused;
  const TedTitlePreferencesButtons({
    super.key,
    required this.client,
    required this.title,
    required this.onChanged,
    this.onFocused,
  });
  @override
  State<TedTitlePreferencesButtons> createState() => _TedTitlePreferencesButtonsState();
}

class _TedTitlePreferencesButtonsState extends State<TedTitlePreferencesButtons> {
  bool _busy = false;
  String? _error;
  Future<void> _save(String field, {bool? watchlist, int? rating}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await widget.client.setTitlePreference(
        widget.title.media,
        field,
        watchlist: watchlist,
        rating: rating,
      );
      if (mounted) widget.onChanged(state);
    } catch (e) {
      if (mounted) setState(() => _error = e is TedFailure ? e.message : 'Cannot save this preference.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rate(int? current) async {
    // A sentinel distinguishes clearing a rating from cancelling the dialog.
    final choice = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Rate ${widget.title.name}'),
        children: [
          TedFocusRegion(
            autofocus: true,
            grid: true,
            onBack: () => Navigator.pop(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 1; i <= 7; i++)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, i),
                    child: Row(
                      children: [
                        TedRatingBadge(rating: i),
                        const SizedBox(width: 12),
                        Expanded(child: Text(tedRatingNames[i - 1])),
                        if (i == current) const Icon(Icons.check),
                      ],
                    ),
                  ),
                if (current != null)
                  SimpleDialogOption(onPressed: () => Navigator.pop(context, 0), child: const Text('Clear rating')),
                SimpleDialogOption(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice != null && mounted) await _save('rating', rating: choice == 0 ? null : choice);
  }

  Widget _focus(Widget child) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (focused) {
      if (focused) widget.onFocused?.call();
    },
    child: child,
  );
  @override
  Widget build(BuildContext context) {
    final state = TedTitlePreferences(widget.title.watchlist, widget.title.userRating);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _focus(
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _save('watchlist', watchlist: !state.watchlist),
            icon: Icon(
              state.watchlist ? Icons.bookmark : Icons.bookmark_border,
              color: state.watchlist ? Colors.green : null,
            ),
            label: Text(state.watchlist ? 'Remove from Watch List' : 'Add to Watch List'),
          ),
        ),
        _focus(
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _rate(state.rating),
            icon: state.rating == null ? const Icon(Icons.rate_review_outlined) : TedRatingBadge(rating: state.rating!),
            label: Text(state.rating == null ? 'Rate' : tedRatingNames[state.rating! - 1]),
          ),
        ),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}
