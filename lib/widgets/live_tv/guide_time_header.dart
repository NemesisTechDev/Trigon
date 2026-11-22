import 'package:flutter/material.dart';

import '../../utils/epg_utils.dart';

class GuideTimeHeader extends StatelessWidget {
  const GuideTimeHeader({
    super.key,
    required this.controller,
    required this.leadingWidth,
  });

  final ScrollController controller;
  final double leadingWidth;

  @override
  Widget build(BuildContext context) {
    final times = List.generate(
      EpgUtils.hoursInGuide,
      (hour) => '${hour.toString().padLeft(2, '0')}:00',
    );

    return SizedBox(
      height: 55,
      child: Row(
        children: [
          SizedBox(width: leadingWidth),
          Expanded(
            child: ListView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              itemCount: times.length,
              itemBuilder: (context, index) => SizedBox(
                width: EpgUtils.hourWidth,
                child: Center(
                  child: Text(
                    times[index],
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
