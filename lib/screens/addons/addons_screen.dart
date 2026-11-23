import 'package:flutter/material.dart';

import '../../addons/addon_client.dart';
import '../../addons/addon_manager.dart';
import '../../addons/addon_models.dart';

/// Settings > Addons.
///
///  - "Default addons": the addons that come with the app. On by default.
///  - "Custom addons": addons the person adds here. Off by default, and it
///    cannot be switched on until one has been added.
///
/// Links come from every addon whose switch is on. With both off, playing
/// or downloading says there are no active addons (see
/// [AddonManager.noAddonsMessage]).
///
/// The default addons are deliberately not listed (their addresses can carry
/// a private key), and the torrent engine has no settings here: it stays
/// hidden and runs by itself.
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
  static const Color _card = Color(0xFF1F1F1F);

  final TextEditingController _url = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AddonManager.instance.load();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _say(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleCustom(bool value) async {
    final ok = await AddonManager.instance.setCustomEnabled(value);
    if (!ok && mounted) {
      _say('Add a custom addon below to use this option.');
    }
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
      _say(AddonManager.instance.customEnabled.value
          ? 'Installed ${manifest.name}'
          : 'Installed ${manifest.name}. Turn on Custom addons to use it.');
    } on AddonException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not install addon: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _switchCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged, activeColor: _gold),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = AddonManager.instance;
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
            'Addons decide where your links come from. Links are taken from '
            'every addon that is switched on.',
            style: TextStyle(color: Colors.white60, height: 1.4),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<bool>(
            valueListenable: manager.defaultEnabled,
            builder: (context, on, _) => _switchCard(
              icon: Icons.extension_outlined,
              title: 'Default addons',
              subtitle: on
                  ? 'Links come from the addons built into the app'
                  : 'Off: the built-in addons are not used',
              value: on,
              onChanged: manager.setDefaultEnabled,
            ),
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<bool>(
            valueListenable: manager.customEnabled,
            builder: (context, on, _) => _switchCard(
              icon: Icons.add_link_rounded,
              title: 'Custom addons',
              subtitle: on
                  ? 'Links also come from the addons you added'
                  : 'Off: the addons you added are not used',
              value: on,
              onChanged: _toggleCustom,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'ADD A CUSTOM ADDON',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _add(),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Addon URL (https://.../manifest.json)',
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
          const SizedBox(height: 16),
          ValueListenableBuilder<List<AddonManifest>>(
            valueListenable: manager.addons,
            builder: (context, _, __) {
              final custom = manager.customAddons;
              if (custom.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text('No custom addons added',
                        style: TextStyle(color: Colors.white38)),
                  ),
                );
              }
              return Column(
                children: [for (final a in custom) _AddonCard(addon: a)],
              );
            },
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
            onPressed: () => AddonManager.instance.remove(addon.key),
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
