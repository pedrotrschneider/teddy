import 'package:json_annotation/json_annotation.dart';

import '../utils/json_utils.dart';
import 'media_stream.dart';

part 'media_part.g.dart';

@JsonSerializable(includeIfNull: false)
class MediaPart {
  /// Backend-opaque part identifier.
  @JsonKey(fromJson: stringOrEmpty)
  final String id;

  final String? streamPath;

  /// The server-side file path backing this part. The identity signal for
  /// "same underlying file": Plex represents a multi-episode file
  /// (`S02E24-E25.mkv`) as distinct episodes whose parts have *different*
  /// part ids but the same [file] (#1500). May be absent (e.g. Plex hides
  /// paths from restricted users), in which case same-file detection
  /// degrades gracefully.
  final String? file;

  @JsonKey(fromJson: flexibleInt)
  final int? sizeBytes;
  final String? container;
  @JsonKey(fromJson: flexibleInt)
  final int? durationMs;
  final bool? accessible;
  final bool? exists;
  @JsonKey(includeFromJson: false, includeToJson: false)
  final List<MediaStream> streams;

  const MediaPart({
    required this.id,
    this.streamPath,
    this.file,
    this.sizeBytes,
    this.container,
    this.durationMs,
    this.accessible,
    this.exists,
    this.streams = const [],
  });

  factory MediaPart.fromJson(Map<String, dynamic> json) => _$MediaPartFromJson(json);

  Map<String, dynamic> toJson() => _$MediaPartToJson(this);

  /// Defaults to true when fields are absent. Plex sets these only when the
  /// metadata request includes `checkFiles=1`.
  bool get isPlayable => accessible != false && exists != false;
}
