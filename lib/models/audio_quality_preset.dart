enum AudioQualityPreset {
  original(null),
  high(320),
  medium(192),
  low(128);

  const AudioQualityPreset(this.bitrateKbps);

  final int? bitrateKbps;

  bool get isOriginal => this == AudioQualityPreset.original;
}
