import 'package:echo_client/features/vignette/assets/asset_cache.dart';

import 'asset_file_store_stub.dart'
    if (dart.library.io) 'asset_file_store_io.dart' as platform;

AssetFileStore createAssetFileStore() => platform.createAssetFileStore();
