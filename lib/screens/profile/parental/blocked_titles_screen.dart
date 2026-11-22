import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../catalog/catalog_models.dart';
import '../../../catalog/tmdb_catalog_service.dart';
import '../../../services/parental/parental_controls.dart';
import '../../../services/parental/parental_models.dart';
import 'parental_widgets.dart';

/// "Title restrictions": search for a movie or show and block it, or
/// unblock what is already blocked.
class BlockedTitlesScreen extends StatefulWidget {
  const BlockedTitlesScreen({super.key});

  @override
  State<BlockedTitlesScreen> createState() => _BlockedTitlesScreenState();
}

class _BlockedTitlesScreenState extends State<BlockedTitlesScreen> {
  final ParentalControls _pc = ParentalControls.instance;
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<CatalogTitle> _results = const [];
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  List<BlockedTitle> get _blocked => _pc.settings.value.blockedTitles;

  bool _isBlocked(String id) => _blocked.any((b) => b.id == id);

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(text));
  }

  Future<void> _search(String text) async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final found = await TmdbCatalogService.search(text);
      if (!mounted || _query.text.trim() != text.trim()) return;
      setState(() {
        _results = found.take(30).toList();
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = "Couldn't search. Check your connection.";
      });
    }
  }

  Future<void> _toggle(CatalogTitle t) async {
    final id = ParentalControls.idOfTitle(t);
    final list = [..._blocked];
    final i = list.indexWhere((b) => b.id == id);
    if (i >= 0) {
      list.removeAt(i);
    } else {
      list.add(BlockedTitle(id, t.title,
          year: t.year, posterPath: t.posterPath));
    }
    await _pc.save(_pc.settings.value.copyWith(blockedTitles: list));
    if (mounted) setState(() {});
  }

  Future<void> _unblock(BlockedTitle b) async {
    final list = [..._blocked]..removeWhere((x) => x.id == b.id);
    await _pc.save(_pc.settings.value.copyWith(blockedTitles: list));
    if (mounted) setState(() {});
  }

  Widget _poster(String? path) {
    final url = TmdbImages.poster(path, size: 'w154');
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 64,
        child: url == null
            ? Container(
                color: pcBg,
                child: const Icon(Icons.movie_outlined,
                    color: Colors.white24, size: 20),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Container(color: pcBg),
              ),
      ),
    );
  }

  Widget _row({
    required String? poster,
    required String title,
    required String subtitle,
    required Widget action,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: pcCardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _poster(poster),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          action,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.text.trim().isNotEmpty;
    return PcPage(
      title: 'Blocked titles',
      children: [
        TextField(
          controller: _query,
          onChanged: _onChanged,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Search a movie or show to block',
            hintStyle: const TextStyle(color: Colors.white38),
            prefixIcon: const Icon(Icons.search, color: Colors.white38),
            filled: true,
            fillColor: pcCardBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            suffixIcon: searching
                ? IconButton(
                    icon: const Icon(Icons.close, color: Colors.white38),
                    onPressed: () {
                      _query.clear();
                      _onChanged('');
                    },
                  )
                : null,
          ),
        ),
        const SizedBox(height: 16),
        if (searching) ...[
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(color: pcGold)),
            )
          else if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.white54))
          else if (_results.isEmpty)
            const Text('No results.',
                style: TextStyle(color: Colors.white54))
          else
            for (final t in _results)
              _row(
                poster: t.posterPath,
                title: t.title,
                subtitle:
                    '${t.type == CatalogType.movie ? 'Movie' : 'Show'}'
                    '${t.year != null ? '  |  ${t.year}' : ''}',
                action: TextButton(
                  onPressed: () => _toggle(t),
                  child: Text(
                    _isBlocked(ParentalControls.idOfTitle(t))
                        ? 'Unblock'
                        : 'Block',
                    style: TextStyle(
                      color: _isBlocked(ParentalControls.idOfTitle(t))
                          ? Colors.white54
                          : Colors.redAccent,
                    ),
                  ),
                ),
              ),
        ] else ...[
          PcSection(
            'Currently blocked',
            hint: _blocked.isEmpty
                ? 'Nothing blocked yet. Search above to add a title.'
                : null,
          ),
          for (final b in _blocked)
            _row(
              poster: b.posterPath,
              title: b.name.isEmpty ? b.id : b.name,
              subtitle: '${b.id.startsWith('m') ? 'Movie' : 'Show'}'
                  '${b.year != null ? '  |  ${b.year}' : ''}',
              action: TextButton(
                onPressed: () => _unblock(b),
                child: const Text('Unblock',
                    style: TextStyle(color: Colors.white54)),
              ),
            ),
        ],
      ],
    );
  }
}
