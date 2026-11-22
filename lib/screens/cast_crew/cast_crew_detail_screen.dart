import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/cache/nemesis_image_cache.dart';
import '../../services/external_metadata/tmdb_service.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../utils/app_fonts.dart';
import '../../utils/responsive.dart';
import '../../utils/bottom_clearance.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/common/artwork_ready_spinner.dart';
import '../movie_details/movie_details_screen.dart';
import '../movie_details/widgets/backdrop_header.dart';
import '../movie_details/widgets/content_row.dart';
import '../movie_details/widgets/landscape_backdrop_bg.dart';
import '../movie_details/widgets/landscape_scroll_bar.dart';
import '../movie_details/widgets/overview_section.dart';

const _gold = Color(0xffD4AF37);
const _pageBg = Color(0xff111111);

class CastCrewDetailScreen extends StatefulWidget {
  final String personId;

  /// Whatever the tapped cast/crew card already had in memory (name,
  /// role, own headshot). Same pattern as MovieDetailsScreen — paints
  /// immediately with this instead of a blank spinner, then silently
  /// swaps in the full record (bio, birth info, filmography) once it
  /// loads.
  final Map<String, dynamic>? initialItem;

  /// The movie/show this cast/crew member was tapped from, when known
  /// (only the two detail-screen call sites have one — search and
  /// favorites open a person on their own, with no single title behind
  /// it). A TMDB-sourced cast/crew card (see CastCrewService) can be
  /// credited here without Jellyfin's own People metadata for this
  /// item listing them at all, which otherwise means NEITHER the
  /// name-based Person lookup (getPerson) NOR the name-based
  /// filmography query (getItemsByPerson) can find this item — both
  /// search Jellyfin's own People index, which never had this person
  /// on it in the first place. Carrying the item in directly
  /// guarantees it always shows up in the Movies/TV Shows row (and
  /// backs the background image) even then, regardless of what those
  /// name-based lookups do or don't turn up elsewhere in the library.
  final Map<String, dynamic>? sourceItem;

  const CastCrewDetailScreen({
    super.key,
    required this.personId,
    this.initialItem,
    this.sourceItem,
  });

  @override
  State<CastCrewDetailScreen> createState() => _CastCrewDetailScreenState();
}

class _CastCrewDetailScreenState extends State<CastCrewDetailScreen> {
  Map<String, dynamic>? person;
  List<dynamic> filmography = [];
  late String backdropUrl;

  // A TMDB-sourced cast/crew card (see CastCrewService) opens this
  // screen with widget.personId == "" — there's no Jellyfin id to
  // give it up front. getPerson()'s `/Persons/{name}` lookup below
  // can still resolve a real Jellyfin person item purely from the
  // name, though, whenever the server happens to have that person
  // indexed (even if they're not credited on this particular title) —
  // this is that resolved id once _load() finds one, and is what
  // _hasServerId/favoriting/the person's own image actually key off
  // instead of widget.personId, so a TMDB-sourced card gets the same
  // favorite button + background treatment as a server-sourced one
  // whenever a match exists. Starts equal to widget.personId, which
  // already covers the case where a real Jellyfin id was passed in.
  late String _resolvedPersonId;

  // NAMESIS PRIME: the id every lookup below uses. Normally widget.personId;
  // for a card that has only a TMDB person id (the last few names of a
  // title's TMDB cast/crew list are not among the title's own People, so they
  // arrive with no Id) it is that TMDB id in the virtual server's own form
  // ("p<tmdbId>"). Without this those people got no biography and no
  // filmography at all, while their neighbours in the same row did.
  late final String _lookupId;

  bool loading = true;
  bool favorite = false;

  // Drives the favorite button's press-scale feedback — same
  // pressed-state + AnimatedScale convention LiveChannelCard uses,
  // since the plain IconButton here otherwise gave no clear "this
  // registered" feedback (its default ripple can bleed past the
  // rounded border it sits in).
  bool _favoritePressed = false;

  // Same "fade the whole block in together" treatment as
  // MovieDetailsScreen's contentReady — the header (name, photo) is
  // already on screen from initialItem, so only the bio/filmography
  // below it needs to wait for the network and appear as one motion
  // rather than popping in piecemeal.
  bool contentReady = false;

  // Raw scroll offset of the landscape layout's column, fed to
  // LandscapeScrollBar so its tinted bar can fade in once the person
  // scrolls past the hero photo — same wiring MovieDetailsScreen uses
  // for its own landscape layout. Tracked as a ValueNotifier rather
  // than setState so scrolling doesn't rebuild the whole screen.
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0);
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();

    _scrollController = ScrollController()
      ..addListener(() {
        _scrollOffset.value = _scrollController.offset;
      });

    person = widget.initialItem;
    loading = widget.initialItem == null;
    favorite = widget.initialItem?["UserData"]?["IsFavorite"] ?? false;
    final cardTmdbId = widget.initialItem?["TmdbPersonId"]?.toString() ?? "";
    _lookupId = widget.personId.isNotEmpty
        ? widget.personId
        : (cardTmdbId.isNotEmpty ? "p$cardTmdbId" : "");
    _resolvedPersonId = _lookupId;

    // A person has no backdrop of their own, so the header used to start on
    // a plain dark panel and only got a picture if the filmography load
    // later turned one up (and sometimes it never did). It now starts on the
    // backdrop of the title this person was opened from, when there is one,
    // and is replaced by the better pick below once the filmography loads.
    backdropUrl = _backdropFrom([
          if (widget.sourceItem != null) widget.sourceItem,
        ]) ??
        MediaService.getBackdropUrl(_lookupId);

    _load();
  }

  /// The backdrop of the first title in [items] that really has one: either a
  /// TMDB backdrop address carried on the entry, or an item whose
  /// BackdropImageTags is not empty (the items always list the tags they
  /// have). Null when none of them has a backdrop.
  ///
  /// Taking the first title that has a picture, instead of whichever title
  /// ranks first and hoping it has one, is what keeps the header from
  /// randomly coming up as a flat dark panel.
  String? _backdropFrom(List<dynamic> items) {
    for (final raw in items) {
      if (raw is! Map) continue;

      final tmdbBackdrop = raw["BackdropUrl"];
      if (tmdbBackdrop is String && tmdbBackdrop.isNotEmpty) {
        return tmdbBackdrop;
      }

      final id = raw["Id"]?.toString() ?? "";
      final tags = raw["BackdropImageTags"];
      if (id.isNotEmpty && tags is List && tags.isNotEmpty) {
        return MediaService.getBackdropUrl(id);
      }
    }
    return null;
  }

  /// [base] with [top] laid over it, except that a blank value in [top]
  /// (null, "" or an empty list) never replaces something [base] already
  /// has. A plain `{...base, ...top}` let an empty Name / Overview in the
  /// loaded record wipe out the name the tapped card had supplied.
  Map<String, dynamic> _overlay(
    Map<String, dynamic>? base,
    Map<String, dynamic> top,
  ) {
    final out = <String, dynamic>{...?base};
    top.forEach((key, value) {
      final blank = value == null ||
          (value is String && value.isEmpty) ||
          (value is List && value.isEmpty);
      if (blank && out[key] != null) return;
      out[key] = value;
    });
    return out;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _scrollOffset.dispose();
    super.dispose();
  }

  // TMDB-sourced cast/crew (see CastCrewService) that aren't also tagged
  // server-side arrive here with no Jellyfin person id at all — the
  // portrait/landscape CastRow.onTap now opens this screen for them too,
  // falling back to "" for personId. getPerson and getItemsByPerson both
  // still have a shot via their name-based lookups below — and when
  // getPerson's own `/Persons/{name}` lookup resolves a real Jellyfin
  // person from just the name, _resolvedPersonId picks that id up (see
  // _load below), giving this a shot at favoriting too. Only a name
  // Jellyfin genuinely has no record of at all is truly id-less.
  bool get _hasServerId => _resolvedPersonId.isNotEmpty;

  /// This person's titles, split by type — rendered as separate
  /// "Movies"/"TV Shows" ContentRows below the biography, either one
  /// alone when the person only has credits of that one type, or both
  /// together when they have credits in each.
  List<dynamic> get _movies =>
      filmography.where((item) => item["Type"] == "Movie").toList();

  List<dynamic> get _tvShows =>
      filmography.where((item) => item["Type"] == "Series").toList();

  /// Reshapes a TMDB `/person/{id}` response into the same field names
  /// [person] otherwise gets from Jellyfin (Overview/PremiereDate/
  /// EndDate/ProductionLocations/ImageUrl), so the rest of this screen
  /// never needs to know which source a given field came from.
  Map<String, dynamic> _tmdbPersonFields(Map<String, dynamic> d) {
    final bio = d["biography"]?.toString();
    final birthday = d["birthday"]?.toString();
    final deathday = d["deathday"]?.toString();
    final placeOfBirth = d["place_of_birth"]?.toString();
    final profilePath = d["profile_path"]?.toString();
    return {
      if (bio != null && bio.isNotEmpty) "Overview": bio,
      if (birthday != null && birthday.isNotEmpty) "PremiereDate": birthday,
      if (deathday != null && deathday.isNotEmpty) "EndDate": deathday,
      if (placeOfBirth != null && placeOfBirth.isNotEmpty)
        "ProductionLocations": [placeOfBirth],
      if (profilePath != null && profilePath.isNotEmpty)
        "ImageUrl": TmdbService.imageUrl(profilePath, size: "w500"),
    };
  }

  /// Runs [f] and turns any failure into null, so a call that's started
  /// early and only awaited later can never surface as an unhandled
  /// async error if the load finishes without ever needing it.
  Future<T?> _orNull<T>(Future<T> f) =>
      f.then<T?>((v) => v).catchError((_) => null);

  Future<void> _load() async {
    // Everything that doesn't depend on another call's answer is started
    // right here, together, and only awaited further down — the old
    // version ran the TMDB bio fetch, then the TMDB credits fetch, then
    // the library scan one after another *after* Jellyfin's own calls,
    // so a TMDB-sourced person paid every round trip in series before
    // anything appeared. Each call is still failure-isolated (a miss on
    // one never wipes out what another loaded).
    final name = widget.initialItem?["Name"]?.toString();
    final tmdbPersonId = widget.initialItem?["TmdbPersonId"]?.toString();

    final personFuture = _orNull(MediaService.getPerson(
      _lookupId,
      name: name,
    ));
    final filmographyFuture = _orNull(MediaService.getItemsByPerson(
      _lookupId,
      name: name,
    ));

    // A TMDB-sourced card already carries its TMDB id, so its TMDB calls
    // don't need to wait for Jellyfin to say anything: start them now.
    // The bio is only worth fetching when nothing on hand has one, and
    // the credits only when no title was passed in with this person (see
    // widget.sourceItem — a source title means the filmography row is
    // never empty, so the TMDB credits fallback further down would never
    // run). The library scan those credits get filtered against is
    // started at the same time, since its first build is the slowest
    // step of all.
    final knownTmdbId = (tmdbPersonId != null &&
            tmdbPersonId.isNotEmpty &&
            TmdbService.isConfigured)
        ? tmdbPersonId
        : null;
    final initialOverview =
        (widget.initialItem?["Overview"] ?? "").toString();

    Future<Map<String, dynamic>?>? tmdbDetailFuture;
    Future<List<Map<String, dynamic>>?>? tmdbCreditsFuture;
    if (knownTmdbId != null) {
      if (initialOverview.isEmpty) {
        tmdbDetailFuture =
            _orNull<Map<String, dynamic>?>(TmdbService.getPersonDetails(knownTmdbId));
      }
      if (widget.sourceItem == null) {
        tmdbCreditsFuture = _orNull<List<Map<String, dynamic>>>(
            TmdbService.getPersonCredits(knownTmdbId));
        MediaService.prewarmTmdbIndex();
      }
    }

    final detail = await personFuture;
    List<dynamic> movies = List<dynamic>.from(await filmographyFuture ?? []);

    // See widget.sourceItem's doc comment — a name-based lookup miss
    // (Jellyfin's own People metadata never listed this person on
    // this item) still shouldn't leave the very title they were
    // opened from missing from their own filmography row.
    final sourceItem = widget.sourceItem;
    if (sourceItem != null) {
      final sourceId = sourceItem["Id"]?.toString();
      final alreadyIncluded = sourceId != null &&
          movies.any((m) => m["Id"]?.toString() == sourceId);
      if (!alreadyIncluded) {
        movies = [...movies, Map<String, dynamic>.from(sourceItem)];
      }
    }

    // widget.initialItem only carries "TmdbPersonId" when this screen
    // was opened straight from a TMDB-sourced cast/crew card (see
    // CastCrewService) — Search and Favorites both open a person from
    // Jellyfin's own /Persons data instead, which has no such field.
    // getPerson()'s Fields now asks for ProviderIds too, so a person
    // Jellyfin resolved by name still carries a TMDB id here (its own
    // Person item's own ProviderIds.Tmdb) whenever the metadata
    // provider set one — the same id either path would need below.
    final resolvedTmdbPersonId =
        (tmdbPersonId != null && tmdbPersonId.isNotEmpty)
            ? tmdbPersonId
            : detail?["ProviderIds"]?["Tmdb"]?.toString();

    final overviewSoFar =
        (detail?["Overview"] ?? widget.initialItem?["Overview"] ?? "")
            .toString();
    final needsTmdbBio = overviewSoFar.isEmpty;
    // Jellyfin's own People data has this person credited on nothing
    // at all in the local library (see MediaService.getItemsByPerson)
    // — the normal case for a TMDB-sourced cast/crew card, since
    // that's exactly why TMDB was needed for the cast row in the
    // first place. TMDB's combined credits are the widest net for
    // finding what they've actually been in, but that list is this
    // person's entire worldwide filmography — so
    // MediaService.filterTmdbItemsInLibrary narrows it to just the
    // titles that genuinely exist in the local library, swapping each
    // match for the real Jellyfin item (which is also what lets
    // _openFilmographyItem open a real detail screen for them).
    final needsTmdbCredits = movies.isEmpty;
    final canUseTmdb = resolvedTmdbPersonId != null &&
        resolvedTmdbPersonId.isNotEmpty &&
        TmdbService.isConfigured;

    // Whatever TMDB call wasn't already started up top (the TMDB id only
    // turned up on Jellyfin's own record) starts now — bio and credits
    // together, not one after the other.
    if (canUseTmdb) {
      if (needsTmdbBio) {
        tmdbDetailFuture ??= _orNull<Map<String, dynamic>?>(
            TmdbService.getPersonDetails(resolvedTmdbPersonId!));
      }
      if (needsTmdbCredits && tmdbCreditsFuture == null) {
        tmdbCreditsFuture =
            _orNull<List<Map<String, dynamic>>>(
            TmdbService.getPersonCredits(resolvedTmdbPersonId!));
        MediaService.prewarmTmdbIndex();
      }
    }

    Map<String, dynamic>? tmdbDetail;

    // Paints the screen from whatever has loaded so far. Safe to call
    // more than once — each call rebuilds the same fields from the
    // current [detail]/[tmdbDetail]/[movies].
    void commit() {
      // Copies, not an in-place sort: [movies] stays in the order it
      // arrived in (most popular first) so the backdrop can be picked from
      // it below, however many times commit() runs.
      final byPopularity = List<dynamic>.from(movies);
      final byRating = List<dynamic>.from(movies)
        ..sort((a, b) {
          final ratingA = (a["CommunityRating"] as num?) ?? 0;
          final ratingB = (b["CommunityRating"] as num?) ?? 0;
          return ratingB.compareTo(ratingA);
        });

      if (!mounted) return;

      setState(() {
        // Merges over initialItem rather than replacing it outright, so
        // a Name/Role that only initialItem had (some Person payloads
        // don't repeat Role on the standalone item fetch) survives, and
        // a blank field in the loaded record never wipes a filled one.
        if (detail != null) {
          person = _overlay(person, detail);
          favorite = detail["UserData"]?["IsFavorite"] ?? favorite;

          // getPerson()'s `/Persons/{name}` lookup returns a real
          // Jellyfin item — including its own "Id" — whenever the
          // server has this person indexed at all, even for a
          // TMDB-sourced card that started with no Jellyfin id
          // (widget.personId == ""). Picking that id up here is what
          // unlocks favoriting (_hasServerId) and the person's own
          // server image for that case.
          final resolvedId = detail["Id"]?.toString();
          if (resolvedId != null && resolvedId.isNotEmpty) {
            _resolvedPersonId = resolvedId;
          }
        }

        if (tmdbDetail != null) {
          // Only fills whatever's still missing/blank — a field Jellyfin
          // genuinely supplied always wins over TMDB's version of it.
          final merged = Map<String, dynamic>.from(person ?? {});
          _tmdbPersonFields(tmdbDetail!).forEach((key, value) {
            final existing = merged[key];
            final isBlank = existing == null ||
                (existing is String && existing.isEmpty) ||
                (existing is List && existing.isEmpty);
            if (isBlank) merged[key] = value;
          });
          person = merged;
        }

        filmography = byRating;

        // The backdrop comes from the first credit (most popular first)
        // that actually has one. It used to be the single highest-RATED
        // credit, which is often an obscure title with a perfect score
        // from a handful of votes and no backdrop at all, so the header
        // randomly came up as a flat dark panel. When none of the credits
        // has a backdrop the header keeps what it already shows (the
        // backdrop of the title this person was opened from, if any).
        final picked = _backdropFrom(byPopularity);
        if (picked != null) {
          backdropUrl = picked;
        }
        loading = false;
        contentReady = true;
      });
    }

    final tmdbPending = canUseTmdb &&
        ((needsTmdbBio && tmdbDetailFuture != null) ||
            (needsTmdbCredits && tmdbCreditsFuture != null));

    // If Jellyfin alone already gave the screen something real to show
    // (a bio or at least one title) and TMDB is still working on the
    // rest, show that now instead of holding everything for TMDB's
    // slowest call; the TMDB results fill in below when they land.
    // With nothing yet (the usual TMDB-sourced case), keep waiting so
    // the screen doesn't flash "No biography available." first.
    if (tmdbPending && (overviewSoFar.isNotEmpty || movies.isNotEmpty)) {
      commit();
    }

    if (canUseTmdb && needsTmdbBio && tmdbDetailFuture != null) {
      tmdbDetail = await tmdbDetailFuture;
    }

    if (canUseTmdb && needsTmdbCredits && tmdbCreditsFuture != null) {
      final credits = await tmdbCreditsFuture;
      if (credits != null) {
        try {
          final tmdbFilmography = _tmdbFilmography(credits);
          movies =
              await MediaService.filterTmdbItemsInLibrary(tmdbFilmography);
        } catch (_) {
          // The library filter failed — rows just stay empty.
        }
      }
    }

    commit();
  }

  /// Reshapes TMDB's `/person/{id}/combined_credits` entries into the
  /// same {TmdbId, Name, Type, ImageUrl, Overview, ProductionYear,
  /// CommunityRating} shape [filmography] otherwise gets from
  /// Jellyfin (see _load) — deliberately leaves "Id" unset, since
  /// there's no Jellyfin item behind these yet. "TmdbId" is what
  /// MediaService.filterTmdbItemsInLibrary matches against the local
  /// library right after this returns; only entries that survive that
  /// filter (and pick up a real Jellyfin "Id" in the process) ever
  /// reach [filmography] — see the call site in _load.
  List<Map<String, dynamic>> _tmdbFilmography(
    List<Map<String, dynamic>> credits,
  ) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];

    for (final c in credits) {
      final mediaType = c["media_type"]?.toString();
      if (mediaType != "movie" && mediaType != "tv") continue;

      final tmdbId = c["id"]?.toString();
      if (tmdbId == null || tmdbId.isEmpty) continue;

      // The same title can appear twice in one combined-credits list
      // (once in `cast`, once in `crew` — a director who also voiced
      // a role, say) — keep just the first.
      if (!seen.add("$mediaType:$tmdbId")) continue;

      final name = (mediaType == "tv" ? c["name"] : c["title"])?.toString();
      if (name == null || name.isEmpty) continue;

      final dateRaw =
          (mediaType == "tv" ? c["first_air_date"] : c["release_date"])
              ?.toString();
      final year = (dateRaw != null && dateRaw.length >= 4)
          ? int.tryParse(dateRaw.substring(0, 4))
          : null;

      final posterPath = c["poster_path"]?.toString();
      final backdropPath = c["backdrop_path"]?.toString();

      result.add({
        "TmdbId": tmdbId,
        "Name": name,
        "Type": mediaType == "tv" ? "Series" : "Movie",
        if (posterPath != null && posterPath.isNotEmpty)
          "ImageUrl": TmdbService.imageUrl(posterPath, size: "w300"),
        if (backdropPath != null && backdropPath.isNotEmpty)
          "BackdropUrl": TmdbService.imageUrl(backdropPath, size: "w780"),
        "Overview": c["overview"]?.toString() ?? "",
        if (year != null) "ProductionYear": year,
        "CommunityRating": (c["vote_average"] as num?) ?? 0,
      });
    }

    return result;
  }

  /// Opens a filmography row's tapped item — a real Jellyfin detail
  /// screen when it has an "Id" (either a genuine local match or the
  /// forced-in widget.sourceItem), or a plain heads-up otherwise: a
  /// TMDB-only credit (see _tmdbFilmography) means this title isn't
  /// actually in the library yet, so there's no detail screen to open
  /// for it.
  void _openFilmographyItem(BuildContext context, dynamic item) {
    final id = item["Id"]?.toString() ?? "";
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Not in your library yet")),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MovieDetailsScreen(
          itemId: id,
          initialItem: Map<String, dynamic>.from(item),
        ),
      ),
    );
  }

  Future<void> _toggleFavorite() async {
    // Flip immediately so the icon (and the press-scale bounce) both
    // read as "this registered" the instant it's tapped, rather than
    // waiting on the network round-trip.
    setState(() => favorite = !favorite);
    try {
      await MediaService.toggleFavorite(_resolvedPersonId, !favorite);
    } catch (_) {
      if (!mounted) return;
      setState(() => favorite = !favorite);
    }
  }

  String _formatDate(String iso) {
    try {
      final date = DateTime.parse(iso);
      const months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
      ];
      return "${months[date.month - 1]} ${date.day}, ${date.year}";
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = person;
    final dataReady = !(loading || current == null);
    // A small spinner over the page until its data and at least one picture
    // (the person's photo or the header backdrop) are ready. It only shows
    // if that takes a moment, so a fast network or an already cached page
    // never shows it.
    return ArtworkReadySpinner(
      dataReady: dataReady,
      urls: (dataReady && current != null)
          ? <String>[_photoUrlFor(current), backdropUrl]
          : const <String>[],
      child: _buildPage(context),
    );
  }

  /// The person's own picture: TMDB-sourced cast/crew (see CastCrewService)
  /// carry their own resolved photo, since there is no Jellyfin image to
  /// build a server URL from when the person has no Jellyfin id (or Jellyfin
  /// simply has no photo on file for them).
  String _photoUrlFor(Map<String, dynamic> p) =>
      (p["ImageUrl"] as String?) ??
      (_hasServerId
          ? MediaService.getImageUrl(_resolvedPersonId, maxWidth: 500)
          : "");

  Widget _buildPage(BuildContext context) {
    if (loading || person == null) {
      // Nothing to draw yet. ArtworkReadySpinner (see build) puts the
      // spinner on top of this after a short delay.
      return const Scaffold(
        backgroundColor: Color(0xff101010),
        body: SizedBox.expand(),
      );
    }

    final p = person!;
    final name = p["Name"] ?? "";
    final role = (p["Role"] ?? p["Type"] ?? "").toString();
    final overview = (p["Overview"] ?? "").toString();
    final birthDateRaw = p["PremiereDate"]?.toString();
    final deathDateRaw = p["EndDate"]?.toString();
    final birthPlace =
        (p["ProductionLocations"] as List?)?.join(", ") ?? "";
    final photoUrl = _photoUrlFor(p);

    if (Responsive.isLandscape(context)) {
      return _buildLandscapeScaffold(
        context,
        name: name,
        role: role,
        overview: overview,
        birthDateRaw: birthDateRaw,
        deathDateRaw: deathDateRaw,
        birthPlace: birthPlace,
        photoUrl: photoUrl,
      );
    }

    return _buildPortraitScaffold(
      context,
      name: name,
      role: role,
      overview: overview,
      birthDateRaw: birthDateRaw,
      deathDateRaw: deathDateRaw,
      birthPlace: birthPlace,
      photoUrl: photoUrl,
    );
  }

  Widget _buildPortraitScaffold(
    BuildContext context, {
    required String name,
    required String role,
    required String overview,
    required String? birthDateRaw,
    required String? deathDateRaw,
    required String birthPlace,
    required String photoUrl,
  }) {
    return Scaffold(
      backgroundColor: _pageBg,
      body: ResistiveRefresh(
        onRefresh: _load,
        color: _gold,
        backgroundColor: const Color(0xff232323),
        child: CustomScrollView(
          // A short filmography doesn't overflow the viewport, which
          // otherwise leaves the pull gesture with nothing to grab onto.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            BackdropHeader(
              backdropUrl: backdropUrl,
              posterUrl: photoUrl,
              item: {
                "Id": widget.personId,
                "Name": name,
              },
              onBack: () => Navigator.of(context).maybePop(),
              // Stacks the photo above a centered name instead of the
              // side-by-side poster+text row, matching the centered
              // treatment the landscape layout below already uses.
              centerIcon: true,
              // The header's default 30px bottom inset plus the 28px gap
              // below made the role chip float ~58px under the name;
              // both are tightened so the chip sits right under it.
              infoBottomInset: 6,
            ),

            /// Page content — fades in as one unit once _load() settles,
            /// same treatment MovieDetailsScreen gives everything below
            /// its own header.
            SliverToBoxAdapter(
              child: AnimatedOpacity(
                opacity: contentReady ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                child: Column(
                  // Centers the role chip / birth info / favorite
                  // button block below the header, matching the
                  // landscape layout's already-centered treatment.
                  // Movies/TV Shows rows and the overview below still
                  // render full-width regardless (ContentRow's own
                  // ListView always claims the full available width,
                  // and the overview is explicitly forced full-width
                  // below), so this only affects the naturally-sized
                  // blocks above them.
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(height: role.isNotEmpty ? 6 : 28),

                    if (role.isNotEmpty) _roleChip(role),

                    if (birthDateRaw != null || birthPlace.isNotEmpty) ...[
                      SizedBox(height: role.isNotEmpty ? 14 : 0),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 20),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 20,
                          runSpacing: 8,
                          children: [
                            if (birthDateRaw != null)
                              _infoChip(
                                "Born",
                                deathDateRaw != null
                                    ? "${_formatDate(birthDateRaw)} – "
                                        "${_formatDate(deathDateRaw)}"
                                    : _formatDate(birthDateRaw),
                              ),
                            if (birthPlace.isNotEmpty)
                              _infoChip("Location", birthPlace),
                          ],
                        ),
                      ),
                    ],

                    SizedBox(
                      height: (role.isNotEmpty ||
                              birthDateRaw != null ||
                              birthPlace.isNotEmpty)
                          ? 16
                          : 0,
                    ),

                    _favoriteButton(),

                    const SizedBox(height: 24),

                    // Forced full-width regardless of a short bio's
                    // own natural (narrower) size — otherwise this
                    // Column's centered cross-axis alignment above
                    // would center a short overview block too instead
                    // of leaving it flush left like a normal
                    // paragraph.
                    SizedBox(
                      width: double.infinity,
                      child: _overviewOrFallback(overview),
                    ),

                    if (_movies.isNotEmpty) ...[
                      const SizedBox(height: 40),
                      ContentRow(
                        title: "Movies",
                        items: _movies,
                        onItemTap: (item) => _openFilmographyItem(context, item),
                      ),
                    ],

                    if (_tvShows.isNotEmpty) ...[
                      SizedBox(height: _movies.isNotEmpty ? 36 : 40),
                      ContentRow(
                        title: "TV Shows",
                        items: _tvShows,
                        onItemTap: (item) => _openFilmographyItem(context, item),
                      ),
                    ],

                    const SizedBox(height: 40),

                    // Same reasoning as MovieDetailsScreen's trailing
                    // SizedBox — the main nav's bottom bar + mini player
                    // float over this screen in a plain Stack, not a
                    // real Scaffold.extendBody (see MainNavScreen's own
                    // doc comment), so BottomClearance.of needs to be
                    // added on top of the safe-area inset MediaQuery
                    // alone reports.
                    BottomClearanceBuilder(
                      builder: (context, bottomClearance) => SizedBox(
                        height: MediaQuery.paddingOf(context).bottom +
                            bottomClearance,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Landscape layout — matches MovieDetailsScreen's own landscape
  /// scaffold: a single continuous blurred backdrop sits behind the
  /// whole page ([LandscapeBackdropBackground]) instead of a header
  /// image that hands off to a flat page-colored background partway
  /// down, and the top bar is the same transparent-then-tinted
  /// [LandscapeScrollBar] the movie/collection screens use rather than
  /// a separate heavily-blurred collapsing header.
  Widget _buildLandscapeScaffold(
    BuildContext context, {
    required String name,
    required String role,
    required String overview,
    required String? birthDateRaw,
    required String? deathDateRaw,
    required String birthPlace,
    required String photoUrl,
  }) {
    final topPadding = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: _pageBg,
      body: Stack(
        children: [
          LandscapeBackdropBackground(backdropUrl: backdropUrl),

          AnimatedOpacity(
            opacity: contentReady ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            child: ResistiveRefresh(
              onRefresh: _load,
              color: _gold,
              backgroundColor: const Color(0xff232323),
              child: CustomScrollView(
                controller: _scrollController,
                // A short filmography doesn't overflow the viewport,
                // which otherwise leaves the pull gesture with nothing
                // to grab onto.
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  LandscapeScrollBar(
                    // No logo art for a person — the bar still fades
                    // in its tinted background on scroll, just without
                    // a logo sitting on top of it.
                    logoUrl: null,
                    accentImageUrl: backdropUrl,
                    onBack: () => Navigator.of(context).maybePop(),
                    scrollOffset: _scrollOffset,
                    topPadding: topPadding,
                  ),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(height: 20),

                        _personPhoto(size: 96, photoUrl: photoUrl),

                        const SizedBox(height: 14),

                        Text(
                          name,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.dosis(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        if (role.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          _roleChip(role),
                        ],

                        if (birthDateRaw != null ||
                            birthPlace.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                            ),
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 20,
                              runSpacing: 8,
                              children: [
                                if (birthDateRaw != null)
                                  _infoChip(
                                    "Born",
                                    deathDateRaw != null
                                        ? "${_formatDate(birthDateRaw)} – "
                                            "${_formatDate(deathDateRaw)}"
                                        : _formatDate(birthDateRaw),
                                  ),
                                if (birthPlace.isNotEmpty)
                                  _infoChip("Location", birthPlace),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 16),

                        _favoriteButton(),

                        const SizedBox(height: 24),

                        // Forced full-width for the same reason as the
                        // portrait layout: a short bio's natural width
                        // would otherwise get centered by this
                        // Column's crossAxisAlignment.center instead
                        // of staying flush left like a normal
                        // paragraph.
                        SizedBox(
                          width: double.infinity,
                          child: _overviewOrFallback(overview),
                        ),

                        if (_movies.isNotEmpty) ...[
                          const SizedBox(height: 40),
                          ContentRow(
                            title: "Movies",
                            items: _movies,
                            onItemTap: (item) => _openFilmographyItem(context, item),
                          ),
                        ],

                        if (_tvShows.isNotEmpty) ...[
                          SizedBox(height: _movies.isNotEmpty ? 36 : 40),
                          ContentRow(
                            title: "TV Shows",
                            items: _tvShows,
                            onItemTap: (item) => _openFilmographyItem(context, item),
                          ),
                        ],

                        const SizedBox(height: 40),

                        // Same reasoning as MovieDetailsScreen's
                        // trailing SizedBox — the main nav's bottom bar
                        // + mini player float over this screen in a
                        // plain Stack, not a real Scaffold.extendBody
                        // (see MainNavScreen's own doc comment), so
                        // BottomClearance.of needs to be added on top
                        // of the safe-area inset MediaQuery alone
                        // reports.
                        BottomClearanceBuilder(
                          builder: (context, bottomClearance) => SizedBox(
                            height: MediaQuery.paddingOf(context).bottom +
                                bottomClearance,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _personPhoto({required double size, required String photoUrl}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: .25),
          width: 2,
        ),
      ),
      child: ClipOval(
        child: photoUrl.isEmpty
            ? Container(
                color: const Color(0xff2A2A2A),
                child: const Icon(
                  Icons.person,
                  color: Colors.white38,
                  size: 40,
                ),
              )
            : CachedNetworkImage(
                cacheManager: NemesisImageCache.instance,
                imageUrl: photoUrl,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 200),
                placeholder: (_, __) => Container(
                  color: const Color(0xff2A2A2A),
                  child: const Icon(
                    Icons.person,
                    color: Colors.white38,
                    size: 40,
                  ),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: const Color(0xff2A2A2A),
                  child: const Icon(
                    Icons.person,
                    color: Colors.white38,
                    size: 40,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _roleChip(String role) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        role,
        style: const TextStyle(
          color: _gold,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _favoriteButton() {
    // No Jellyfin person id means nothing for a favorite to attach to
    // server-side — see _hasServerId.
    if (!_hasServerId) return const SizedBox();

    // One enclosed pill holding the heart and its "Favorite" label.
    return _favoriteCircle();
  }

  Widget _favoriteCircle() {
    return AnimatedScale(
      duration: const Duration(milliseconds: 120),
      scale: _favoritePressed ? 0.95 : 1,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white.withValues(alpha: .12)),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTapDown: (_) => setState(() => _favoritePressed = true),
            onTapUp: (_) => setState(() => _favoritePressed = false),
            onTapCancel: () => setState(() => _favoritePressed = false),
            onTap: _toggleFavorite,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: child,
                    ),
                    child: Icon(
                      favorite ? Icons.favorite : Icons.favorite_border,
                      key: ValueKey(favorite),
                      color: favorite ? Colors.red : Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Favorite",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .72),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _overviewOrFallback(String overview) {
    return overview.isNotEmpty
        ? OverviewSection(overview: overview)
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              "No biography available.",
              style: TextStyle(
                color: Colors.white.withValues(alpha: .4),
                fontSize: 14,
              ),
            ),
          );
  }

  Widget _infoChip(String tag, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "$tag: ",
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ],
    );
  }
}
