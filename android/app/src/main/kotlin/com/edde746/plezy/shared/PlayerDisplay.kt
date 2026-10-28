package com.edde746.plezy.shared

import android.app.Activity
import android.os.Build
import android.view.Display

/** Display reads must remain safe while an Activity/window is being detached. */
@Suppress("DEPRECATION")
internal fun Activity.playerDisplay(): Display? {
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
    try {
      display?.let { return it }
    } catch (_: UnsupportedOperationException) {
      // Context.getDisplay throws when the context is no longer associated
      // with a display. WindowManager still owns this window's display.
    }
  }
  return windowManager?.defaultDisplay
}
