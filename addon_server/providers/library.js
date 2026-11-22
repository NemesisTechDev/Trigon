'use strict';
/**
 * Provider for media YOU own: video files on this machine, or direct URLs to
 * your own storage. Describe them in library.json:
 *
 * {
 *   "movies": {
 *     "tt1254207":  { "file": "media/bbb.mp4", "title": "Big Buck Bunny", "quality": "1080p" },
 *     "tmdb:10378": { "url": "https://my-storage.example.com/bbb.mp4" }
 *   },
 *   "series": {
 *     "tt0000000:1:1": { "file": "media/show/s01e01.mkv" }
 *   },
 *   "subtitles": {
 *     "tt1254207": [ { "lang": "eng", "file": "media/bbb.en.srt" } ]
 *   }
 * }
 *
 * Files are only ever served by key — nothing outside library.json can be
 * requested, and "file" paths are resolved relative to this folder's parent.
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const LIB_PATH = process.env.LIBRARY_FILE || path.join(ROOT, 'library.json');

function load() {
  try { return JSON.parse(fs.readFileSync(LIB_PATH, 'utf8')); }
  catch { return { movies: {}, series: {}, subtitles: {} }; }
}

// A key is just the base64url of the absolute path. It is only honoured if
// that exact file is currently listed in library.json, so it survives server
// restarts but can never be used to read anything you haven't listed.
function register(file) {
  return Buffer.from(path.resolve(ROOT, file)).toString('base64url');
}

function listedFiles(lib) {
  const out = new Set();
  const add = (e) => { if (e && e.file) out.add(path.resolve(ROOT, e.file)); };
  Object.values(lib.movies || {}).forEach(add);
  Object.values(lib.series || {}).forEach(add);
  Object.values(lib.subtitles || {}).forEach((arr) => (arr || []).forEach(add));
  return out;
}

function fileFor(key) {
  let abs;
  try { abs = Buffer.from(key, 'base64url').toString('utf8'); } catch { return null; }
  return listedFiles(load()).has(abs) ? abs : null;
}

function entryFor(lib, ctx) {
  const table = ctx.type === 'movie' ? lib.movies : lib.series;
  if (!table) return null;
  const suffix = ctx.type === 'series' && ctx.season != null ? `:${ctx.season}:${ctx.episode}` : '';
  return table[`${ctx.baseId}${suffix}`] || null;
}

module.exports = {
  name: 'library',
  fileFor,

  async getStreams(ctx) {
    const entry = entryFor(load(), ctx);
    if (!entry) return [];
    const label = entry.title || 'My Library';
    const detail = [entry.quality, entry.note].filter(Boolean).join(' · ');
    if (entry.url) {
      return [{ name: 'My Library', title: `${label}${detail ? '\n' + detail : ''}`, url: entry.url }];
    }
    if (entry.file) {
      const abs = path.resolve(ROOT, entry.file);
      if (!fs.existsSync(abs)) return [];
      const key = register(entry.file);
      return [{
        name: 'My Library',
        title: `${label}${detail ? '\n' + detail : ''}`,
        url: `${ctx.origin}/media/${key}`,
      }];
    }
    return [];
  },

  async getSubtitles(ctx) {
    const subs = (load().subtitles || {})[ctx.baseId] || [];
    return subs
      .filter((s) => s.file && fs.existsSync(path.resolve(ROOT, s.file)))
      .map((s, i) => ({
        id: `lib-${i}`,
        lang: s.lang || 'eng',
        url: `${ctx.origin}/media/${register(s.file)}`,
      }));
  },
};
