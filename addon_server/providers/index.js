'use strict';
const library = require('./library');
const openMovies = require('./open_movies');

// Order = display order inside each addon response. Add your own here.
const providers = [library, openMovies];

providers.libraryFileFor = library.fileFor;
module.exports = providers;
