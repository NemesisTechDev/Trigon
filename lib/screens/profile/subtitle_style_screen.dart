import 'package:flutter/material.dart';

import '../../player/models/subtitle_appearance.dart';
import '../../player/widgets/subtitle_style.dart';
import '../../services/subtitle_appearance_settings.dart';
import '../../utils/responsive.dart';

const _gold = Color(0xffD4AF37);
const _bg = Color(0xff161616);
const _cardBg = Color(0xff1F1F1F);

/// Full-page subtitle customization (Settings > Subtitle Style). Every
/// change goes straight into [SubtitleAppearanceSettings.notifier], so
/// the preview, the video player and — while casting — the TV all update
/// live; there is no Save button.
class SubtitleStyleScreen extends StatelessWidget {
  const SubtitleStyleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('Subtitle Style',
            style: TextStyle(color: Colors.white)),
        actions: [
          ValueListenableBuilder<SubtitleAppearance>(
            valueListenable: SubtitleAppearanceSettings.notifier,
            builder: (context, a, _) => TextButton(
              onPressed: a.isDefault ? null : SubtitleAppearanceSettings.reset,
              child: Text(
                'RESET',
                style: TextStyle(
                  color: a.isDefault ? Colors.white24 : _gold,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: Responsive.constrainedContentWidth(context, maxWidth: 700),
          child: ValueListenableBuilder<SubtitleAppearance>(
            valueListenable: SubtitleAppearanceSettings.notifier,
            builder: (context, a, _) => ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                8,
                20,
                32 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                _Preview(appearance: a),
                const SizedBox(height: 8),
                const Text(
                  'Drag the slider beside the preview to move subtitles up or down.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 24),
                _label('Background color'),
                _SwatchRow(
                  selected: a.backgroundColor,
                  onSelected: (c) => _set(a.copyWith(backgroundColor: c)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.opacity, color: Colors.white54, size: 20),
                    Expanded(
                      child: _themedSlider(
                        value: a.backgroundOpacity,
                        onChanged: (v) =>
                            _set(a.copyWith(backgroundOpacity: v)),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${(a.backgroundOpacity * 100).round()}%',
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 13),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _label('Font family'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in SubtitleFontFamily.values)
                      _chip(
                        label: f.label,
                        fontFamily: f.flutterFamily,
                        selected: a.fontFamily == f,
                        onTap: () => _set(a.copyWith(fontFamily: f)),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                _label('Text color'),
                _SwatchRow(
                  selected: a.textColor,
                  onSelected: (c) => _set(a.copyWith(textColor: c)),
                ),
                const SizedBox(height: 20),
                _label('Text size'),
                _SizeRow(
                  selectedIndex: a.sizeIndex,
                  onSelected: (i) => _set(a.copyWith(sizeIndex: i)),
                ),
                const SizedBox(height: 20),
                _label('Text edge style'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in SubtitleEdgeStyle.values)
                      _chip(
                        label: e.label,
                        selected: a.edgeStyle == e,
                        onTap: () => _set(a.copyWith(edgeStyle: e)),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                _label('Text edge color'),
                Opacity(
                  opacity: a.edgeStyle == SubtitleEdgeStyle.none ? 0.4 : 1,
                  child: _SwatchRow(
                    selected: a.edgeColor,
                    onSelected: (c) => _set(a.copyWith(edgeColor: c)),
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: _gold,
                  checkColor: Colors.black,
                  controlAffinity: ListTileControlAffinity.trailing,
                  title: const Text('Bold text',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  value: a.bold,
                  onChanged: (v) => _set(a.copyWith(bold: v ?? false)),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _cardBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.cast, color: Colors.white38, size: 20),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'This style does not apply to your TV while casting '
                          ,
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static void _set(SubtitleAppearance a) =>
      SubtitleAppearanceSettings.update(a);

  static Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  static Widget _themedSlider({
    required double value,
    required ValueChanged<double> onChanged,
    double max = 1,
  }) =>
      SliderTheme(
        data: const SliderThemeData(
          activeTrackColor: _gold,
          thumbColor: _gold,
          inactiveTrackColor: Colors.white24,
          trackHeight: 2,
        ),
        child: Slider(value: value.clamp(0.0, max), max: max, onChanged: onChanged),
      );

  static Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    String? fontFamily,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? _gold.withValues(alpha: 0.18) : _cardBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? _gold : Colors.white12),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? _gold : Colors.white70,
              fontSize: 14,
              fontFamily: fontFamily,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}

/// Preview picture with the live-styled sample subtitle and the vertical
/// height slider on its left (top = higher subtitles).
class _Preview extends StatelessWidget {
  final SubtitleAppearance appearance;
  const _Preview({required this.appearance});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 190,
      child: Row(
        children: [
          SliderTheme(
            data: const SliderThemeData(
              activeTrackColor: _gold,
              thumbColor: _gold,
              inactiveTrackColor: Colors.white24,
              trackHeight: 2,
            ),
            child: RotatedBox(
              quarterTurns: 3,
              child: SizedBox(
                width: 190,
                child: Slider(
                  value: appearance.bottomOffset
                      .clamp(0.0, kSubtitleMaxBottomOffset),
                  max: kSubtitleMaxBottomOffset,
                  onChanged: (v) => SubtitleAppearanceSettings.update(
                    appearance.copyWith(bottomOffset: v),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: LayoutBuilder(
                builder: (context, c) {
                  // Same proportions the player uses: size and gap are
                  // fractions of the picture height.
                  final h = c.maxHeight;
                  final size = (h * kSubtitleHeightRatio * appearance.sizeScale)
                      .clamp(kSubtitleMinFontSize,
                          kSubtitleMaxFontSize * appearance.sizeScale);
                  return Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xff3A4A5C), Color(0xff1B222B)],
                      ),
                    ),
                    alignment: Alignment.bottomCenter,
                    padding: EdgeInsets.only(
                      left: 12,
                      right: 12,
                      bottom: h * appearance.bottomOffset,
                    ),
                    child: Text(
                      'Subtitle Preview',
                      textAlign: TextAlign.center,
                      style: subtitleTextStyleFor(appearance, fontSize: size),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwatchRow extends StatelessWidget {
  final Color selected;
  final ValueChanged<Color> onSelected;
  const _SwatchRow({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            for (final c in kSubtitleSwatches)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(c),
                  child: Container(
                    color: c,
                    alignment: Alignment.center,
                    child: c.toARGB32() == selected.toARGB32()
                        ? Icon(
                            Icons.check,
                            size: 16,
                            color: c.computeLuminance() > 0.5
                                ? Colors.black
                                : Colors.white,
                          )
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SizeRow extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  const _SizeRow({required this.selectedIndex, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < kSubtitleSizeScales.length; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelected(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                'A',
                style: TextStyle(
                  fontSize: 14 + i * 6.0,
                  fontWeight: FontWeight.w700,
                  color: i == selectedIndex ? _gold : Colors.white54,
                  decoration: i == selectedIndex
                      ? TextDecoration.underline
                      : TextDecoration.none,
                  decorationColor: _gold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
