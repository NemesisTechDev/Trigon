package com.nemesistech.trigon

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.util.Log
import android.view.KeyEvent
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.Arrays
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Ad blocker for the "Embed servers" web player, and for that player ONLY.
 *
 * How it is scoped: [install] puts an [EmbedAdBlockClient] on the one WebView
 * that Dart's EmbedPlayerScreen created. Nothing here is process-wide: the
 * trailer WebView, Dio, media_kit, Firebase / Google sign-in and every other
 * network call in the app never see this code.
 *
 * What it does: every sub-resource request the embed page makes (scripts,
 * iframes, images, XHR, ...) is checked against a host blocklist. A blocked
 * request gets an empty 403 answer and never leaves the phone. This is the
 * same thing a DNS ad blocker (dns.adguard.com) does, only done inside the
 * app: a host on the AdGuard DNS filter cannot be reached, so its ads never
 * load.
 *
 * Block data:
 *  - [BUILTIN]: a small list of well-known ad networks, always active, so the
 *    very first embed playback is already covered.
 *  - the official AdGuard DNS filter (the list dns.adguard.com itself uses),
 *    downloaded in the background into the app's private storage, refreshed
 *    weekly, and read from the cached copy afterwards. If the download ever
 *    fails, the previous copy (or just BUILTIN) keeps working.
 *
 * Never blocked: the main frame (our own page, navigations are handled by the
 * Dart NavigationDelegate), `localhost`, and the player pages' own hosts
 * (exact host match, [NEVER_BLOCK]), so a list mistake can't take the player
 * itself down.
 */
object EmbedAdBlocker {
    private const val TAG = "EmbedAdBlock"

    /** The AdGuard DNS filter, as served by AdGuard's own hostlists registry. */
    private const val LIST_URL =
        "https://raw.githubusercontent.com/AdguardTeam/HostlistsRegistry/main/assets/filter_1.txt"
    private const val LIST_DIR = "embed_adblock"
    private const val LIST_FILE = "adguard_dns.txt"
    private const val MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
    private const val MAX_DOWNLOAD_BYTES = 40L * 1024 * 1024

    /** A real copy of the list has ~190k rules; anything far below is a bad download. */
    private const val MIN_RULES = 50_000

    /** Exact hosts that are never blocked (subdomains are still filtered). */
    private val NEVER_BLOCK = setOf(
        "localhost",
        "vidfast.pro", "vidfast.in", "vidfast.io", "vidfast.me", "vidfast.net",
        "vidfast.pm", "vidfast.xyz", "vidfast.vc", "vidfast.bz",
        "vidlink.pro",
        "vidsrc.mov",
    )

    /** Well-known ad networks. Blocked with all their subdomains. */
    private val BUILTIN_HOSTS = arrayOf(
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com",
        "popads.net", "popcash.net", "propellerads.com", "exoclick.com",
        "exosrv.com", "juicyads.com", "adsterra.com", "onclickads.net",
        "clickadu.com", "hilltopads.net", "trafficjunky.net", "adcash.com",
        "a-ads.com", "ad-maven.com", "admaven.com", "taboola.com",
        "outbrain.com", "criteo.com", "pubmatic.com", "rubiconproject.com",
        "tsyndicate.com", "adsco.re",
    )
    private val BUILTIN: LongArray =
        LongArray(BUILTIN_HOSTS.size) { hash(BUILTIN_HOSTS[it], 0, BUILTIN_HOSTS[it].length) }
            .also { it.sort() }

    /**
     * Parsed list. Hosts are kept as sorted 64-bit hashes (190k rules take
     * about 1.5 MB this way, against ~20 MB as strings). A false match needs a
     * 64-bit collision, which for this list size is ~1e-14 per lookup.
     */
    private class Rules(
        val blocked: LongArray,
        val important: LongArray,
        val allowed: LongArray,
    ) {
        val size: Int get() = blocked.size + important.size
    }

    private val EMPTY = Rules(LongArray(0), LongArray(0), LongArray(0))

    @Volatile
    private var rules: Rules = EMPTY

    @Volatile
    private var loadedFromDisk = false
    private val updating = AtomicBoolean(false)
    private val blockedTotal = AtomicInteger(0)

    fun blockedCount(): Int = blockedTotal.get()

    // ---------------------------------------------------------------- install

    /**
     * Puts the blocker on [webView], keeping its current client (the
     * webview_flutter one, which carries Dart's NavigationDelegate) working
     * exactly as before. Safe to call repeatedly. Returns false when the
     * blocker could not be installed (Android older than 8.0 can't read the
     * existing client back).
     */
    fun install(webView: WebView, enabled: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val current = webView.webViewClient
        if (current is EmbedAdBlockClient) {
            current.enabled = enabled
            return true
        }
        webView.webViewClient = EmbedAdBlockClient(current, enabled)
        return true
    }

    // ------------------------------------------------------------- matching

    internal fun shouldBlock(scheme: String?, rawHost: String?): Boolean {
        if (scheme != "https" && scheme != "http") return false
        if (rawHost.isNullOrEmpty()) return false
        val host = rawHost.trimEnd('.').lowercase()
        if (host.isEmpty() || host in NEVER_BLOCK) return false
        val r = rules
        if (anySuffix(host, BUILTIN)) return true
        if (anySuffix(host, r.important)) return true
        if (anySuffix(host, r.allowed)) return false
        return anySuffix(host, r.blocked)
    }

    /**
     * True when [host] or any parent domain of it (never the bare TLD) is in
     * [set]: `a.b.example.com` checks itself, `b.example.com`, `example.com`.
     */
    private fun anySuffix(host: String, set: LongArray): Boolean {
        if (set.isEmpty()) return false
        var start = 0
        while (true) {
            if (Arrays.binarySearch(set, hash(host, start, host.length)) >= 0) return true
            val dot = host.indexOf('.', start)
            if (dot < 0) return false
            start = dot + 1
            if (host.indexOf('.', start) < 0) return false // only the TLD is left
        }
    }

    /** FNV-1a, 64 bit, over the (already lower-cased, ASCII) host text. */
    private fun hash(s: CharSequence, from: Int, to: Int): Long {
        var h = -3750763034362895579L // 0xcbf29ce484222325
        for (i in from until to) {
            h = h xor s[i].code.toLong()
            h *= 1099511628211L // 0x100000001b3
        }
        return h
    }

    internal fun blockedResponse(): WebResourceResponse {
        blockedTotal.incrementAndGet()
        return WebResourceResponse(
            "text/plain",
            "UTF-8",
            403,
            "Blocked",
            emptyMap(),
            ByteArrayInputStream(ByteArray(0)),
        )
    }

    // ------------------------------------------------------- list handling

    /** Loads the cached list and refreshes it when stale, off the main thread. */
    fun refreshInBackground(context: Context) {
        if (!updating.compareAndSet(false, true)) return
        val app = context.applicationContext
        Thread({
            try {
                refresh(app)
            } catch (t: Throwable) {
                Log.w(TAG, "list refresh failed: $t")
            } finally {
                updating.set(false)
            }
        }, "embed-adblock").start()
    }

    private fun refresh(context: Context) {
        val dir = File(context.filesDir, LIST_DIR).apply { mkdirs() }
        val file = File(dir, LIST_FILE)

        if (!loadedFromDisk && file.exists()) {
            val cached = parse(file)
            if (cached != null) {
                rules = cached
                Log.d(TAG, "loaded ${cached.size} rules from cache")
            } else {
                file.delete() // unreadable copy: download a fresh one below
            }
            loadedFromDisk = true
        }

        val stale = !file.exists() || System.currentTimeMillis() - file.lastModified() > MAX_AGE_MS
        if (!stale) return

        val tmp = File(dir, "$LIST_FILE.tmp")
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(LIST_URL).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 30_000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", "Trigon")
            }
            if (conn.responseCode != 200) {
                Log.w(TAG, "list download: HTTP ${conn.responseCode}")
                return
            }
            conn.inputStream.use { input ->
                tmp.outputStream().use { out -> input.copyTo(out) }
            }
            if (tmp.length() > MAX_DOWNLOAD_BYTES) {
                tmp.delete()
                return
            }
            val parsed = parse(tmp)
            if (parsed == null) {
                tmp.delete()
                Log.w(TAG, "list download: not a usable list, keeping the old one")
                return
            }
            if (file.exists()) file.delete()
            if (!tmp.renameTo(file)) {
                tmp.delete()
                return
            }
            rules = parsed
            loadedFromDisk = true
            Log.d(TAG, "downloaded list: ${parsed.size} rules")
        } catch (t: Throwable) {
            Log.w(TAG, "list download failed: $t")
            tmp.delete()
        } finally {
            conn?.disconnect()
        }
    }

    private class LongList {
        private var a = LongArray(4096)
        private var n = 0

        fun add(v: Long) {
            if (n == a.size) a = a.copyOf(n * 2)
            a[n++] = v
        }

        fun toSortedArray(): LongArray {
            val r = a.copyOf(n)
            r.sort()
            return r
        }
    }

    /**
     * Reads the AdGuard DNS filter. Understood lines:
     *   `||host^`            block host and subdomains
     *   `||host^$important`  block, and exceptions don't apply
     *   `@@||host^`          exception (allow host and subdomains)
     *   `||host^$badfilter`  cancels the matching block rule
     * Everything else (comments, regex, wildcards, other modifiers) is
     * ignored. Returns null when the file does not look like the list.
     */
    private fun parse(file: File): Rules? {
        val blocked = LongList()
        val important = LongList()
        val allowed = LongList()
        val bad = HashSet<Long>()

        file.bufferedReader(Charsets.UTF_8).useLines { lines ->
            for (raw in lines) {
                val line = raw.trim()
                if (line.length < 5 || line[0] == '!' || line[0] == '#') continue

                if (line.startsWith("||")) {
                    var body = line.substring(2)
                    var mods = ""
                    val d = body.indexOf('$')
                    if (d >= 0) {
                        mods = body.substring(d + 1)
                        body = body.substring(0, d)
                    }
                    if (!body.endsWith("^")) continue
                    val host = body.substring(0, body.length - 1).lowercase()
                    if (!validHost(host)) continue
                    val h = hash(host, 0, host.length)
                    when (mods) {
                        "" -> blocked.add(h)
                        "important" -> important.add(h)
                        "badfilter" -> bad.add(h)
                        else -> {}
                    }
                } else if (line.startsWith("@@||")) {
                    var body = line.substring(4)
                    if (body.endsWith("|")) body = body.substring(0, body.length - 1)
                    if (!body.endsWith("^")) continue
                    val host = body.substring(0, body.length - 1).lowercase()
                    if (!validHost(host)) continue
                    allowed.add(hash(host, 0, host.length))
                }
            }
        }

        var b = blocked.toSortedArray()
        var i = important.toSortedArray()
        if (bad.isNotEmpty()) {
            b = b.filter { it !in bad }.toLongArray()
            i = i.filter { it !in bad }.toLongArray()
        }
        if (b.size + i.size < MIN_RULES) return null
        return Rules(b, i, allowed.toSortedArray())
    }

    /** Plain dotted hostname: letters, digits, '-', '_', '.', at least one dot. */
    private fun validHost(h: String): Boolean {
        if (h.length < 3 || h.length > 253) return false
        if (h[0] == '.' || h[h.length - 1] == '.') return false
        var dots = 0
        for (c in h) {
            when {
                c == '.' -> dots++
                c in 'a'..'z' || c in '0'..'9' || c == '-' || c == '_' -> {}
                else -> return false
            }
        }
        return dots > 0
    }
}

/**
 * Wraps the WebViewClient webview_flutter installed and passes EVERY callback
 * through to it unchanged (that is what feeds Dart's NavigationDelegate:
 * onPageFinished, onNavigationRequest, errors, ...). The one thing it adds is
 * [shouldInterceptRequest], which webview_flutter does not expose.
 */
class EmbedAdBlockClient(
    private val inner: WebViewClient,
    @Volatile var enabled: Boolean,
) : WebViewClient() {

    /** webview_flutter ignores the favicon but declares it non-null. */
    private val blankFavicon: Bitmap by lazy {
        Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
    }

    override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
    ): WebResourceResponse? {
        if (enabled && !request.isForMainFrame) {
            val uri = request.url
            if (uri != null && EmbedAdBlocker.shouldBlock(uri.scheme, uri.host)) {
                Log.v("EmbedAdBlock", "blocked ${uri.host}")
                return EmbedAdBlocker.blockedResponse()
            }
        }
        return inner.shouldInterceptRequest(view, request)
    }

    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
        inner.onPageStarted(view, url, favicon ?: blankFavicon)
    }

    override fun onPageFinished(view: WebView, url: String) {
        inner.onPageFinished(view, url)
    }

    override fun onReceivedHttpError(
        view: WebView,
        request: WebResourceRequest,
        errorResponse: WebResourceResponse,
    ) {
        inner.onReceivedHttpError(view, request, errorResponse)
    }

    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceError,
    ) {
        inner.onReceivedError(view, request, error)
    }

    override fun shouldOverrideUrlLoading(
        view: WebView,
        request: WebResourceRequest,
    ): Boolean = inner.shouldOverrideUrlLoading(view, request)

    override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
        inner.doUpdateVisitedHistory(view, url, isReload)
    }

    override fun onReceivedHttpAuthRequest(
        view: WebView,
        handler: android.webkit.HttpAuthHandler,
        host: String,
        realm: String,
    ) {
        inner.onReceivedHttpAuthRequest(view, handler, host, realm)
    }

    override fun onFormResubmission(
        view: WebView,
        dontResend: android.os.Message,
        resend: android.os.Message,
    ) {
        inner.onFormResubmission(view, dontResend, resend)
    }

    override fun onLoadResource(view: WebView, url: String) {
        inner.onLoadResource(view, url)
    }

    override fun onPageCommitVisible(view: WebView, url: String) {
        inner.onPageCommitVisible(view, url)
    }

    override fun onReceivedClientCertRequest(
        view: WebView,
        request: android.webkit.ClientCertRequest,
    ) {
        inner.onReceivedClientCertRequest(view, request)
    }

    override fun onReceivedLoginRequest(
        view: WebView,
        realm: String,
        account: String?,
        args: String,
    ) {
        inner.onReceivedLoginRequest(view, realm, account, args)
    }

    override fun onReceivedSslError(
        view: WebView,
        handler: android.webkit.SslErrorHandler,
        error: android.net.http.SslError,
    ) {
        inner.onReceivedSslError(view, handler, error)
    }

    override fun onScaleChanged(view: WebView, oldScale: Float, newScale: Float) {
        inner.onScaleChanged(view, oldScale, newScale)
    }

    override fun onUnhandledKeyEvent(view: WebView, event: KeyEvent) {
        inner.onUnhandledKeyEvent(view, event)
    }
}
