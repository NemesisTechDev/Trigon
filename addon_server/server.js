'use strict';
/**
 * Namesis addon server — speaks the Stremio addon protocol so the app can
 * treat it exactly like any other addon.
 *
 *   GET /manifest.json
 *   GET /stream/{type}/{id}.json      type = movie | series
 *   GET /subtitles/{type}/{id}.json
 *   GET /media/{key}                  range-capable file serving for the
 *                                     "library" provider (only files you
 *                                     listed in library.json, never paths)
 *   GET /health
 *
 * ids:  movie   -> "tt1254207"  or "tmdb:10378"
 *       series  -> "tt0944947:1:2"  or "tmdb:1399:1:2"   (show:season:episode)
 *
 * What it plays is decided entirely by the providers in ./providers.
 * Add one by exporting { name, getStreams(ctx), getSubtitles?(ctx) }.
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');
const providers = require('./providers');

const PORT = Number(process.env.PORT || 7000);
const ADDON_ID = 'com.namesis.addon';

function parseId(rawId) {
  const id = decodeURIComponent(rawId);
  const parts = id.split(':');
  let base, season = null, episode = null;
  if (parts[0] === 'tmdb') {
    base = `tmdb:${parts[1]}`;
    if (parts.length >= 4) { season = Number(parts[2]); episode = Number(parts[3]); }
  } else {
    base = parts[0];
    if (parts.length >= 3) { season = Number(parts[1]); episode = Number(parts[2]); }
  }
  return {
    id,
    baseId: base,
    imdbId: base.startsWith('tt') ? base : null,
    tmdbId: base.startsWith('tmdb:') ? base.slice(5) : null,
    season,
    episode,
  };
}

function origin(req) {
  if (process.env.PUBLIC_URL) return process.env.PUBLIC_URL.replace(/\/$/, '');
  return `http://${req.headers.host}`;
}

function send(res, status, body, headers = {}) {
  const isObj = typeof body === 'object' && !Buffer.isBuffer(body);
  res.writeHead(status, {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': '*',
    'Content-Type': isObj ? 'application/json; charset=utf-8' : 'text/plain; charset=utf-8',
    ...headers,
  });
  res.end(isObj ? JSON.stringify(body) : body);
}

function manifest() {
  return {
    id: ADDON_ID,
    version: '1.0.0',
    name: 'Namesis Addon',
    description: 'Stream resolver for Namesis Prime.',
    resources: ['stream', 'subtitles'],
    types: ['movie', 'series'],
    idPrefixes: ['tt', 'tmdb:'],
    catalogs: [],
    behaviorHints: { configurable: false },
  };
}

function serveFile(req, res, filePath, mime) {
  fs.stat(filePath, (err, stat) => {
    if (err || !stat.isFile()) return send(res, 404, { error: 'file not found' });
    const range = req.headers.range;
    const base = {
      'Access-Control-Allow-Origin': '*',
      'Content-Type': mime || 'application/octet-stream',
      'Accept-Ranges': 'bytes',
    };
    if (!range) {
      res.writeHead(200, { ...base, 'Content-Length': stat.size });
      return fs.createReadStream(filePath).pipe(res);
    }
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!m) { res.writeHead(416, { ...base, 'Content-Range': `bytes */${stat.size}` }); return res.end(); }
    let start = m[1] === '' ? stat.size - Number(m[2]) : Number(m[1]);
    let end = m[1] === '' || m[2] === '' ? stat.size - 1 : Number(m[2]);
    end = Math.min(end, stat.size - 1);
    if (!(start >= 0) || start > end) { res.writeHead(416, { ...base, 'Content-Range': `bytes */${stat.size}` }); return res.end(); }
    res.writeHead(206, {
      ...base,
      'Content-Range': `bytes ${start}-${end}/${stat.size}`,
      'Content-Length': end - start + 1,
    });
    fs.createReadStream(filePath, { start, end }).pipe(res);
  });
}

const MIME = {
  '.mp4': 'video/mp4', '.m4v': 'video/mp4', '.mkv': 'video/x-matroska',
  '.webm': 'video/webm', '.mov': 'video/quicktime', '.avi': 'video/x-msvideo',
  '.ts': 'video/mp2t', '.srt': 'application/x-subrip', '.vtt': 'text/vtt',
};

const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') return send(res, 204, '');
  const url = new URL(req.url, origin(req));
  const p = url.pathname;
  try {
    if (p === '/' || p === '/health') return send(res, 200, { ok: true, addon: ADDON_ID });
    if (p === '/manifest.json') return send(res, 200, manifest());

    let m = /^\/(stream|subtitles)\/(movie|series)\/(.+)\.json$/.exec(p);
    if (m) {
      const [, resource, type, rawId] = m;
      const ctx = { type, ...parseId(rawId), origin: origin(req) };
      const key = resource === 'stream' ? 'getStreams' : 'getSubtitles';
      const results = await Promise.all(
        providers.map(async (prov) => {
          if (typeof prov[key] !== 'function') return [];
          try { return (await prov[key](ctx)) || []; }
          catch (e) { console.error(`[${prov.name}] ${key} failed:`, e.message); return []; }
        })
      );
      const flat = results.flat();
      return send(res, 200, resource === 'stream' ? { streams: flat } : { subtitles: flat });
    }

    m = /^\/media\/(.+)$/.exec(p);
    if (m) {
      const file = providers.libraryFileFor(decodeURIComponent(m[1]));
      if (!file) return send(res, 404, { error: 'unknown media key' });
      return serveFile(req, res, file, MIME[path.extname(file).toLowerCase()]);
    }

    send(res, 404, { error: 'not found' });
  } catch (e) {
    console.error(e);
    send(res, 500, { error: 'internal error' });
  }
});

if (require.main === module) {
  server.listen(PORT, '0.0.0.0', () => {
    console.log(`Namesis addon listening on :${PORT}`);
    console.log(`Install in the app with:  http://<this-machine-LAN-IP>:${PORT}/manifest.json`);
  });
}
module.exports = { server, parseId };
