import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../services/parental/parental_controls.dart';
import 'virtual_catalog.dart';
import 'virtual_collection_discovery.dart';
import 'virtual_collection_favorites.dart';

// Top level so compute() can run it in a background isolate. Parameter is
// `Object` (not a typed Map): generics are lost when a message crosses an
// isolate boundary.
String _encodeJson(Object data) => jsonEncode(data);

/// Who is "signed in". The login screen is a placeholder, so this is only a
/// display name.
class VirtualSession {
  VirtualSession._();
  static String username = 'Guest';
}

/// Answers the requests the original screens send to a Jellyfin server,
/// using TMDB data, so no real server is involved. Installed as the Dio
/// adapter in `JellyfinClient.init()`.
class VirtualJellyfinAdapter implements HttpClientAdapter {
  static final RegExp _users = RegExp(r'^/Users/[^/]+(/.*)?$');

  @override
  Future<ResponseBody> fetch(
      RequestOptions options,
      Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture,
      ) async {
    final method = options.method.toUpperCase();
    final path = options.uri.path;
    final q = <String, String>{
      for (final e in options.uri.queryParameters.entries) e.key: e.value,
    };

    try {
      final result = await _route(method, path, q, options.data);
      if (result == null) return _empty(404);
      if (result == _noContent) return _empty(204);
      return await _json(result, 200);
    } on ParentalBlockedException catch (e) {
      // Blocked by Parental Controls: an ordinary "forbidden" to the screens.
      return _json({'error': e.decision.message, 'Restricted': true}, 403);
    } catch (e, st) {
      debugPrint('[VirtualJellyfin] $method $path failed: $e\n$st');
      return _json({'error': e.toString()}, 500);
    }
  }

  static const Object _noContent = Object();

  Future<Object?> _route(
      String method,
      String path,
      Map<String, String> q,
      dynamic body,
      ) async {
    final limit = int.tryParse(q['Limit'] ?? '');

    // ---- not tied to a user ----
    if (path == '/System/Info/Public' || path == '/System/Info') {
      return {
        'ServerName': 'Namesis Prime',
        'Version': '10.9.0',
        'Id': VirtualCatalog.serverId,
        'LocalAddress': 'http://namesis.local',
      };
    }
    if (path == '/Users/AuthenticateByName') {
      return {
        'AccessToken': 'namesis',
        'ServerId': VirtualCatalog.serverId,
        'User': {
          'Id': VirtualCatalog.userId,
          'Name': VirtualSession.username,
        },
      };
    }
    if (path == '/Localization/ParentalRatings') return <dynamic>[];
    if (path.startsWith('/MediaSegments/')) return {'Items': <dynamic>[]};
    if (path.startsWith('/Persons')) {
      // NAMESIS PRIME: the Search screen's Cast & Crew results.
      final term = (q['SearchTerm'] ?? '').trim();
      if (path == '/Persons' && term.isNotEmpty) {
        final people = await VirtualCatalog.searchPeople(term,
            limit: limit ?? 30);
        return {'Items': people, 'TotalRecordCount': people.length};
      }
      if (path == '/Persons' &&
          (q['Filters'] ?? '').toLowerCase().contains('isfavorite')) {
        final people = await VirtualCatalog.favoritePeople(limit ?? 50);
        return {'Items': people, 'TotalRecordCount': people.length};
      }
      return {'Items': <dynamic>[], 'TotalRecordCount': 0};
    }

    final similar = RegExp(r'^/Items/([^/]+)/Similar$').firstMatch(path);
    if (similar != null) {
      final similarId = similar.group(1)!;
      // NAMESIS PRIME: a collection's "More Like This" is other collections
      // with similar genres; VirtualCatalog.similar only knows movies/shows.
      final forCollection = VId.parse(similarId).kind == 'collection';
      final items = forCollection
          ? await VirtualCollectionDiscovery.similar(similarId)
          : await VirtualCatalog.similar(similarId);
      final n = limit ?? items.length;
      final reply = {
        'Items': items.take(n).toList(),
        'TotalRecordCount': items.length,
      };
      if (forCollection) {
        // Same as every other BoxSet list: hearts show the real state.
        return VirtualCollectionFavorites.markFavorites(reply);
      }
      return reply;
    }

    final seasons = RegExp(r'^/Shows/([^/]+)/Seasons$').firstMatch(path);
    if (seasons != null) {
      final items = await VirtualCatalog.seasonsOf(seasons.group(1)!);
      return {'Items': items, 'TotalRecordCount': items.length};
    }

    final episodes = RegExp(r'^/Shows/([^/]+)/Episodes$').firstMatch(path);
    if (episodes != null) {
      final items =
      await VirtualCatalog.episodesOf(episodes.group(1)!, q['SeasonId']);
      return {'Items': items, 'TotalRecordCount': items.length};
    }

    // NAMESIS PRIME: the collection (BoxSet) a movie belongs to, from TMDB's
    // `belongs_to_collection`. {"Collection": null} when it is in none.
    final parentCollection =
    RegExp(r'^/Items/([^/]+)/ParentCollection$').firstMatch(path);
    if (parentCollection != null) {
      return VirtualCollectionFavorites.markFavorites({
        'Collection':
        await VirtualCatalog.collectionForItem(parentCollection.group(1)!),
      });
    }

    final bareItem = RegExp(r'^/Items/([^/]+)$').firstMatch(path);
    if (bareItem != null && method == 'GET') {
      return VirtualCollectionFavorites.markFavorites(
          await VirtualCatalog.item(bareItem.group(1)!));
    }

    // ---- /Users/{id}/... ----
    final um = _users.firstMatch(path);
    if (um != null) {
      final rest = um.group(1) ?? '';

      if (rest.isEmpty) {
        return {
          'Id': VirtualCatalog.userId,
          'Name': VirtualSession.username,
          'ServerId': VirtualCatalog.serverId,
          'HasPassword': false,
          'Policy': {
            'IsAdministrator': false,
            'EnableAllFolders': true,
            'EnableMediaPlayback': true,
          },
          'Configuration': <String, dynamic>{},
        };
      }

      if (rest == '/Views') {
        return {'Items': await VirtualCatalog.views()};
      }
      if (rest == '/Items/Resume') {
        return {'Items': await VirtualCatalog.resume(limit ?? 30)};
      }
      if (rest == '/Items/Latest') {
        return VirtualCatalog.latest(q['ParentId'], limit ?? 20);
      }
      if (rest == '/Items') {
        return _items(q, limit);
      }

      final fav = RegExp(r'^/FavoriteItems/([^/]+)$').firstMatch(rest);
      if (fav != null) {
        final on = method == 'POST';
        final favId = fav.group(1)!;
        if (VirtualCollectionFavorites.isCollectionId(favId)) {
          // NAMESIS PRIME: favorite collections (BoxSets).
          await VirtualCollectionFavorites.setFavorite(favId, on);
        } else {
          await VirtualCatalog.setFavorite(favId, on);
        }
        return {'IsFavorite': on};
      }

      final userData =
      RegExp(r'^/Items/([^/]+)/UserData$').firstMatch(rest);
      if (userData != null) {
        // The only caller that matters sets the position to 0 to drop an
        // item from Continue Watching.
        if (method == 'POST') {
          await VirtualCatalog.removeFromResume(userData.group(1)!);
        }
        return _noContent;
      }

      final one = RegExp(r'^/Items/([^/]+)$').firstMatch(rest);
      if (one != null && method == 'GET') {
        return VirtualCollectionFavorites.markFavorites(
            await VirtualCatalog.item(one.group(1)!));
      }

      // Played / unplayed marks and similar user-state writes.
      if (method != 'GET') return _noContent;
    }

    // Anything else: reads get an empty list, writes succeed quietly (this
    // covers Sessions/Playing progress reports and similar).
    if (method == 'GET') {
      return {'Items': <dynamic>[], 'TotalRecordCount': 0};
    }
    return _noContent;
  }

  /// `GET /Users/{id}/Items`. NAMESIS PRIME: favorite collections (BoxSets)
  /// are added to a favorites query that asks for BoxSets, and every BoxSet
  /// in the answer carries its real favorite state.
  Future<Object?> _items(Map<String, String> q, int? limit) async {
    Map<String, dynamic> result;
    if (VirtualCollectionDiscovery.handles(q)) {
      // NAMESIS PRIME: the Collections grid, with its own bigger list and
      // New / Popular / Rating / A-Z sorts. Falls back to the plain answer
      // if that ever fails, so the grid is never left empty by it.
      try {
        result = await VirtualCollectionDiscovery.grid(q);
      } catch (e, st) {
        debugPrint('[VirtualJellyfin] collections grid failed: $e\n$st');
        result = await VirtualCatalog.items(q);
      }
    } else {
      result = await VirtualCatalog.items(q);
    }
    final filters = (q['Filters'] ?? '').toLowerCase();
    final include = (q['IncludeItemTypes'] ?? '').toLowerCase();
    if (filters.contains('isfavorite') && include.contains('boxset')) {
      final cols = await VirtualCatalog.filterCollectionMaps(
          await VirtualCollectionFavorites.favoriteItems(limit: limit));
      if (cols.isNotEmpty) {
        final existing = (result['Items'] as List?) ?? const [];
        final merged = [...existing, ...cols];
        return VirtualCollectionFavorites.markFavorites({
          ...result,
          'Items': merged,
          'TotalRecordCount': merged.length,
        });
      }
    }
    return VirtualCollectionFavorites.markFavorites(result);
  }

  /// Lists at least this long are serialised in a background isolate: this
  /// "server" runs inside the app, so a 100-500 item grid used to be
  /// jsonEncode'd on the UI thread in one long frame-dropping chunk.
  static const int _isolateEncodeMinItems = 40;

  static Future<String> _encode(Object data) async {
    final items = data is Map ? data['Items'] : data;
    if (items is List && items.length >= _isolateEncodeMinItems) {
      try {
        return await compute(_encodeJson, data);
      } catch (_) {
        // Not sendable to an isolate (e.g. custom toJson objects): fall
        // through to the plain in-line encode.
      }
    }
    return jsonEncode(data);
  }

  Future<ResponseBody> _json(Object data, int status) async {
    return ResponseBody.fromString(
      await _encode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  ResponseBody _empty(int status) => ResponseBody.fromString('', status);

  @override
  void close({bool force = false}) {}
}