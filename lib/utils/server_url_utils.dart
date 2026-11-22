/// Normalizes a user-entered Jellyfin server address into a full URL.
///
/// Jellyfin servers reached over a local network (an IP address like
/// `192.168.1.5:8096`, or `localhost`) essentially never have TLS set
/// up, while servers reached by a domain name are usually fronted by a
/// reverse proxy that does. So when no scheme is typed, this defaults
/// to `http://` for bare IP/localhost addresses and `https://` for
/// everything else — instead of always assuming `https://`, which
/// silently breaks plain-http local/offline servers.
class ServerUrlUtils {
  static final RegExp _ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');

  static String normalize(String input) {
    String url = input.trim();

    if (url.isEmpty) return url;

    if (!url.startsWith("http://") && !url.startsWith("https://")) {
      url = "${_defaultScheme(url)}://$url";
    }

    if (url.endsWith("/")) {
      url = url.substring(0, url.length - 1);
    }

    return url;
  }

  static String _defaultScheme(String schemeless) {
    final host = _hostOf(schemeless);
    final isLocal = host == "localhost" ||
        host.endsWith(".local") ||
        _ipv4.hasMatch(host) ||
        (host.startsWith('[') && host.endsWith(']')); // IPv6 literal
    return isLocal ? "http" : "https";
  }

  /// Extracts just the host portion from a scheme-less address like
  /// "192.168.1.5:8096/foo" or "myserver.example.com".
  static String _hostOf(String schemeless) {
    final withoutPath = schemeless.split('/').first;
    if (withoutPath.startsWith('[')) {
      // IPv6 literal, e.g. "[::1]:8096"
      final end = withoutPath.indexOf(']');
      return end == -1 ? withoutPath : withoutPath.substring(0, end + 1);
    }
    return withoutPath.split(':').first;
  }
}
