/// Whether [path] is a network URL (ordinary Jellyfin artwork) as
/// opposed to a local filesystem path (a local song's cached embedded
/// artwork, written by LocalMusicService). Every artwork call site that
/// accepts either — MediaItem.image, a song map's "ArtworkPath" — uses
/// this one check so local and network art can share the same field
/// without a separate "isLocal" flag threaded alongside every image
/// string in the app.
bool isRemoteArtwork(String path) =>
    path.startsWith('http://') || path.startsWith('https://');
