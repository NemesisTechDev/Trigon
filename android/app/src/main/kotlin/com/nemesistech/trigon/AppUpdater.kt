package com.nemesistech.trigon

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Native half of the in-app updater (the Dart half is lib/services/update/).
 *
 * Dart downloads the new APK into [updateDir]; this object does everything
 * that needs Android itself:
 *
 *  - getVersionInfo         the installed versionName / versionCode (so the app
 *                           never needs a hard-coded version string)
 *  - getUpdateDir           the folder Dart downloads into (shared with the
 *                           installer through [UpdateFileProvider])
 *  - canInstallPackages     whether "Install unknown apps" is allowed for Trigon
 *  - openInstallSettings    opens that exact system switch for Trigon
 *  - installApk             checks the downloaded file really is a newer build of
 *                           this app signed with the same key, then opens the
 *                           system installer on it
 *
 * Every failure is reported with a short code (see [UpdateException]) that the
 * Dart side turns into a proper message.
 */
object AppUpdater {
    const val CHANNEL = "com.nemesis.app/app_update"

    private const val APK_MIME = "application/vnd.android.package-archive"

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private class UpdateException(val code: String, message: String) : Exception(message)

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getVersionInfo" -> {
                try {
                    result.success(versionInfo(activity))
                } catch (e: Throwable) {
                    result.error("version_failed", e.message, null)
                }
            }

            "getUpdateDir" -> {
                try {
                    result.success(updateDir(activity).absolutePath)
                } catch (e: Throwable) {
                    result.error("dir_failed", e.message, null)
                }
            }

            "canInstallPackages" -> {
                result.success(canInstall(activity))
            }

            "openInstallSettings" -> {
                try {
                    openInstallSettings(activity)
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("settings_failed", e.message, null)
                }
            }

            "installApk" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("missing_file", "No update file was given.", null)
                    return
                }
                // Reading and verifying a ~100 MB APK must not block the UI thread.
                worker.execute {
                    val failure: UpdateException? = try {
                        if (!canInstall(activity)) {
                            UpdateException(
                                "install_permission",
                                "Allow Trigon to install apps first."
                            )
                        } else {
                            verifyApk(activity, File(path))
                            null
                        }
                    } catch (e: UpdateException) {
                        e
                    } catch (e: Throwable) {
                        UpdateException("verify_failed", e.message ?: "The update could not be checked.")
                    }
                    main.post {
                        if (failure != null) {
                            result.error(failure.code, failure.message, null)
                        } else {
                            try {
                                launchInstaller(activity, File(path))
                                result.success(true)
                            } catch (e: UpdateException) {
                                result.error(e.code, e.message, null)
                            } catch (e: Throwable) {
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    // ───────────────────────────── version / folders ─────────────────────────────

    @Suppress("DEPRECATION")
    private fun versionInfo(ctx: Context): Map<String, Any?> {
        val info = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        return mapOf(
            "versionName" to (info.versionName ?: ""),
            "versionCode" to versionCodeOf(info),
            "packageName" to ctx.packageName
        )
    }

    @Suppress("DEPRECATION")
    private fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else info.versionCode.toLong()

    /** <app files dir>/updates - must match res/xml/update_file_paths.xml. */
    private fun updateDir(ctx: Context): File {
        val dir = File(ctx.filesDir, "updates")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    // ───────────────────────────── install permission ─────────────────────────────

    private fun canInstall(ctx: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ctx.packageManager.canRequestPackageInstalls()
        } else {
            true // before Android 8 it is one global "Unknown sources" switch
        }

    private fun openInstallSettings(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}")
                    )
                )
                return
            } catch (e: ActivityNotFoundException) {
                // Some builds lack the per-app screen: fall through to the app's own page.
            }
            activity.startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${activity.packageName}")
                )
            )
        } else {
            @Suppress("DEPRECATION")
            activity.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
        }
    }

    // ───────────────────────────── verify + install ─────────────────────────────

    @Suppress("DEPRECATION")
    private fun verifyApk(ctx: Context, file: File) {
        if (!file.isFile || file.length() <= 0L) {
            throw UpdateException("missing_file", "The downloaded update file is missing.")
        }
        val pm = ctx.packageManager

        val archive = pm.getPackageArchiveInfo(file.absolutePath, 0)
            ?: throw UpdateException(
                "invalid_apk",
                "The downloaded file is not a valid app package."
            )
        if (archive.packageName != ctx.packageName) {
            throw UpdateException(
                "wrong_package",
                "The downloaded file belongs to a different app."
            )
        }

        val installed = pm.getPackageInfo(ctx.packageName, 0)
        if (versionCodeOf(archive) < versionCodeOf(installed)) {
            throw UpdateException(
                "downgrade",
                "The downloaded file is older than the installed version."
            )
        }

        // Android refuses to update an app with a build signed by a different
        // key; say so plainly instead of the installer's generic failure.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val flags = PackageManager.GET_SIGNING_CERTIFICATES
                val a = signaturesOf(pm.getPackageArchiveInfo(file.absolutePath, flags))
                val b = signaturesOf(pm.getPackageInfo(ctx.packageName, flags))
                if (a.isNotEmpty() && b.isNotEmpty() && a.intersect(b).isEmpty()) {
                    throw UpdateException(
                        "signature_mismatch",
                        "This update is signed with a different key than the installed app."
                    )
                }
            } catch (e: UpdateException) {
                throw e
            } catch (e: Throwable) {
                // Could not read the signatures: let the system installer decide.
            }
        }
    }

    private fun signaturesOf(info: PackageInfo?): Set<String> {
        val out = HashSet<String>()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return out
        val si = info?.signingInfo ?: return out
        si.apkContentsSigners?.forEach { out.add(it.toCharsString()) }
        si.signingCertificateHistory?.forEach { out.add(it.toCharsString()) }
        return out
    }

    private fun launchInstaller(activity: Activity, file: File) {
        if (activity.isFinishing) {
            throw UpdateException("install_failed", "The app is closing.")
        }
        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.updatefileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, APK_MIME)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            activity.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw UpdateException(
                "no_installer",
                "No package installer was found on this device."
            )
        }
    }
}
