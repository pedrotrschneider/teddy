package com.edde746.plezy.mpv

import com.edde746.plezy.libmpv.EndFileReason
import com.edde746.plezy.libmpv.MpvEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MpvStartupDiagnosticsTest {
  @Test
  fun `JNI receipt timing separates native startup from main-thread delivery and stops after first restart`() {
    val diagnostics = MpvStartupDiagnostics()
    assertEquals(0L, diagnostics.onEvent(MpvEvent.StartFile(7, 100), 110)?.get("elapsedMs"))
    val video = diagnostics.onEvent(MpvEvent.VideoReconfig(7, 150), 180)!!
    assertEquals(mapOf("sourceId" to 7L, "phase" to "video_reconfig", "elapsedMs" to 50L, "deliveryMs" to 30L), video)
    repeat(100) { assertNull(diagnostics.onEvent(MpvEvent.VideoReconfig(7, 160), 190)) }
    assertEquals("audio_reconfig", diagnostics.onEvent(MpvEvent.AudioReconfig(7, 170), 190)?.get("phase"))
    assertEquals("file_loaded", diagnostics.onEvent(MpvEvent.FileLoaded(7, 180), 200)?.get("phase"))
    assertEquals("restart_received", diagnostics.onEvent(MpvEvent.PlaybackRestart(7, 0.0, 200), 230)?.get("phase"))
    assertNull(diagnostics.onEvent(MpvEvent.PlaybackRestart(7, 20.0, 250), 260))
  }

  @Test
  fun `retired events and failed entries cannot publish into a successor profile`() {
    val diagnostics = MpvStartupDiagnostics()
    assertNull(diagnostics.onEvent(MpvEvent.FileLoaded(7), 1))
    diagnostics.onEvent(MpvEvent.StartFile(7, 100), 100)
    diagnostics.onEvent(MpvEvent.StartFile(8, 200), 200)
    assertNull(diagnostics.onEvent(MpvEvent.EndFile(EndFileReason.Stop, 7), 210))
    assertNull(diagnostics.onEvent(MpvEvent.FileLoaded(7, 220), 220))
    assertEquals(30L, diagnostics.onEvent(MpvEvent.FileLoaded(8, 230), 240)?.get("elapsedMs"))
    diagnostics.onEvent(MpvEvent.EndFile(EndFileReason.Error, 8), 250)
    assertNull(diagnostics.onEvent(MpvEvent.AudioReconfig(8, 260), 260))
    diagnostics.onEvent(MpvEvent.StartFile(9, 300), 300)
    assertEquals(20L, diagnostics.onEvent(MpvEvent.FileLoaded(9, 320), 320)?.get("elapsedMs"))
    diagnostics.onEvent(MpvEvent.StartFile(null, 400), 400)
    assertNull(diagnostics.onEvent(MpvEvent.FileLoaded(null, 420), 420))
  }
}
