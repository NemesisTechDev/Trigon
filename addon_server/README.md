# Namesis addon server

A tiny, dependency-free server that speaks the **Stremio addon protocol**, so Namesis Prime (or any Stremio-compatible client) can ask it "how do I play this title?".

```
node test.js     # self-test
node server.js   # PORT=7000 by default
```

## Endpoints

| Route | Purpose |
|---|---|
| `GET /manifest.json` | Describes the addon (resources: `stream`, `subtitles`; types: `movie`, `series`) |
| `GET /stream/{type}/{id}.json` | `{ "streams": [ { name, title, url, ... } ] }` |
| `GET /subtitles/{type}/{id}.json` | `{ "subtitles": [ { id, lang, url } ] }` |
| `GET /media/{key}` | Serves a file listed in `library.json`, with HTTP Range support |

IDs: movie `tt1254207` or `tmdb:10378`; episode `tt0944947:1:2` or `tmdb:1399:1:2` (show:season:episode).

## What it plays is up to its providers

`providers/index.js` lists them. Two are included:

- **`open_movies`** — openly licensed Blender Foundation films (Big Buck Bunny, Sintel, Tears of Steel, Elephants Dream) for testing the whole flow.
- **`library`** — media *you own*, described in `library.json`:

```json
{
  "movies": {
    "tt1254207":  { "file": "media/bbb.mp4", "title": "Big Buck Bunny", "quality": "1080p" },
    "tmdb:10378": { "url": "https://my-storage.example.com/bbb.mp4" }
  },
  "series": { "tt0000000:1:1": { "file": "media/show/s01e01.mkv" } },
  "subtitles": { "tt1254207": [ { "lang": "eng", "file": "media/bbb.en.srt" } ] }
}
```

Files are only served by key, and only if listed in `library.json`; arbitrary paths cannot be requested.

## Writing your own provider

```js
module.exports = {
  name: 'my-source',
  async getStreams(ctx) {
    // ctx: { type, id, baseId, imdbId, tmdbId, season, episode, origin }
    return [{ name: 'My Source', title: 'Title\n1080p · English', url: 'https://...' }];
  },
};
```

Add it to the array in `providers/index.js`. Return `[]` for titles it doesn't have; throwing is also safe (it is logged and skipped).

## Using it from your phone

Set `PUBLIC_URL=http://<LAN-IP>:7000` if the addon is behind a proxy; otherwise the URL is derived from the request's `Host` header. For use outside your home network you need to host it somewhere reachable (and put HTTPS in front of it).
