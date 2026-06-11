import 'dart:convert';
import 'dart:typed_data';

import 'package:echo_client/features/vignette/backdrop/glb_scene_composer.dart';
import 'package:flutter_test/flutter_test.dart';

const int _glbMagic = 0x46546C67;
const int _jsonChunkType = 0x4E4F534A;
const int _binChunkType = 0x004E4942;

/// Build a minimal valid GLB (one triangle, one material) for tests.
Uint8List _triangleGlb({Map<String, dynamic>? extraDoc}) {
  final indices = Uint8List.fromList([0, 0, 1, 0, 2, 0]); // uint16 le: 0,1,2
  final positions = Float32List.fromList(<double>[
    0, 0, 0, //
    1, 0, 0,
    0, 1, 0,
  ]);
  final bin = BytesBuilder()
    ..add(indices)
    ..add(Uint8List(2)) // pad indices (6 -> 8) to 4-byte align positions
    ..add(positions.buffer.asUint8List());
  final binBytes = bin.toBytes();

  final doc = <String, dynamic>{
    'asset': <String, dynamic>{'version': '2.0'},
    'scene': 0,
    'scenes': <dynamic>[
      <String, dynamic>{
        'nodes': <int>[0],
      },
    ],
    'nodes': <dynamic>[
      <String, dynamic>{'mesh': 0},
    ],
    'meshes': <dynamic>[
      <String, dynamic>{
        'primitives': <dynamic>[
          <String, dynamic>{
            'attributes': <String, dynamic>{'POSITION': 1},
            'indices': 0,
            'material': 0,
          },
        ],
      },
    ],
    'materials': <dynamic>[
      <String, dynamic>{
        'pbrMetallicRoughness': <String, dynamic>{
          'baseColorFactor': <double>[0.5, 0.5, 0.5, 1.0],
        },
      },
    ],
    'accessors': <dynamic>[
      <String, dynamic>{
        'bufferView': 0,
        'componentType': 5123,
        'count': 3,
        'type': 'SCALAR',
      },
      <String, dynamic>{
        'bufferView': 1,
        'componentType': 5126,
        'count': 3,
        'type': 'VEC3',
        'min': <double>[0, 0, 0],
        'max': <double>[1, 1, 0],
      },
    ],
    'bufferViews': <dynamic>[
      <String, dynamic>{
        'buffer': 0,
        'byteOffset': 0,
        'byteLength': 6,
        'target': 34963,
      },
      <String, dynamic>{
        'buffer': 0,
        'byteOffset': 8,
        'byteLength': 36,
        'target': 34962,
      },
    ],
    'buffers': <dynamic>[
      <String, dynamic>{'byteLength': binBytes.lengthInBytes},
    ],
    ...?extraDoc,
  };

  List<int> jsonBytes = utf8.encode(json.encode(doc));
  while (jsonBytes.length % 4 != 0) {
    jsonBytes = <int>[...jsonBytes, 0x20];
  }
  final total = 12 + 8 + jsonBytes.length + 8 + binBytes.lengthInBytes;
  final out = BytesBuilder();
  final header = ByteData(12)
    ..setUint32(0, _glbMagic, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, total, Endian.little);
  out.add(header.buffer.asUint8List());
  final jsonHeader = ByteData(8)
    ..setUint32(0, jsonBytes.length, Endian.little)
    ..setUint32(4, _jsonChunkType, Endian.little);
  out.add(jsonHeader.buffer.asUint8List());
  out.add(jsonBytes);
  final binHeader = ByteData(8)
    ..setUint32(0, binBytes.lengthInBytes, Endian.little)
    ..setUint32(4, _binChunkType, Endian.little);
  out.add(binHeader.buffer.asUint8List());
  out.add(binBytes);
  return out.toBytes();
}

Map<String, dynamic> _parseGlbJson(Uint8List data) {
  final view = ByteData.sublistView(data);
  expect(view.getUint32(0, Endian.little), _glbMagic);
  expect(view.getUint32(4, Endian.little), 2);
  expect(
    view.getUint32(8, Endian.little),
    data.lengthInBytes,
    reason: 'declared length must equal byte length',
  );
  var offset = 12;
  Map<String, dynamic>? doc;
  while (offset + 8 <= data.lengthInBytes) {
    final len = view.getUint32(offset, Endian.little);
    final type = view.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    if (type == _jsonChunkType) {
      doc = json.decode(utf8.decode(data.sublist(start, start + len)))
          as Map<String, dynamic>;
    }
    offset = start + len;
  }
  return doc!;
}

/// Column-major translation matrix, matching scene_models.translationMatrix.
List<double> _translation(double x, double y, double z) => <double>[
      1, 0, 0, 0, //
      0, 1, 0, 0,
      0, 0, 1, 0,
      x, y, z, 1,
    ];

const List<double> _identity = <double>[
  1, 0, 0, 0, //
  0, 1, 0, 0,
  0, 0, 1, 0,
  0, 0, 0, 1,
];

void main() {
  test('single part passes through unchanged', () {
    final glb = _triangleGlb();
    final result = composeSceneGlb([GlbScenePart(glb: glb, matrix: _identity)]);
    expect(result, same(glb));
  });

  test('two parts merge into one valid GLB with two meshes and two roots', () {
    final a = _triangleGlb();
    final b = _triangleGlb();
    final merged = composeSceneGlb([
      GlbScenePart(glb: a, matrix: _translation(0.5, 0, 0)),
      GlbScenePart(glb: b, matrix: _translation(0, 0, -0.4)),
    ]);

    expect(merged, isNotNull);
    final doc = _parseGlbJson(merged!);

    expect((doc['meshes'] as List).length, 2);
    expect((doc['accessors'] as List).length, 4);
    expect((doc['materials'] as List).length, 2);
    expect((doc['bufferViews'] as List).length, 4);
    expect((doc['buffers'] as List).length, 1);
    // Two source nodes + two wrapper nodes.
    expect((doc['nodes'] as List).length, 4);
    // The scene references the two wrapper roots.
    expect(((doc['scenes'] as List).first as Map)['nodes'], hasLength(2));

    // Second source's accessors must have been re-based onto its bufferViews.
    final secondMeshPrim =
        ((doc['meshes'] as List)[1] as Map)['primitives'] as List;
    final pos =
        ((secondMeshPrim.first as Map)['attributes'] as Map)['POSITION'] as int;
    expect(pos, 3, reason: 'second POSITION accessor re-indexed by +2');

    // Each wrapper node carries its source's world matrix; the translation
    // column (indices 12..14) places the part within the merged scene.
    final wrappers = (doc['nodes'] as List)
        .whereType<Map<String, dynamic>>()
        .where((n) => n.containsKey('matrix'))
        .toList();
    expect(wrappers, hasLength(2));
    final tx = (wrappers.first['matrix'] as List)[12] as num;
    final tz = (wrappers.last['matrix'] as List)[14] as num;
    expect(tx, closeTo(0.5, 1e-9));
    expect(tz, closeTo(-0.4, 1e-9));
  });

  test('an identity placement omits the wrapper matrix', () {
    final merged = composeSceneGlb([
      GlbScenePart(glb: _triangleGlb(), matrix: _identity),
      GlbScenePart(glb: _triangleGlb(), matrix: _translation(0, 0, -0.4)),
    ]);
    final doc = _parseGlbJson(merged!);
    final wrappers = (doc['nodes'] as List)
        .whereType<Map<String, dynamic>>()
        .where((n) => !n.containsKey('mesh')) // wrapper nodes have no mesh
        .toList();
    expect(wrappers, hasLength(2));
    final withMatrix = wrappers.where((n) => n.containsKey('matrix')).toList();
    expect(withMatrix, hasLength(1), reason: 'identity wrapper carries no matrix');
  });

  test('bails (null) when a part requires an unsupported extension', () {
    final plain = _triangleGlb();
    final draco = _triangleGlb(
      extraDoc: <String, dynamic>{
        'extensionsRequired': <String>['KHR_draco_mesh_compression'],
      },
    );
    final result = composeSceneGlb([
      GlbScenePart(glb: plain, matrix: _identity),
      GlbScenePart(glb: draco, matrix: _translation(0, 0, -0.4)),
    ]);
    expect(result, isNull, reason: 'caller falls back to a single asset');
  });

  test('empty input returns null', () {
    expect(composeSceneGlb(const []), isNull);
  });
}
