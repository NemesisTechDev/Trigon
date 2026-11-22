import 'package:dio/dio.dart';

import 'jellyfin_client.dart';
import 'storage_service.dart';

class MusicService {
  // NOT cached as `static final Dio _dio = JellyfinClient.dio` — that
  // pattern grabs whichever Dio instance happens to exist the first
  // time any MusicService method is called, then keeps that same
  // instance forever (Dart only evaluates a `static final` once, ever).
  // JellyfinClient.init()/refresh() build a brand-new Dio instance on
  // login, server switch, or account switch (see profile_settings_
  // screen.dart and auth_service.dart) and swap it into
  // JellyfinClient._dio, but a `static final` here would keep pointing
  // at the old, now-replaced instance — stale baseUrl/auth header. With
  // `validateStatus: (_) => true` on that Dio, a stale token doesn't
  // even throw; it just comes back as a non-200 with no "Items" key, so
  // `response.data["Items"] ?? []` silently resolves to an empty list.
  // That's exactly why Artists (getArtists/getFavoriteArtists/
  // searchArtists all live in this file) would work right after a
  // fresh login and then quietly go empty again later — every other
  // service reads `JellyfinClient.dio` fresh per call and never hit
  // this. A getter re-reads the current instance on every call instead.
  static Dio get _dio => JellyfinClient.dio;

  static Future<String?> _userId() async {
    return await StorageService.getUserId();
  }

  static Future<List<dynamic>> getAlbums({
    String? parentId,
    String sortBy = "SortName",
    String sortOrder = "Ascending",
  }) async {
    final userId = await _userId();

    final response = await _dio.get(
      "/Users/$userId/Items",
      queryParameters: {
        if (parentId != null) "ParentId": parentId,
        "Recursive": true,
        "IncludeItemTypes": "MusicAlbum",
        "SortBy": sortBy,
        "SortOrder": sortOrder,
        "Limit": 5000,
      },
    );

    return response.data["Items"] ?? [];
  }

  static Future<List<dynamic>> getSongs({
    String? parentId,
    String sortBy = "SortName",
    String sortOrder = "Ascending",
  }) async {
    final userId = await _userId();

    final response = await _dio.get(
      "/Users/$userId/Items",
      queryParameters: {
        if (parentId != null) "ParentId": parentId,
        "Recursive": true,
        "IncludeItemTypes": "Audio",
        "SortBy": sortBy,
        "SortOrder": sortOrder,
        "Limit": 5000,
      },
    );

    return response.data["Items"] ?? [];
  }

  static Future<List<dynamic>> getPlaylists({
    String sortBy = "SortName",
    String sortOrder = "Ascending",
  }) async {
    final userId = await _userId();

    final response = await _dio.get(
      "/Users/$userId/Items",
      queryParameters: {
        "IncludeItemTypes": "Playlist",
        "SortBy": sortBy,
        "SortOrder": sortOrder,
        "Limit": 5000,
      },
    );

    return response.data["Items"] ?? [];
  }

  static Future<List<dynamic>> getArtists({
    String? parentId,
    String sortBy = "SortName",
    String sortOrder = "Ascending",
  }) async {
    final userId = await _userId();

    final response = await _dio.get(
      "/Artists",
      queryParameters: {
        "UserId": userId,
        if (parentId != null) "ParentId": parentId,
        "SortBy": sortBy,
        "SortOrder": sortOrder,
        // Without this, Jellyfin doesn't walk into the music library's
        // folder hierarchy to collect artists and silently comes back
        // with an empty Items array — same fix MediaService.
        // getAlbumArtists() already had (via its own /Artists/
        // AlbumArtists call) that this sibling method was missing.
        "Recursive": true,
      },
    );

    return response.data["Items"] ?? [];
  }

  /// Favorited artists — Artists live under their own `/Artists`
  /// endpoint rather than the generic Items tree, so this mirrors
  /// getArtists() above with Jellyfin's IsFavorite filter instead of
  /// going through MediaService.getFavoriteItems (which wouldn't reach
  /// them at all).
  static Future<List<dynamic>> getFavoriteArtists() async {
    final userId = await _userId();

    final response = await _dio.get(
      "/Artists",
      queryParameters: {
        "UserId": userId,
        "Filters": "IsFavorite",
        "SortBy": "SortName",
        "Recursive": true,
      },
    );

    return response.data["Items"] ?? [];
  }

  /// Artists matching a search term — same /Artists endpoint as
  /// getArtists()/getFavoriteArtists(), just with SearchTerm instead of
  /// a ParentId or Filters. Kept separate from MediaService's search
  /// because Artists live outside the regular Items tree.
  static Future<List<dynamic>> searchArtists(
    String query, {
    int limit = 30,
  }) async {
    if (query.trim().isEmpty) return [];

    final userId = await _userId();

    final response = await _dio.get(
      "/Artists",
      queryParameters: {
        "UserId": userId,
        "SearchTerm": query,
        "Limit": limit,
        "Recursive": true,
      },
    );

    return response.data["Items"] ?? [];
  }
}