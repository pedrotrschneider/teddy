package com.edde746.plezy.exoplayer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackHttpFailureTest {
  @Test fun transportFailuresRetainStatusForCredentialAndStreamRecovery() {
    for (status in 400..599) {
      val failure = PlaybackHttpFailure.fromStatus(status)!!
      assertEquals("HTTP error $status", failure.message)
      assertEquals(status, failure.status)
    }
  }

  @Test fun legacyCausesRemainAvailableWithoutMisclassifyingAuthAsFormatFailure() {
    assertEquals("server-http-404", PlaybackHttpFailure.fromStatus(404)!!.cause)
    assertEquals("server-http-500", PlaybackHttpFailure.fromStatus(500)!!.cause)
    for (status in listOf(401, 403, 409, 422, 429, 503)) {
      assertNull(PlaybackHttpFailure.fromStatus(status)!!.cause)
    }
  }

  @Test fun absentAndNonFailureStatusesLeaveCodecRecoveryAvailable() {
    for (status in listOf(null, 0, 200, 302, 600)) {
      assertNull(PlaybackHttpFailure.fromStatus(status))
    }
  }
}
