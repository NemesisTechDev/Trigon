import 'dart:async';

import 'package:native_device_orientation/native_device_orientation.dart';

class OrientationService {
  OrientationService._();

  static StreamSubscription<NativeDeviceOrientation>? _subscription;

  static void start(
      void Function(NativeDeviceOrientation) onChanged,
      ) {
    stop();

    _subscription =
        NativeDeviceOrientationCommunicator()
            .onOrientationChanged()
            .listen(onChanged);
  }

  static void stop() {
    _subscription?.cancel();
    _subscription = null;
  }
}