import Foundation

@main
struct StartupTraceTests {
  static func main() {
    // Audio, subtitle and actual video presentation must remain distinct.
    precondition(MpvStartupTraceMarkers.phase(prefix: "cplayer", text: "audio ready\n") == "audio_ready")
    precondition(
      MpvStartupTraceMarkers.phase(prefix: "sub/ass", text: "Setting up fonts...\n") == "subtitle_fonts_begin")
    precondition(
      MpvStartupTraceMarkers.phase(prefix: "cplayer", text: "first video frame after restart shown\n")
        == "first_video_shown")
    precondition(
      MpvStartupTraceMarkers.phase(prefix: "cplayer", text: "Video frame delayed due to waiting on subtitles.")
        == "subtitle_wait")
    precondition(
      MpvStartupTraceMarkers.phase(prefix: "cplayer", text: "blocked, waiting for old audio to play")
        == "old_audio_wait")
    // Provider/header/path contents may resemble markers but are never logged.
    let secret = "Authorization: Bearer private-token https://private.invalid/private-file"
    precondition(MpvStartupTraceMarkers.phase(prefix: "ffmpeg", text: secret) == nil)
    precondition(MpvStartupTraceMarkers.phase(prefix: "http", text: "audio ready") == nil)
    precondition(MpvStartupTraceMarkers.phase(prefix: "mkv", text: "refresh seek to 0.000000") == "demux_refresh_seek")
    precondition(MpvStartupTraceMarkers.phase(prefix: "cplayer", text: secret) == nil)
    precondition(MpvStartupTraceMarkers.phase(prefix: "vd", text: "Opening decoder " + secret) == "video_decoder_open")
    precondition(
      MpvStartupTraceMarkers.phase(prefix: "sub/ass", text: "fontselect: " + secret) == "subtitle_font_select")
    print("Native startup trace marker/privacy checks passed")
  }
}
