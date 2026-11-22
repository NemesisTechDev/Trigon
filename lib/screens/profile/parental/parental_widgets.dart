import 'package:flutter/material.dart';

import '../../../widgets/common/pressable.dart';

const pcGold = Color(0xffD4AF37);
const pcBg = Color(0xff161616);
const pcCardBg = Color(0xff1F1F1F);

/// Small building blocks that match the app's own Settings look.
class PcSection extends StatelessWidget {
  final String label;
  final String? hint;
  const PcSection(this.label, {super.key, this.hint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint!,
                style: const TextStyle(
                    color: Colors.white30, fontSize: 12, height: 1.35)),
          ],
        ],
      ),
    );
  }
}

class PcTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;
  final bool dimmed;
  const PcTile({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    this.onTap,
    this.trailing,
    this.destructive = false,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Colors.redAccent : Colors.white;
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: pcCardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: color,
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
          trailing ??
              (onTap != null
                  ? const Icon(Icons.chevron_right,
                      color: Colors.white24, size: 20)
                  : const SizedBox.shrink()),
        ],
      ),
    );
    final w = Opacity(opacity: dimmed ? 0.45 : 1, child: body);
    if (onTap == null) return w;
    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: w,
    );
  }
}

class PcToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  const PcToggle({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PcTile(
      icon: icon,
      label: label,
      subtitle: subtitle,
      dimmed: onChanged == null,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: pcGold,
      ),
    );
  }
}

/// A rounded card holding a single message (used for status banners).
class PcBanner extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final Widget child;
  const PcBanner({super.key, required this.icon, required this.child, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? pcGold;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: pcCardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: c, size: 22),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Dark scaffold + centred, width-limited list used by every sub-screen.
class PcPage extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  const PcPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pcBg,
      appBar: AppBar(
        backgroundColor: pcBg,
        title: Text(title, style: const TextStyle(color: Colors.white)),
        actions: actions,
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              40 + MediaQuery.paddingOf(context).bottom + 80,
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}
