import 'dart:async';
import 'package:flutter/material.dart';
import 'ted_downloads.dart';
import 'ted_models.dart';

class TedDownloadButton extends StatefulWidget {
  final TedDownloads? downloads;
  final TedMediaIdentity media;
  final int? season;
  final String label;
  final VoidCallback? onPressed;
  const TedDownloadButton({
    super.key,
    this.downloads,
    required this.media,
    this.season,
    required this.label,
    this.onPressed,
  });
  @override
  State<TedDownloadButton> createState() => _TedDownloadButtonState();
}

class _TedDownloadButtonState extends State<TedDownloadButton> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.downloads?.refreshProgress());
  }

  @override
  void didUpdateWidget(TedDownloadButton old) {
    super.didUpdateWidget(old);
    if (old.downloads != widget.downloads) unawaited(widget.downloads?.refreshProgress());
  }

  Widget _button() {
    final progress = widget.downloads?.progress(widget.media, season: widget.season);
    final pending = progress?.pending == true;
    return OutlinedButton.icon(
      onPressed: pending ? null : widget.onPressed,
      icon: const Icon(Icons.download_outlined),
      label: pending
          ? SizedBox(
              width: 180,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(progress!.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (!progress.grouped && progress.status == 'downloading')
                    Text(progress.speed, style: const TextStyle(fontSize: 11)),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: progress.fraction, minHeight: 3),
                ],
              ),
            )
          : Text(widget.label),
    );
  }

  @override
  Widget build(BuildContext context) => widget.downloads == null
      ? _button()
      : ListenableBuilder(listenable: widget.downloads!, builder: (_, _) => _button());
}
