import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../addons/addon_client.dart';
import '../../addons/addon_manager.dart';
import '../../addons/addon_models.dart';
import '../../library/source_preferences.dart';
import '../../torrent/torrent_engine.dart';

/// Install / remove addons. An addon is any server that speaks the Stremio
/// addon protocol, including the one in `addon_server/`.
class AddonsScreen extends StatefulWidget {
  /// True when shown as a root tab (no back arrow).
  final bool isTab;
  const AddonsScreen({super.key, this.isTab = false});

  @override
  State<AddonsScreen> createState() => _AddonsScreenState();
}

class _AddonsScreenState extends State<AddonsScreen> {
  static const Color _gold = Color(0xFFD4AF37);
  static const Color _bg = Color(0xFF161616);

  final TextEditingController _url = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AddonManager.instance.load();
    SourcePreferences.instance.load();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _url.text.trim();
    if (text.isEmpty || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final manifest = await AddonManager.instance.add(text);
      if (!mounted) return;
      _url.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Installed ${manifest.name}')),
      );
    } on AddonException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not install addon: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        automaticallyImplyLeading: !widget.isTab,
        title: const Text('Addons',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Text(
            'Addons decide what plays. Paste the address of your addon '
            '(for example http://192.168.1.20:7000/manifest.json).',
            style: TextStyle(color: Colors.white60, height: 1.4),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _add(),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Addon URL',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF222222),
              errorText: _error,
              errorMaxLines: 3,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              suffixIcon: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _gold),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.add_circle, color: _gold),
                      onPressed: _add,
                    ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tip: from an Android emulator, your computer is 10.0.2.2.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<bool>(
            valueListenable: SourcePreferences.instance.autoPick,
            builder: (context, on, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-pick my last source',
                  style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                'Skip the source list when a title already has one you chose.',
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              value: on,
              onChanged: SourcePreferences.instance.setAutoPick,
            ),
          ),
          const SizedBox(height: 12),
          const _TorrentEngineCard(),
          const SizedBox(height: 16),
          ValueListenableBuilder<List<AddonManifest>>(
            valueListenable: AddonManager.instance.addons,
            builder: (context, list, _) {
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text('No addons installed',
                        style: TextStyle(color: Colors.white38)),
                  ),
                );
              }
              return Column(
                children: [for (final a in list) _AddonCard(addon: a)],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Settings for the local torrent engine that plays torrent-only sources.
class _TorrentEngineCard extends StatefulWidget {
  const _TorrentEngineCard();

  @override
  State<_TorrentEngineCard> createState() => _TorrentEngineCardState();
}

class _TorrentEngineCardState extends State<_TorrentEngineCard> {
  static const Color _gold = Color(0xFFD4AF37);

  final TextEditingController _url = TextEditingController();
  final TextEditingController _exe = TextEditingController();
  bool _busy = false;
  bool? _ok;
  bool _builtIn = false;
  String? _status;

  bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await TorrentEngine.instance.load();
    if (!mounted) return;
    _url.text = TorrentEngine.instance.baseUrl;
    _exe.text = TorrentEngine.instance.exePath;
    final up = await TorrentEngine.instance.isRunning();
    final embedded = (await TorrentEngine.instance.embeddedExe()) != null;
    if (!mounted) return;
    setState(() {
      _builtIn = embedded;
      _ok = up;
      _status = up
          ? 'Engine is running.'
          : (embedded
              ? 'Built-in engine is ready. It starts when you play a torrent.'
              : 'Engine is not running.');
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _exe.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _status = null;
    });
    await TorrentEngine.instance.save(url: _url.text, exe: _exe.text);
    final up = await TorrentEngine.instance.ensureRunning();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = up;
      _status = up
          ? 'Engine is running.'
          : (TorrentEngine.instance.lastStartError ??
              'Not reachable. Check the address, or start TorrServer.');
    });
  }

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF222222),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Torrent engine',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 15)),
          const SizedBox(height: 4),
          Text(
            _builtIn
                ? 'Torrent sources play through the engine built into this '
                    'app. Nothing to install: it starts by itself when you '
                    'play one. The fields below are only for using a '
                    'different engine.'
                : 'Some addons return torrents instead of direct links. They '
                    'play through TorrServer, a free torrent engine. This '
                    'build has none built in, so start TorrServer yourself '
                    '(or point to one on your network), then tap Save & test.',
            style: const TextStyle(
                color: Colors.white54, fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(color: Colors.white),
            decoration: _decoration('Engine address (http://127.0.0.1:8090)'),
          ),
          if (_desktop) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _exe,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(color: Colors.white),
              decoration: _decoration(
                  'Optional: path to TorrServer so the app can start it'),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: _busy ? null : _saveAndTest,
                style: FilledButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                ),
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black),
                      )
                    : const Text('Save & test'),
              ),
              const SizedBox(width: 12),
              if (_status != null)
                Expanded(
                  child: Text(
                    _status!,
                    style: TextStyle(
                      color: _ok == true
                          ? Colors.lightGreenAccent
                          : Colors.orangeAccent,
                      fontSize: 12.5,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddonCard extends StatelessWidget {
  final AddonManifest addon;
  const _AddonCard({required this.addon});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  addon.version.isEmpty
                      ? addon.name
                      : '${addon.name}  v${addon.version}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15),
                ),
                if (addon.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(addon.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12.5)),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final r in addon.resources) _Chip(r),
                    for (final t in addon.types) _Chip(t, muted: true),
                  ],
                ),
                const SizedBox(height: 6),
                Text(addon.baseUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white30, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline, color: Colors.white54),
            onPressed: () => AddonManager.instance.remove(addon.id),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool muted;
  const _Chip(this.label, {this.muted = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: muted
            ? Colors.white10
            : const Color(0xFFD4AF37).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: muted ? Colors.white60 : const Color(0xFFD4AF37),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
