'use strict';
/**
 * Sample provider: openly licensed films (Blender Foundation open movies,
 * CC-BY), hosted on Google's public sample bucket. Lets you test the whole
 * app flow end to end without any content of your own.
 */
const BASE = 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample';

const CATALOG = {
  // Big Buck Bunny
  tt1254207: { title: 'Big Buck Bunny', file: 'BigBuckBunny.mp4' },
  'tmdb:10378': { title: 'Big Buck Bunny', file: 'BigBuckBunny.mp4' },
  // Elephants Dream
  tt0807840: { title: 'Elephants Dream', file: 'ElephantsDream.mp4' },
  // Sintel
  tt1727587: { title: 'Sintel', file: 'Sintel.mp4' },
  'tmdb:45745': { title: 'Sintel', file: 'Sintel.mp4' },
  // Tears of Steel
  tt2285752: { title: 'Tears of Steel', file: 'TearsOfSteel.mp4' },
};

module.exports = {
  name: 'open-movies',
  async getStreams(ctx) {
    if (ctx.type !== 'movie') return [];
    const hit = CATALOG[ctx.baseId];
    if (!hit) return [];
    return [
      {
        name: 'Open Movies',
        title: `${hit.title}\nBlender Foundation (CC-BY) · MP4`,
        url: `${BASE}/${hit.file}`,
        behaviorHints: { notWebReady: false },
      },
    ];
  },
};
