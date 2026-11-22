import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/jellyfin_services/auth_service.dart';
import '../../services/jellyfin_services/jellyfin_client.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/jellyfin_services/storage_service.dart';
import '../../services/profile_avatar_service.dart';
import '../../services/profile_name_service.dart';
import '../../utils/bottom_clearance.dart';
import '../../utils/responsive.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/profile/avatar_presets.dart';

const _gold = Color(0xffD4AF37);
const _bg = Color(0xff161616);
const _cardBg = Color(0xff1F1F1F);

/// Full-page replacement for the old "Choose your profile picture" sheet:
/// change the name shown on Profile & Settings and pick an avatar.
///
/// Nothing is saved until the person taps Save, so the picture and name can
/// be tried out (the preview at the top follows every change) and backing out
/// discards them. The first avatar in the grid is always the account's
/// default picture: the Google photo for a Google account, otherwise the
/// plain profile icon. The one currently selected has the gold ring.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _nameController = TextEditingController();
  final _nameFocus = FocusNode();

  bool _ready = false;
  bool _saving = false;

  /// What was saved when the page opened (and after each successful save).
  String _initialName = '';
  String? _initialPresetId;

  /// What the page currently shows. A null [_presetId] is the default picture.
  String? _presetId;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final avatar = ProfileAvatarService.instance;
    await avatar.ready;
    final stored = (await StorageService.getUsername() ?? '').trim();
    if (!mounted) return;
    setState(() {
      _initialName = stored;
      _nameController.value = TextEditingValue(
        text: stored,
        selection: TextSelection.collapsed(offset: stored.length),
      );
      _initialPresetId = avatar.preset?.id;
      _presetId = _initialPresetId;
      _ready = true;
    });
  }

  bool get _nameChanged => _nameController.text.trim() != _initialName;
  bool get _presetChanged => _presetId != _initialPresetId;
  bool get _dirty => _ready && (_nameChanged || _presetChanged);
  bool get _canSave => _dirty && !_saving;

  void _select(String? id) {
    if (_saving || id == _presetId) return;
    HapticFeedback.selectionClick();
    _nameFocus.unfocus();
    setState(() => _presetId = id);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _save() async {
    if (!_canSave) return;

    final name = _nameController.text.trim();
    if (_nameChanged && name.isEmpty) {
      setState(() => _nameError = 'Enter a name for your profile.');
      return;
    }

    final avatar = ProfileAvatarService.instance;
    final accountId = avatar.uid;
    if (accountId == null) {
      _toast("Couldn't save your changes. Please sign in again.");
      return;
    }

    _nameFocus.unfocus();
    setState(() => _saving = true);

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      if (_presetChanged) {
        await avatar.choosePreset(_presetId);
        // choosePreset swallows storage errors; make sure it really stuck.
        if (avatar.preset?.id != _presetId) {
          throw StateError('The avatar could not be saved.');
        }
        _initialPresetId = _presetId;
      }
      if (_nameChanged) {
        await ProfileNameService.instance.rename(accountId, name);
        _initialName = name;
      }
    } catch (e) {
      debugPrint('[EditProfile] save failed: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      _toast("Couldn't save your changes. Please try again.");
      return;
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Profile updated'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    if (mounted) navigator.pop();
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text('Discard changes?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          "Your changes to this profile haven't been saved.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep editing',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Discard',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  // ----------------------------------------------------------------- faces

  /// The account's default picture: the Google photo for a Google account,
  /// otherwise what the app already shows when no avatar is chosen (the
  /// profile image, or the plain profile icon).
  Widget _defaultFace({double iconSize = 30}) {
    final icon = Icon(Icons.person_outline, color: Colors.white, size: iconSize);

    final userId = JellyfinClient.userId;
    final imageUrl = userId.isNotEmpty
        ? MediaService.getUserImageUrl(userId, maxWidth: 200)
        : null;
    final Widget fallback = imageUrl == null
        ? icon
        : CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.cover,
            placeholder: (context, url) => icon,
            errorWidget: (context, url, error) => icon,
          );

    final photo = ProfileAvatarService.instance.googlePhotoUrl;
    if (photo == null) return fallback;
    return CachedNetworkImage(
      imageUrl: photo,
      fit: BoxFit.cover,
      placeholder: (context, url) => fallback,
      errorWidget: (context, url, error) => fallback,
    );
  }

  Widget _faceFor(String? presetId, {double iconSize = 30}) {
    final preset = AvatarPresets.byId(presetId);
    if (preset == null) return _defaultFace(iconSize: iconSize);
    return SizedBox.expand(child: preset.build());
  }

  String get _defaultLabel =>
      ProfileAvatarService.instance.googlePhotoUrl != null
          ? 'Google photo'
          : 'Default';

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _saving) return;
        _confirmDiscard();
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          title: const Text('Edit Profile',
              style: TextStyle(color: Colors.white)),
          actions: [
            // The only Save control on this page (the old bottom "Save
            // changes" button was removed as a duplicate). Shows a small
            // spinner while the save is running.
            TextButton(
              onPressed: _canSave ? _save : null,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: _gold,
                        strokeWidth: 2.2,
                      ),
                    )
                  : Text(
                      'SAVE',
                      style: TextStyle(
                        color: _canSave ? _gold : Colors.white24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: !_ready
            ? const Center(child: CircularProgressIndicator(color: _gold))
            : AbsorbPointer(
                absorbing: _saving,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: Responsive.constrainedContentWidth(context,
                        maxWidth: 700),
                    // BottomClearanceBuilder so the page's trailing padding
                    // clears the main nav's floating bottom bar, like every
                    // other screen in Profile & Settings.
                    child: BottomClearanceBuilder(
                      builder: (context, bottomClearance) => ListView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.fromLTRB(
                          20,
                          16,
                          20,
                          40 +
                              MediaQuery.paddingOf(context).bottom +
                              bottomClearance,
                        ),
                        children: [
                          _sectionLabel('Profile'),
                          const SizedBox(height: 10),
                          _profileCard(),
                          const SizedBox(height: 24),
                          _sectionLabel('Avatar'),
                          const SizedBox(height: 10),
                          _avatarCard(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: Colors.white38,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _profileCard() {
    final typed = _nameController.text.trim();
    final email = AuthService.currentEmail;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 72,
                height: 72,
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  // Tight size, so every picture fills the whole circle.
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, if (current != null) current],
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(_presetId ?? 'default'),
                    child: _faceFor(_presetId, iconSize: 34),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      typed.isEmpty ? 'Your name' : typed,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: typed.isEmpty ? Colors.white38 : Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (email != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        email,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'Username',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            focusNode: _nameFocus,
            maxLength: ProfileNameService.maxLength,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            cursorColor: _gold,
            onChanged: (_) => setState(() => _nameError = null),
            onSubmitted: (_) => _save(),
            onTapOutside: (_) => _nameFocus.unfocus(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            buildCounter: (context,
                    {required currentLength,
                    required isFocused,
                    required maxLength}) =>
                Text(
              '$currentLength/$maxLength',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            decoration: InputDecoration(
              hintText: 'Your name',
              hintStyle: const TextStyle(color: Colors.white38),
              errorText: _nameError,
              filled: true,
              fillColor: _bg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _gold, width: 1.2),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: Colors.redAccent, width: 1.2),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: Colors.redAccent, width: 1.2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarCard() {
    final selectedLabel = _presetId == null
        ? _defaultLabel
        : (AvatarPresets.byId(_presetId)?.label ?? _defaultLabel);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose an avatar',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            selectedLabel,
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns =
                  (constraints.maxWidth / 64).floor().clamp(4, 6).toInt();
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1,
                ),
                itemCount: AvatarPresets.all.length + 1,
                itemBuilder: (context, i) {
                  // First tile: the account's default picture.
                  if (i == 0) {
                    return _AvatarTile(
                      label: _defaultLabel,
                      selected: _presetId == null,
                      onTap: () => _select(null),
                      child: ColoredBox(
                        color: Colors.black45,
                        child: _defaultFace(),
                      ),
                    );
                  }
                  final preset = AvatarPresets.all[i - 1];
                  return _AvatarTile(
                    label: preset.label,
                    selected: _presetId == preset.id,
                    onTap: () => _select(preset.id),
                    child: preset.build(),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

/// One round choice in the avatar grid. The selected one gets the gold ring.
class _AvatarTile extends StatelessWidget {
  const _AvatarTile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // No visible name under the avatar; the label is for screen readers (and
    // the caption above the grid shows the current choice).
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      child: Pressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? _gold : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: ClipOval(child: child),
        ),
      ),
    );
  }
}
