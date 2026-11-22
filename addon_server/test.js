'use strict';
// Self-contained test: boots the server on a random port and exercises it.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const http = require('http');

fs.mkdirSync(path.join(__dirname, 'media'), { recursive: true });
const tmp = path.join(__dirname, 'media', '_test.mp4');
fs.writeFileSync(tmp, Buffer.from('0123456789abcdefghij'));
const subFile = path.join(__dirname, 'media', '_test.srt');
fs.writeFileSync(subFile, '1\n00:00:01,000 --> 00:00:02,000\nhi\n');
const libFile = path.join(__dirname, '_test_library.json');
fs.writeFileSync(libFile, JSON.stringify({
  movies: { tt9999999: { file: 'media/_test.mp4', title: 'Test Movie', quality: '1080p' },
            'tmdb:42': { url: 'https://example.com/x.mp4' } },
  series: { 'tt8888888:2:3': { file: 'media/_test.mp4' } },
  subtitles: { tt9999999: [{ lang: 'eng', file: 'media/_test.srt' }] },
}));
process.env.LIBRARY_FILE = libFile;

const { server } = require('./server');

function get(port, p, headers = {}) {
  return new Promise((resolve, reject) => {
    http.get({ port, path: p, headers, host: '127.0.0.1' }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString() }));
    }).on('error', reject);
  });
}

server.listen(0, '127.0.0.1', async () => {
  const port = server.address().port;
  let failed = false;
  try {
    let r = await get(port, '/manifest.json');
    assert.strictEqual(r.status, 200);
    const mf = JSON.parse(r.body);
    assert.ok(mf.resources.includes('stream') && mf.types.includes('series'));

    r = await get(port, '/stream/movie/tt1254207.json');
    let s = JSON.parse(r.body).streams;
    assert.ok(s.length === 1 && s[0].url.endsWith('BigBuckBunny.mp4'), 'open-movies imdb');

    r = await get(port, '/stream/movie/tmdb%3A10378.json');
    s = JSON.parse(r.body).streams;
    assert.ok(s.length === 1, 'open-movies tmdb id');

    r = await get(port, '/stream/movie/tt9999999.json');
    s = JSON.parse(r.body).streams;
    assert.strictEqual(s.length, 1);
    assert.ok(s[0].url.startsWith(`http://127.0.0.1:${port}/media/`), 'library file url is absolute');
    assert.ok(s[0].title.includes('1080p'));

    // range serving
    const mediaPath = new URL(s[0].url).pathname;
    r = await get(port, mediaPath, { Range: 'bytes=2-5' });
    assert.strictEqual(r.status, 206);
    assert.strictEqual(r.body, '2345');
    assert.strictEqual(r.headers['content-range'], 'bytes 2-5/20');
    r = await get(port, mediaPath, { Range: 'bytes=-4' });
    assert.strictEqual(r.body, 'ghij');
    r = await get(port, mediaPath);
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.body.length, 20);
    r = await get(port, mediaPath, { Range: 'bytes=50-60' });
    assert.strictEqual(r.status, 416);

    // series
    r = await get(port, '/stream/series/tt8888888%3A2%3A3.json');
    assert.strictEqual(JSON.parse(r.body).streams.length, 1, 'series episode');
    r = await get(port, '/stream/series/tt8888888%3A2%3A4.json');
    assert.strictEqual(JSON.parse(r.body).streams.length, 0, 'wrong episode empty');

    // direct url entry
    r = await get(port, '/stream/movie/tmdb%3A42.json');
    assert.strictEqual(JSON.parse(r.body).streams[0].url, 'https://example.com/x.mp4');

    // unknown -> empty, not error
    r = await get(port, '/stream/movie/tt0000001.json');
    assert.deepStrictEqual(JSON.parse(r.body).streams, []);

    // subtitles
    r = await get(port, '/subtitles/movie/tt9999999.json');
    const subs = JSON.parse(r.body).subtitles;
    assert.strictEqual(subs.length, 1);
    r = await get(port, new URL(subs[0].url).pathname);
    assert.ok(r.body.includes('hi'));

    // no path traversal: unknown key 404
    r = await get(port, '/media/' + Buffer.from('/etc/passwd').toString('base64url'));
    assert.strictEqual(r.status, 404);

    console.log('ALL ADDON SERVER TESTS PASSED');
  } catch (e) {
    failed = true;
    console.error('TEST FAILED:', e.message);
  } finally {
    server.close();
    for (const f of [tmp, subFile, libFile]) try { fs.unlinkSync(f); } catch {}
    process.exit(failed ? 1 : 0);
  }
});
