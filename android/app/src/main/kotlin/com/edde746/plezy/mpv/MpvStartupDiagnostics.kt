package com.edde746.plezy.mpv

import com.edde746.plezy.libmpv.MpvEvent

/** First occurrence of each startup phase only, with JNI-to-main delivery time. */
internal class MpvStartupDiagnostics {
  private var sourceId: Long? = null
  private var beganAtMs = 0L
  private val phases = mutableSetOf<String>()
  private var complete = true

  fun onEvent(event: MpvEvent, nowMs: Long): Map<String, Any>? {
    val receivedAtMs = event.receivedAtMs ?: nowMs
    if (event is MpvEvent.StartFile) {
      sourceId = event.sourceId
      beganAtMs = receivedAtMs
      phases.clear()
      complete = false
    }
    if (event.sourceId == null || event.sourceId != sourceId) return null
    if (event is MpvEvent.EndFile) complete = true
    if (complete) return null
    val phase = when (event) {
      is MpvEvent.StartFile -> "start_file"
      is MpvEvent.FileLoaded -> "file_loaded"
      is MpvEvent.VideoReconfig -> "video_reconfig"
      is MpvEvent.AudioReconfig -> "audio_reconfig"
      is MpvEvent.PlaybackRestart -> "restart_received"
      else -> return null
    }
    if (!phases.add(phase)) return null
    if (event is MpvEvent.PlaybackRestart) complete = true
    return mapOf(
      "sourceId" to event.sourceId!!,
      "phase" to phase,
      "elapsedMs" to (receivedAtMs - beganAtMs).coerceAtLeast(0),
      "deliveryMs" to (nowMs - receivedAtMs).coerceAtLeast(0)
    )
  }
}
