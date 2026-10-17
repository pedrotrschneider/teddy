package com.edde746.plezy.exoplayer

/** Preserve transport/auth status across the native-to-Dart error boundary. */
internal data class PlaybackHttpFailure(val status: Int) {
  val message: String get() = "HTTP error $status"
  val cause: String? get() = when (status) {
    404 -> "server-http-404"
    500 -> "server-http-500"
    else -> null
  }

  companion object {
    fun fromStatus(status: Int?): PlaybackHttpFailure? =
      status?.takeIf { it in 400..599 }?.let(::PlaybackHttpFailure)
  }
}
