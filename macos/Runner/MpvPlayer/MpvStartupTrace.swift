import Foundation

/// Translate selected libmpv messages into fixed codes. Raw text never escapes.
enum MpvStartupTraceMarkers {
  static func phase(prefix: String, text: String) -> String? {
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // The demuxer's child log can be named after the container (e.g. mkv),
    // so an internal refresh is not necessarily emitted with prefix demux.
    if line.hasPrefix("refresh seek to ") { return "demux_refresh_seek" }
    if prefix == "cplayer" {
      if line == "Video frame delayed due to waiting on subtitles." { return "subtitle_wait" }
      if line == "first video frame after restart shown" { return "first_video_shown" }
      if line == "audio ready" || line == "audio ready (and EOF)" { return "audio_ready" }
      if line == "starting audio playback" { return "audio_start" }
      if line == "starting video playback" { return "video_start" }
      if line == "blocked, waiting for old audio to play" { return "old_audio_wait" }
      if line.hasPrefix("delaying audio start ") { return "audio_sync_wait" }
      if line.hasPrefix("VO: [") { return "video_output_configure" }
      if line.hasPrefix("AO: [") { return "audio_output_configure" }
      if line.hasPrefix("playback restart complete @ ") { return "core_restart_complete" }
      if line.hasPrefix("Running hook: ") { return "load_hook" }
    }
    if prefix == "vd" {
      if line.hasPrefix("Opening decoder ") { return "video_decoder_open" }
      if line.hasPrefix("Using hardware decoding") { return "hardware_decoding" }
      if line.hasPrefix("Using software decoding") { return "software_decoding" }
      if line.hasPrefix("Decoder format:") { return "video_decoder_format" }
    }
    if prefix == "ad" && line.hasPrefix("Opening decoder ") { return "audio_decoder_open" }
    if prefix == "sub/ass" {
      if line.hasPrefix("libass API version:") { return "subtitle_ass_init" }
      if line == "Setting up fonts..." { return "subtitle_fonts_begin" }
      if line.hasPrefix("Using font provider ") { return "subtitle_font_provider" }
      if line.hasPrefix("fontselect:") { return "subtitle_font_select" }
    }
    if prefix == "demux" {
      if line.hasPrefix("Refreshing seek") || line.hasPrefix("refresh seek") { return "demux_refresh_seek" }
      if line.hasPrefix("Seeking to ") { return "demux_seek" }
      if line.hasPrefix("Detected file format:") { return "container_detected" }
    }
    if prefix == "vo/gpu-next" && line.lowercased().contains("shader") && line.lowercased().contains("compil") {
      return "gpu_shader_compile"
    }
    return nil
  }
}
