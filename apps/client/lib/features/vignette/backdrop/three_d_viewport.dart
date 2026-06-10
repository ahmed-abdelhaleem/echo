import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:flutter/widgets.dart';

import 'three_d_viewport_stub.dart'
    if (dart.library.io) 'three_d_viewport_io.dart'
    if (dart.library.js_interop) 'three_d_viewport_web.dart' as platform;

Widget buildThreeDViewport(BuildContext context, AssetScene scene) {
  return platform.buildThreeDViewport(context, scene);
}
