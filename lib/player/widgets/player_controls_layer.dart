import 'package:flutter/material.dart';

import 'player_controls.dart';

class PlayerControlsLayer extends StatelessWidget {

  final bool visible;

  const PlayerControlsLayer({
    super.key,
    required this.visible,
  });

  @override
  Widget build(BuildContext context) {

    return PlayerControls(
      visible: visible,
    );

  }
}