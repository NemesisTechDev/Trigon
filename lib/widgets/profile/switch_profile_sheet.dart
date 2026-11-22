import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/account_store.dart';
import '../common/pressable.dart';
import 'profile_avatar.dart';

const _gold = Color(0xffD4AF37);
const _sheetBg = Color(0xff1A1A1A);
const _rowBg = Color(0xff232323);

/// Bottom sheet listing every profile saved on this device, with
/// one-tap switching. Open it with [SwitchProfileSheet.show] — wired to
/// Profile & Settings, a long-press on Home's avatar, and a long-press
/// on the landscape rail's profile button.
class SwitchProfileSheet extends StatefulWidget {
  const SwitchProfileSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: _sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const SwitchProfileSheet(),
    );
  }

  @override
  State<SwitchProfileSheet> createState() => _SwitchProfileSheetState();
}

class _SwitchProfileSheetState extends State<SwitchProfileSheet> {
  List<SavedAccount>? _accounts;
  String? _switchingId; // userId currently being switched to

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Makes sure the active session is in the list even if it was
    // signed in before this feature existed.
    await AccountStore.rememberCurrent();
    final list = await AccountStore.all();
    if (!mounted) return;
    setState(() => _accounts = list);
  }

  Future<void> _switch(SavedAccount a) async {
    if (_switchingId != null || a.isCurrent) return;
    setState(() => _switchingId = a.userId);

    final rootNav = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);

    final outcome = await AccountStore.switchTo(a, rootNav);
    if (!mounted) return;

    switch (outcome) {
      case SwitchOutcome.ok:
        // switchTo already replaced the whole route stack (this sheet
        // included); nothing left to do here.
        break;
      case SwitchOutcome.expired:
        setState(() => _switchingId = null);
        rootNav.pop(); // close the sheet
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('${a.username} was signed out on the server. '
                'Sign in again to use this profile.'),
            action: SnackBarAction(
              label: 'Sign in',
              onPressed: () => rootNav.pushNamed('/login'),
            ),
          ));
      case SwitchOutcome.unreachable:
        setState(() => _switchingId = null);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text("Couldn't reach the server. You're still on your "
                'current profile.'),
          ));
    }
  }

  Future<void> _remove(SavedAccount a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xff1F1F1F),
        title: const Text('Remove profile?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          '${a.username} will be removed from this device\'s quick-switch '
          'list. Their account on the server isn\'t affected.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AccountStore.remove(a.userId, a.serverUrl);
    await _load();
  }

  void _addProfile() {
    // Plain push (not remove-until): the current profile stays signed in
    // underneath, and back from the login screen just pops to it. A
    // successful login saves the new profile (AuthService.login) and
    // rebuilds from "/home" itself.
    final rootNav = Navigator.of(context, rootNavigator: true);
    rootNav.pop();
    rootNav.pushNamed('/login');
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    final servers = accounts?.map((a) => a.serverUrl).toSet().length ?? 1;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Switch Profile',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 14),
            if (accounts == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: CircularProgressIndicator(color: _gold),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final a in accounts)
                      _AccountRow(
                        account: a,
                        showServer: servers > 1,
                        switching: _switchingId == a.userId,
                        disabled: _switchingId != null,
                        onTap: () => _switch(a),
                        onRemove: a.isCurrent ? null : () => _remove(a),
                      ),
                    const SizedBox(height: 4),
                    Pressable(
                      onTap: _switchingId != null ? () {} : _addProfile,
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Row(
                          children: [
                            CircleAvatar(
                              radius: 22,
                              backgroundColor: Color(0xff2C2C2C),
                              child: Icon(Icons.add_rounded,
                                  color: Colors.white, size: 24),
                            ),
                            SizedBox(width: 14),
                            Text(
                              'Add profile',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  final SavedAccount account;
  final bool showServer;
  final bool switching;
  final bool disabled;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _AccountRow({
    required this.account,
    required this.showServer,
    required this.switching,
    required this.disabled,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final current = account.isCurrent;
    final host = Uri.tryParse(account.serverUrl)?.host ?? account.serverUrl;

    final avatarImage = CachedNetworkImage(
      imageUrl: account.avatarUrl,
      fit: BoxFit.cover,
      memCacheWidth: 120,
      placeholder: (_, __) =>
          const Icon(Icons.person_outline, color: Colors.white, size: 22),
      errorWidget: (_, __, ___) =>
          const Icon(Icons.person_outline, color: Colors.white, size: 22),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        onTap: disabled ? () {} : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          decoration: BoxDecoration(
            color: _rowBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: current ? _gold.withValues(alpha: 0.7) : Colors.transparent,
              width: 1.2,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                // The signed-in account shows its real picture (Google photo
                // or chosen avatar); other saved profiles keep theirs.
                child: current
                    ? ProfileAvatarBody(fallback: avatarImage)
                    : avatarImage,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.username.isEmpty ? 'Profile' : account.username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (current || showServer)
                      Text(
                        current
                            ? (showServer ? 'Active, $host' : 'Active')
                            : host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: current ? _gold : Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (switching)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: _gold),
                  ),
                )
              else if (current)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.check_circle_rounded,
                      color: _gold, size: 22),
                )
              else if (onRemove != null)
                IconButton(
                  tooltip: 'Remove from this device',
                  onPressed: disabled ? null : onRemove,
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white38, size: 20),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
