package com.nemesistech.trigon

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.provider.Settings
import android.hardware.SensorManager
import android.system.Os
import android.view.OrientationEventListener
import android.webkit.MimeTypeMap
import com.ryanheise.audioservice.AudioServiceActivity
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * Native side of three Dart channels (the Dart side was always there; this
 * file is what had been reduced to an empty class, which is why "Open with"
 * / "Play with" stopped working):
 *
 *  - com.nemesis.app/external_media   "Open with" / "Play with" for local
 *    audio and video files, plus the file-descriptor helpers local casting
 *    uses (openContentFd / closeContentFd).
 *  - com.nemesis.app/media_notification   flips the "ongoing" flag of the
 *    now-playing notification so it can be swiped away when paused.
 *  - com.nemesis.app/download_service   starts / stops the foreground
 *    service that keeps downloads running with the screen off or the app in
 *    the background (see DownloadService.kt).
 *  - com.nemesis.app/app_update   the in-app updater's Android side: installed
 *    version, the "install unknown apps" permission, and handing the
 *    downloaded APK to the system installer (see AppUpdater.kt).
 */
/**
 * Extends [AudioServiceActivity] (not a plain FlutterActivity) on purpose: the
 * lock-screen / notification "now playing" widget is built by the audio_service
 * plugin, which refuses every call (AudioService.init throws "The Activity class
 * declared in your AndroidManifest.xml is wrong or has not provided the correct
 * FlutterEngine") unless the Activity runs on the plugin's own cached engine,
 * AudioServicePlugin.getFlutterEngine(). The process-wide engine below is
 * therefore always taken from there.
 */
class MainActivity : AudioServiceActivity() {

    companion object {
        /** Channel to the running Dart side; null once the Flutter engine is gone. */
        @Volatile
        private var downloadChannel: MethodChannel? = null

        /**
         * The one Flutter engine (and so the one running Dart app) of this
         * process. It is kept in the companion instead of being owned by the
         * Activity, so that when Android destroys the Activity in the
         * background (memory pressure, a few minutes away) the app is still
         * there, with its screens, and a returning Activity simply reattaches
         * to it instead of booting a new engine from the splash screen.
         *
         * It is destroyed only when the app is really left:
         *  - the Activity finishes (the Exit button, back from the root, the
         *    app swiped out of the recent apps list while it was open), or
         *  - a launch starts with no saved state (the task is gone: the app
         *    was swiped away while its Activity was already destroyed).
         */
        @Volatile
        private var sharedEngine: FlutterEngine? = null

        /** Activities currently alive (created, not yet destroyed). */
        @Volatile
        private var liveActivities = 0

        /**
         * True when Android recreated the app after killing its process (the
         * task was still in the recent apps list): the Dart side then skips
         * the splash animation and returns to the last tab.
         */
        @Volatile
        private var restoredLaunch = false

        /**
         * Dart asked for the phone's physical tilt (a video player screen is
         * open). Kept here, not in the Activity, because the engine (and so
         * the player screen) can outlive the Activity.
         */
        @Volatile
        private var physicalTrackingRequested = false

        /**
         * Called when the app's task was removed (swiped away). If no
         * Activity is left to do it, destroys the orphaned engine so nothing
         * keeps running invisibly and the next launch starts from the splash.
         */
        fun releaseEngineIfOrphaned() {
            if (liveActivities > 0) return // the finishing Activity destroys it
            releaseAllMulticast()
            val e = sharedEngine ?: return
            sharedEngine = null
            downloadChannel = null
            retireEngine(e)
        }

        /** True while [e] is still audio_service's live, cached engine. */
        private fun isCachedEngine(e: FlutterEngine?): Boolean =
            e != null &&
                    FlutterEngineCache.getInstance().get(AudioServicePlugin.getFlutterEngineId()) === e

        /**
         * Removes [e] from audio_service's engine cache, so the next
         * AudioServicePlugin.getFlutterEngine() builds a fresh engine instead
         * of handing out a dead (or about-to-be-destroyed) one.
         */
        private fun forgetCachedEngine(e: FlutterEngine?) {
            if (isCachedEngine(e)) {
                FlutterEngineCache.getInstance().remove(AudioServicePlugin.getFlutterEngineId())
            }
        }

        /**
         * Destroys [e] and drops it from the cache. Does nothing when audio_service
         * has already disposed it (AudioServicePlugin.disposeFlutterEngine()), so
         * an engine is never destroyed twice.
         */
        private fun retireEngine(e: FlutterEngine) {
            if (!isCachedEngine(e)) return
            forgetCachedEngine(e)
            try {
                e.destroy()
            } catch (t: Throwable) {
            }
        }

        /**
         * Wi-Fi multicast lock. Android's Wi-Fi stack normally drops multicast
         * packets that are not addressed to this device; Google Cast devices
         * (and many other TVs) answer discovery over multicast (mDNS), so
         * while the cast picker scans, the app holds this lock. The lock is
         * process-wide and shared by several owners (the DLNA scan and the
         * Google Cast scan each ask for it separately), and is only released
         * once the last owner has let go. It lives here, not in the Activity,
         * so it survives the Activity being destroyed while the engine lives
         * on. Needs CHANGE_WIFI_MULTICAST_STATE (declared in the manifest).
         */
        private var multicastLock: WifiManager.MulticastLock? = null
        private val multicastOwners = HashSet<String>()

        @Synchronized
        fun setMulticastLock(context: Context, owner: String, acquire: Boolean): Boolean {
            return try {
                if (acquire) multicastOwners.add(owner) else multicastOwners.remove(owner)
                if (multicastOwners.isNotEmpty()) {
                    if (multicastLock == null) {
                        val wifi = context.applicationContext
                            .getSystemService(Context.WIFI_SERVICE) as? WifiManager
                            ?: return false
                        multicastLock = wifi.createMulticastLock("trigon-discovery").apply {
                            setReferenceCounted(false)
                        }
                    }
                    multicastLock?.let { if (!it.isHeld) it.acquire() }
                } else {
                    multicastLock?.let { if (it.isHeld) it.release() }
                }
                true
            } catch (e: Exception) {
                false
            }
        }

        @Synchronized
        fun releaseAllMulticast() {
            multicastOwners.clear()
            try {
                multicastLock?.let { if (it.isHeld) it.release() }
            } catch (e: Exception) {
            }
        }

        /**
         * A Pause / Resume / Cancel button on a download notification was
         * tapped. Returns false when no app is running to receive it.
         */
        fun deliverDownloadAction(actionId: String): Boolean {
            val ch = downloadChannel ?: return false
            Handler(Looper.getMainLooper()).post {
                try {
                    ch.invokeMethod("action", actionId)
                } catch (e: Throwable) {
                }
            }
            return true
        }
    }

    private var externalChannel: MethodChannel? = null

    /** Physical tilt of the phone in degrees (0..359), -1 = unknown / flat. */
    private var physicalListener: OrientationEventListener? = null
    @Volatile
    private var physicalDegrees = OrientationEventListener.ORIENTATION_UNKNOWN

    /** The engine this Activity instance attached to. */
    private var myEngine: FlutterEngine? = null

    /** True when this Activity was started with no saved state (a real launch). */
    private var freshLaunch = true
    private val io = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** The file the app was cold-launched on, until Dart asks for it. */
    private var pendingUri: Uri? = null
    private var pendingMime: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        freshLaunch = savedInstanceState == null
        liveActivities++

        // Only a genuine fresh launch carries a file to open. A recreated
        // activity (savedInstanceState != null) would replay the old intent.
        if (savedInstanceState == null) {
            viewTarget(intent)?.let { (uri, mime) ->
                pendingUri = uri
                pendingMime = mime
            }
        }
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        // A tap on the body of a download notification: show the Downloads tab.
        if (intent.action == DownloadNotifications.OPEN_ACTION) {
            downloadChannel?.invokeMethod(
                "open",
                intent.getStringExtra(DownloadNotifications.EXTRA_OPEN_TAB) ?: ""
            )
            return
        }

        val target = viewTarget(intent) ?: return
        val (uri, mime) = target
        io.execute {
            // Light payload only: playback must start right away. Tags,
            // cover art, the video frame and subtitles are fetched by Dart
            // afterwards (enrichMedia / videoFrame / scanSidecarSubtitles).
            val payload = try {
                lightPayload(uri, mime)
            } catch (e: Throwable) {
                null
            } ?: return@execute
            mainHandler.post {
                externalChannel?.invokeMethod("onExternalMedia", payload)
            }
        }
    }

    /**
     * Hands this Activity the process-wide engine (see [sharedEngine]),
     * creating it on first use.
     *
     * The engine is ALWAYS obtained from [AudioServicePlugin.getFlutterEngine]
     * (audio_service's own cached engine) and never built with
     * FlutterEngine(context): audio_service compares the Activity's engine with
     * that cached one and, on a mismatch, makes AudioService.init() fail, which
     * silently removes the lock-screen / notification widget (and the mismatch
     * also made the plugin boot a second, headless copy of the whole Dart app).
     * getFlutterEngine() also starts the Dart entrypoint; its first platform
     * messages are only delivered once onCreate has finished, i.e. after
     * [configureFlutterEngine] has installed the channel handlers.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        var engine = sharedEngine

        // audio_service can dispose its engine on its own (when the playback
        // service ends while no Activity is attached). A remembered engine
        // that is no longer the cached one is dead: forget it.
        if (engine != null && !isCachedEngine(engine)) {
            sharedEngine = null
            downloadChannel = null
            engine = null
        }

        // A launch with no saved state while an engine is still around means
        // the task was removed (swiped away) after its Activity had already
        // been destroyed: that is a new start, not a return, so drop the old
        // app. (If another Activity is still alive it is finishing and
        // destroys its own engine; only forget the reference then.)
        if (engine != null && freshLaunch) {
            if (liveActivities <= 1) {
                retireEngine(engine)
            } else {
                forgetCachedEngine(engine)
            }
            sharedEngine = null
            downloadChannel = null
            engine = null
        }

        if (engine == null) {
            engine = AudioServicePlugin.getFlutterEngine(context)
            sharedEngine = engine
            restoredLaunch = !freshLaunch
        }
        myEngine = engine
        return engine
    }

    /**
     * Keep the engine (and the running app) when Android merely destroys the
     * Activity; destroy it only when the Activity is really finishing.
     */
    override fun shouldDestroyEngineWithHost(): Boolean = isFinishing

    override fun onDestroy() {
        super.onDestroy()
        liveActivities = (liveActivities - 1).coerceAtLeast(0)
        // The app is really being left (the engine goes with it): do not
        // leave the Wi-Fi multicast lock held.
        if (isFinishing) releaseAllMulticast()
        // The sensor listener belongs to this Activity.
        setPhysicalTracking(false, remember = false)
        // The engine was destroyed by the call above when finishing: forget
        // it (only if it is still the current one - a newer launch may
        // already have replaced it).
        if (isFinishing && myEngine != null && myEngine === sharedEngine) {
            // super.onDestroy() has just destroyed it: also take it out of
            // audio_service's cache so it is never handed out again.
            forgetCachedEngine(myEngine)
            sharedEngine = null
            downloadChannel = null
        }
        myEngine = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        externalChannel = MethodChannel(messenger, "com.nemesis.app/external_media").also {
            it.setMethodCallHandler { call, result -> onExternalCall(call, result) }
        }

        MethodChannel(messenger, "com.nemesis.app/download_notifications").also {
            downloadChannel = it
            it.setMethodCallHandler { call, result -> onDownloadNotificationCall(call, result) }
        }

        // Wi-Fi multicast lock for the cast scans (see setMulticastLock). The
        // Dart side (DlnaTransport, GoogleCastTransport) has always called
        // this channel, but this file had no handler for it, so the lock was
        // never taken (Project Nemesis's MainActivity does take it). "owner"
        // is optional ("dlna" when absent, for the older call shape).
        MethodChannel(messenger, "com.nemesis.app/multicast_lock")
            .setMethodCallHandler { call, result ->
                val owner = call.argument<String>("owner") ?: "dlna"
                when (call.method) {
                    "acquire" -> result.success(setMulticastLock(applicationContext, owner, true))
                    "release" -> result.success(setMulticastLock(applicationContext, owner, false))
                    else -> result.notImplemented()
                }
            }

        // Used by the video players when they close (see PlayerOrientation in
        // Dart): "exitPlan" says whether Android would keep the screen in
        // landscape once the player's orientation lock is released - that
        // needs auto-rotate on AND the phone physically held on its side.
        // When it would not, Dart turns the screen to portrait BEFORE the
        // player is closed, so the screen underneath is never drawn in
        // landscape first.
        MethodChannel(messenger, "com.nemesis.app/orientation")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "track" -> {
                        setPhysicalTracking((call.arguments as? Boolean) ?: false)
                        result.success(true)
                    }

                    "exitPlan" -> result.success(
                        hashMapOf<String, Any>(
                            "autoRotate" to autoRotateOn(),
                            "degrees" to physicalDegrees
                        )
                    )

                    else -> result.notImplemented()
                }
            }
        // A returning Activity re-attaches to a live player screen: pick the
        // sensor up again.
        if (physicalTrackingRequested) setPhysicalTracking(true)

        MethodChannel(messenger, "com.nemesis.app/launch")
            .setMethodCallHandler { call, result ->
                if (call.method == "wasRestored") {
                    result.success(restoredLaunch)
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(messenger, "com.nemesis.app/media_notification")
            .setMethodCallHandler { call, result ->
                if (call.method == "setOngoing") {
                    val ongoing = call.argument<Boolean>("ongoing") ?: false
                    result.success(applyMediaNotificationOngoing(ongoing))
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(messenger, AppUpdater.CHANNEL)
            .setMethodCallHandler { call, result ->
                AppUpdater.handle(this, call, result)
            }

        // Ad blocker for the Embed servers' web player only (see
        // EmbedAdBlocker.kt). Dart passes the identifier of the one WebView
        // its EmbedPlayerScreen created; the blocker is put on that WebView
        // alone, so no other network traffic in the app is touched.
        MethodChannel(messenger, "com.nemesis.app/embed_adblock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> {
                        val id = call.argument<Number>("webViewId")?.toLong()
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        if (id == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            @Suppress("DEPRECATION")
                            val webView = WebViewFlutterAndroidExternalApi.getWebView(flutterEngine, id)
                            val ok = webView != null && EmbedAdBlocker.install(webView, enabled)
                            if (ok && enabled) EmbedAdBlocker.refreshInBackground(applicationContext)
                            result.success(ok)
                        } catch (e: Throwable) {
                            result.success(false)
                        }
                    }

                    "blockedCount" -> result.success(EmbedAdBlocker.blockedCount())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, "com.nemesis.app/download_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start", "update" -> {
                        val title = call.argument<String>("title") ?: "Downloading"
                        val text = call.argument<String>("text") ?: ""
                        // false: only keep the app alive, without wake/Wi-Fi locks
                        // (everything is paused).
                        val hold = call.argument<Boolean>("hold") ?: true
                        result.success(DownloadService.start(applicationContext, title, text, hold))
                    }
                    "stop" -> {
                        DownloadService.stop(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ───────────────────────── orientation channel ─────────────────────────

    /** The system "Auto-rotate" switch (true when it can't be read). */
    private fun autoRotateOn(): Boolean = try {
        Settings.System.getInt(
            applicationContext.contentResolver,
            Settings.System.ACCELEROMETER_ROTATION,
            1
        ) == 1
    } catch (e: Throwable) {
        true
    }

    /**
     * Starts / stops reading the phone's physical tilt. Works whatever the
     * app's own orientation lock is (it reads the accelerometer, not the
     * screen rotation). Only on while a video player screen is open.
     */
    private fun setPhysicalTracking(on: Boolean, remember: Boolean = true) {
        if (remember) physicalTrackingRequested = on
        try {
            if (on) {
                if (physicalListener == null) {
                    physicalListener = object : OrientationEventListener(
                        applicationContext,
                        SensorManager.SENSOR_DELAY_NORMAL
                    ) {
                        override fun onOrientationChanged(orientation: Int) {
                            physicalDegrees = orientation
                        }
                    }
                }
                physicalListener?.let { if (it.canDetectOrientation()) it.enable() }
            } else {
                physicalListener?.disable()
                physicalListener = null
                physicalDegrees = OrientationEventListener.ORIENTATION_UNKNOWN
            }
        } catch (e: Throwable) {
        }
    }

    // ──────────────────── download notifications channel ────────────────────

    @Suppress("UNCHECKED_CAST")
    private fun onDownloadNotificationCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "show" -> {
                try {
                    DownloadNotifications.show(
                        applicationContext,
                        call.arguments as Map<String, Any?>
                    )
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("show_failed", e.message, null)
                }
            }

            "cancel" -> {
                try {
                    val id = (call.arguments as? Number)?.toInt()
                    if (id != null) DownloadNotifications.cancel(applicationContext, id)
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("cancel_failed", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    // ───────────────────────── external_media channel ─────────────────────────

    private fun onExternalCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consumeInitialMedia" -> {
                val uri = pendingUri
                val mime = pendingMime
                pendingUri = null
                pendingMime = null
                if (uri == null) {
                    result.success(null)
                    return
                }
                io.execute {
                    val payload = try {
                        lightPayload(uri, mime)
                    } catch (e: Throwable) {
                        null
                    }
                    mainHandler.post { result.success(payload) }
                }
            }

            // Duration, tags, embedded cover and same-name lyrics/subtitle:
            // the cheap part of the old payload (no video frame).
            "enrichMedia" -> {
                val uri = call.argument<String>("uri")
                if (uri == null) {
                    result.success(null)
                    return
                }
                val mime = call.argument<String>("mime")
                io.execute {
                    val payload = try {
                        quickPayload(Uri.parse(uri), mime)
                    } catch (e: Throwable) {
                        null
                    }
                    mainHandler.post { result.success(payload) }
                }
            }

            // The slow part (decoding a video frame), only ever asked for
            // after playback has already started.
            "videoFrame" -> {
                val uri = call.argument<String>("uri")
                if (uri == null) {
                    result.success(null)
                    return
                }
                io.execute {
                    val bytes = try {
                        extractVideoFrame(Uri.parse(uri))
                    } catch (e: Throwable) {
                        null
                    }
                    mainHandler.post { result.success(bytes) }
                }
            }

            "scanSidecarSubtitles" -> {
                val uri = call.argument<String>("uri")
                if (uri == null) {
                    result.success(emptyList<Map<String, String>>())
                    return
                }
                io.execute {
                    val list = try {
                        scanSidecarSubtitleFiles(Uri.parse(uri))
                    } catch (e: Throwable) {
                        emptyList<Map<String, String>>()
                    }
                    mainHandler.post { result.success(list) }
                }
            }

            "openContentFd" -> {
                val uri = call.argument<String>("uri")
                if (uri == null) {
                    result.success(null)
                    return
                }
                try {
                    val pfd = applicationContext.contentResolver.openFileDescriptor(Uri.parse(uri), "r")
                    // detachFd hands ownership of the raw fd to Dart; it comes
                    // back through closeContentFd.
                    result.success(pfd?.detachFd())
                } catch (e: Throwable) {
                    result.success(null)
                }
            }

            "closeContentFd" -> {
                val fd = call.argument<Int>("fd")
                if (fd != null) {
                    try {
                        ParcelFileDescriptor.adoptFd(fd).close()
                    } catch (e: Throwable) {
                        // already closed
                    }
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /** Intent that asks to open a file, or null for any other launch. */
    private fun viewTarget(intent: Intent?): Pair<Uri, String?>? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        val data = intent.data ?: return null
        val scheme = data.scheme ?: return null
        if (scheme != "content" && scheme != "file") return null
        return Pair(data, intent.type)
    }

    private fun resolveMime(uri: Uri, hint: String?): String {
        if (!hint.isNullOrEmpty() && hint != "*/*") return hint
        try {
            applicationContext.contentResolver.getType(uri)?.let { if (it.isNotEmpty() && it != "*/*") return it }
        } catch (e: Throwable) {
        }
        val name = displayName(uri) ?: uri.toString()
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext.isNotEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)?.let { return it }
            if (ext == "mkv") return "video/x-matroska"
        }
        return ""
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        try {
            applicationContext.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) {
                        val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (i >= 0) return c.getString(i)
                    }
                }
        } catch (e: Throwable) {
        }
        return uri.lastPathSegment
    }

    private val audioExt = setOf("mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma")

    /**
     * Just enough to start playing: no MediaMetadataRetriever, no file reads.
     * Runs off the UI thread (the provider queries can block).
     */
    private fun lightPayload(uri: Uri, mimeHint: String?): HashMap<String, Any?> {
        val out = HashMap<String, Any?>()
        out["uri"] = uri.toString()
        out["mimeType"] = resolveMime(uri, mimeHint)
        out["displayName"] = displayName(uri)
        out["light"] = true
        return out
    }

    /**
     * Duration, tags, embedded cover and a same-name lyrics/subtitle file.
     * Deliberately WITHOUT the video frame, which can take very long on
     * large files. Runs off the UI thread.
     */
    private fun quickPayload(uri: Uri, mimeHint: String?): HashMap<String, Any?> {
        val out = HashMap<String, Any?>()
        val mime = resolveMime(uri, mimeHint)
        val name = displayName(uri)

        val ext = (name ?: uri.toString()).substringAfterLast('.', "").lowercase()
        val isAudio = mime.startsWith("audio/") ||
                (!mime.startsWith("video/") && ext in audioExt)

        extractEmbedded(uri, isAudio, out)

        // Single same-name sidecar (the fallback Dart uses when it cannot get
        // a full folder listing).
        val real = realPath(uri)
        if (real != null) {
            val base = File(real).nameWithoutExtension
            val dir = File(real).parentFile
            if (dir != null) {
                val wanted = if (isAudio) listOf("lrc") else listOf("srt", "vtt", "ass", "ssa")
                for (e in wanted) {
                    val f = File(dir, "$base.$e")
                    val text = readSmallText(f) ?: continue
                    if (isAudio) {
                        out["lyricsContent"] = text
                        out["lyricsFileName"] = f.name
                    } else {
                        out["subtitleContent"] = text
                        out["subtitleFileName"] = f.name
                    }
                    break
                }
            }
        }
        return out
    }

    private fun extractEmbedded(uri: Uri, isAudio: Boolean, out: HashMap<String, Any?>) {
        val r = MediaMetadataRetriever()
        try {
            if (uri.scheme == "file") r.setDataSource(uri.path) else r.setDataSource(applicationContext, uri)

            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()?.let { out["durationMs"] = it }

            if (isAudio) {
                out["title"] = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                out["artist"] = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                    ?: r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST)
                out["album"] = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
                r.embeddedPicture?.let { out["artworkBytes"] = it }
            }
        } catch (e: Throwable) {
            // A file the retriever cannot read still plays; it just has no tags.
        } finally {
            try {
                r.release()
            } catch (e: Throwable) {
            }
        }
    }

    /** A small JPEG of the video's first seconds, or null. Can be slow. */
    private fun extractVideoFrame(uri: Uri): ByteArray? {
        val r = MediaMetadataRetriever()
        try {
            if (uri.scheme == "file") r.setDataSource(uri.path) else r.setDataSource(applicationContext, uri)
            var frame: Bitmap = r.getFrameAtTime(
                1_000_000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: r.getFrameAtTime() ?: return null
            val maxW = 640
            if (frame.width > maxW) {
                val h = frame.height * maxW / frame.width
                val scaled = Bitmap.createScaledBitmap(frame, maxW, h, true)
                if (scaled !== frame) frame.recycle()
                frame = scaled
            }
            val bos = ByteArrayOutputStream()
            frame.compress(Bitmap.CompressFormat.JPEG, 80, bos)
            frame.recycle()
            return bos.toByteArray()
        } catch (e: Throwable) {
            return null
        } finally {
            try {
                r.release()
            } catch (e: Throwable) {
            }
        }
    }

    /**
     * Real filesystem path behind a content:// or file:// uri, or null.
     * Reading /proc/self/fd/N gives the path for providers backed by a real
     * file (downloads, file managers, MediaStore).
     */
    private fun realPath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path
        if (uri.scheme != "content") return null
        try {
            applicationContext.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                val target = Os.readlink("/proc/self/fd/${pfd.fd}")
                if (target.startsWith("/") &&
                    !target.startsWith("/proc") &&
                    !target.startsWith("/dev") &&
                    File(target).exists()
                ) return target
            }
        } catch (e: Throwable) {
        }
        return null
    }

    private fun readSmallText(f: File): String? {
        return try {
            if (!f.isFile || f.length() == 0L || f.length() > 5L * 1024 * 1024) null
            else String(f.readBytes(), Charsets.UTF_8)
        } catch (e: Throwable) {
            null
        }
    }

    /**
     * Every .srt/.vtt/.ass/.ssa next to the opened video, any name, same-name
     * files first. Needs a real directory listing, which Android only allows
     * with "All files access" (Dart asks for that first).
     */
    private fun scanSidecarSubtitleFiles(uri: Uri): List<Map<String, String>> {
        val real = realPath(uri) ?: return emptyList()
        val file = File(real)
        val dir = file.parentFile ?: return emptyList()
        val exts = setOf("srt", "vtt", "ass", "ssa")
        val base = file.nameWithoutExtension.lowercase()
        val subs = (dir.listFiles() ?: return emptyList())
            .filter { it.isFile && it.extension.lowercase() in exts }
            .sortedWith(
                compareBy<File>(
                    { if (it.nameWithoutExtension.lowercase().startsWith(base)) 0 else 1 },
                    { it.name.lowercase() }
                )
            )
            .take(30)
        val list = ArrayList<Map<String, String>>()
        for (s in subs) {
            val text = readSmallText(s) ?: continue
            list.add(mapOf("content" to text, "fileName" to s.name))
        }
        return list
    }

    // ───────────────────────── media_notification channel ─────────────────────────

    /** audio_service's default notification id. */
    private val mediaNotificationId = 1124

    private fun applyMediaNotificationOngoing(ongoing: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            var changed = false
            for (sbn in nm.activeNotifications) {
                if (sbn.id != mediaNotificationId) continue
                val n = sbn.notification
                val isOngoing = n.flags and android.app.Notification.FLAG_ONGOING_EVENT != 0
                if (isOngoing == ongoing) continue
                n.flags = if (ongoing) {
                    n.flags or android.app.Notification.FLAG_ONGOING_EVENT
                } else {
                    n.flags and android.app.Notification.FLAG_ONGOING_EVENT.inv()
                }
                nm.notify(sbn.id, n)
                changed = true
            }
            changed
        } catch (e: Throwable) {
            false
        }
    }
}