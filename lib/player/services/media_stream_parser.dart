import '../../services/jellyfin_services/jellyfin_client.dart';
import '../models/audio_track.dart';
import '../models/subtitle_track.dart';

class MediaStreamParser {
  /// [itemId]/[mediaSourceId] are only needed to build the extraction URL
  /// used as a fallback below when Jellyfin hasn't handed us a
  /// [DeliveryUrl] directly.
  static List<SubtitleTrack> subtitles(
    List<dynamic>? streams, {
    String? itemId,
    String? mediaSourceId,
  }) {
    if (streams == null) return [];

    return streams
        .where((e) => e["Type"] == "Subtitle")
        .map(
          (e) {
        final isExternal = e["IsExternal"] == true;
        final deliveryUrl = e["DeliveryUrl"] as String?;
        final index = e["Index"];

        // `DeliveryUrl` is only ever populated by Jellyfin during
        // /PlaybackInfo's device-profile negotiation — this app fetches
        // items through the plain /Items list/detail endpoints (see
        // MediaService.getItems etc.), which return MediaStreams
        // without it, for external *and* embedded subtitles alike. So
        // this is realistically always null here regardless of
        // isExternal — kept as the preferred source in case a future
        // caller does route through PlaybackInfo.
        String? url = deliveryUrl != null
            ? "${JellyfinClient.serverUrl}$deliveryUrl"
                "${deliveryUrl.contains('?') ? '&' : '?'}"
                "api_key=${JellyfinClient.token}"
            : null;

        // Fallback: Jellyfin's per-stream extraction endpoint —
        // `/Videos/{itemId}/{mediaSourceId}/Subtitles/{index}/{startPositionTicks}/Stream.{format}`
        // (`0` for startPositionTicks, since this always requests the
        // subtitle from the start of the file; mpv syncs it against
        // playback position locally from there). This works for *any*
        // text-based subtitle stream Jellyfin can serve/convert —
        // embedded (srt/ass/ssa/mov_text/...) and external sidecar
        // files alike, gated only on `IsTextSubtitleStream`, not on
        // `isExternal`. Restricting this to embedded-only previously
        // meant a genuinely external sidecar subtitle (no DeliveryUrl,
        // and never demuxed by mpv either, so no real native track id
        // to fall back on) ended up with no way to load at all —
        // selection still "succeeded" in the UI, silently selecting a
        // placeholder id mpv had no matching track for. Image-based
        // tracks (PGS/VobSub) don't set `IsTextSubtitleStream` and
        // keep relying on native id selection below, which is the
        // correct (only) option for those.
        if (url == null &&
            e["IsTextSubtitleStream"] == true &&
            itemId != null &&
            mediaSourceId != null) {
          url = "${JellyfinClient.serverUrl}"
              "/Videos/$itemId/$mediaSourceId/Subtitles/$index/0/Stream.vtt"
              "?api_key=${JellyfinClient.token}";
        }

        return SubtitleTrack(
          index: index,
          language: e["Language"] ?? "Unknown",
          displayTitle:
          e["DisplayTitle"] ??
              e["Title"] ??
              "Subtitle",
          isDefault: e["IsDefault"] ?? false,
          isForced: e["IsForced"] ?? false,
          // Placeholder — PlayerManager fills in the real mpv track id once
          // the player has reported its native tracks for this file. Only
          // actually used as a fallback when there's no fetchable [url].
          nativeId: "$index",
          isExternal: isExternal,
          externalUrl: url,
        );
      },
    )
        .toList();
  }

  static List<AudioTrack> audio(List<dynamic>? streams) {
    if (streams == null) return [];

    return streams
        .where((e) => e["Type"] == "Audio")
        .map(
          (e) => AudioTrack(
        index: e["Index"],
        language: e["Language"] ?? "Unknown",
        displayTitle:
        e["DisplayTitle"] ??
            e["Title"] ??
            "Audio",
        isDefault: e["IsDefault"] ?? false,
        nativeId: "${e["Index"]}",
      ),
    )
        .toList();
  }
}