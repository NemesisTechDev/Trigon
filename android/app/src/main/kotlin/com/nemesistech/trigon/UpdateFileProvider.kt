package com.nemesistech.trigon

import androidx.core.content.FileProvider

/**
 * Hands the system package installer read access to the downloaded update
 * APK (see res/xml/update_file_paths.xml and AppUpdater.kt).
 *
 * It is a subclass of its own, instead of a plain androidx FileProvider entry,
 * so it can never clash in the merged manifest with a FileProvider that some
 * plugin (file picker, share, cast ...) already declares.
 */
class UpdateFileProvider : FileProvider()
