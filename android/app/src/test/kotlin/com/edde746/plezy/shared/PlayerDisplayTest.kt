package com.edde746.plezy.shared

import android.app.Activity
import android.hardware.display.DisplayManager
import android.view.Display
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDisplayManager

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], manifest = Config.NONE)
class PlayerDisplayTest {
  class DetachedActivity : Activity() {
    override fun getDisplay(): Display = throw UnsupportedOperationException("display detached")
  }

  class SecondaryActivity : Activity() {
    var associatedDisplay: Display? = null
    override fun getDisplay(): Display = checkNotNull(associatedDisplay)
  }

  @Test
  @Suppress("DEPRECATION")
  fun aDetachedContextUsesTheWindowsDisplayWithoutThrowing() {
    val activity = Robolectric.buildActivity(DetachedActivity::class.java).setup().get()
    assertThrows(UnsupportedOperationException::class.java) { activity.display }
    assertEquals(activity.windowManager.defaultDisplay.displayId, activity.playerDisplay()?.displayId)
  }

  @Test
  fun anAssociatedSecondaryDisplayIsNotReplacedByTheDefaultDisplay() {
    val activity = Robolectric.buildActivity(SecondaryActivity::class.java).setup().get()
    val displayId = ShadowDisplayManager.addDisplay("w800dp-h600dp")
    activity.associatedDisplay = activity.getSystemService(DisplayManager::class.java).getDisplay(displayId)
    assertEquals(displayId, activity.playerDisplay()?.displayId)
  }
}
