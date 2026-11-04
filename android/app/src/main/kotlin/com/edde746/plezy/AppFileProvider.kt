package com.edde746.plezy

import android.content.Context
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

internal fun Context.shareFileUri(file: File): Uri =
  FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
