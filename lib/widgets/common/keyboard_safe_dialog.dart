import 'package:flutter/material.dart';

/// Wraps a dialog so the on-screen keyboard behaves the way it does in
/// WhatsApp, Instagram, etc. when you tap a text field: the keyboard
/// just slides up and overlays the bottom of the screen, while
/// everything already on screen — including this dialog — stays
/// completely still underneath it.
///
/// Flutter's own [Dialog] (which [AlertDialog] builds on) doesn't do
/// that by default. It wraps its content in an `AnimatedPadding` keyed
/// off `MediaQuery.viewInsets.bottom`, so the dialog repositions
/// *itself* every time the keyboard's height changes. That would be
/// fine if both animations moved together, but they don't: the
/// keyboard's own slide-up is drawn by the OS as soon as it starts,
/// while Flutter only learns the new inset (and starts animating the
/// dialog to match) once that platform value actually lands — which in
/// practice arrives late and in one lump, well after the keyboard
/// already looks fully open on screen. The result is two separate,
/// out-of-sync animations: the keyboard appears to finish, and only
/// *then* does the dialog visibly lurch up to get out of its way. That
/// lurch — and the same thing again in reverse on dismiss — is the
/// "keyboard interferes with content" stutter.
///
/// The fix is to give the dialog nothing to react to in the first
/// place. [MediaQuery.removeViewInsets] strips the bottom inset out of
/// the [MediaQuery] the [Dialog] widget reads, so its `AnimatedPadding`
/// always computes zero padding and never animates. In its place, this
/// pins the dialog near the top of the screen from the moment it opens
/// — every dialog this app uses it for is a short title, a line or two
/// of description, one text field, and a Cancel/Save row, all well
/// clear of where a keyboard rises to on any phone in portrait or
/// landscape. With the dialog no longer moving at all, the keyboard's
/// own native slide is the only motion left on screen, exactly as if
/// it were overlaying any other static content.
///
/// Usage: wrap just the `builder` result passed to `showDialog` —
/// nothing else about the call site changes.
///
/// ```dart
/// showDialog<String>(
///   context: context,
///   builder: (context) => const KeyboardSafeDialog(
///     child: AlertDialog(...),
///   ),
/// );
/// ```
class KeyboardSafeDialog extends StatelessWidget {
  const KeyboardSafeDialog({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: child,
    );
  }
}

/// The alignment every [KeyboardSafeDialog] dialog should pass to its
/// [AlertDialog]/[Dialog]'s own `alignment` parameter — pins the
/// dialog's vertical center to the top fifth of the screen, comfortably
/// above where a keyboard reaches even in landscape.
const Alignment keyboardSafeDialogAlignment = Alignment(0, -0.6);
