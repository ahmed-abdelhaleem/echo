// Pure-Dart glTF/GLB scene composer (T-CLIENT-201).
//
// The web viewport renders a single `<model-viewer>`, which loads one model.
// To show the *full* composed vignette scene on web (parity with the native
// Thermion path, which already loads every layer), we merge the scene's asset
// GLBs into ONE GLB: each source's geometry is kept, and each source is parented
// under a wrapper node carrying that asset's authored **world matrix** (TRS +
// anchor chain, resolved upstream from the VignetteScene). The merged GLB is
// handed to `<model-viewer>` as a data URL. The legacy parallax path expresses
// itself as a translation-only matrix, so there is a single placement codepath.
//
// Scope / correctness: this handles the GLBs Echo produces today — embedded
// single-buffer GLBs with geometry + simple PBR materials (the dev generator
// and typical provider exports). It deliberately **bails (returns null)** on
// anything it cannot merge losslessly — external/multi buffers, `images`,
// `animations`, `skins`, `cameras`, sparse accessors, or any `extensionsRequired`
// (e.g. Draco / EXT_meshopt_compression). Callers fall back to rendering the
// first asset alone, so a scene is never rendered *wrong* — at worst it renders
// partially until the richer baked-scene path (T-CONTENT-200) lands.
//
// This file is pure byte/JSON manipulation with no platform imports, so it is
// unit-tested on the VM without a device (see test/.../glb_scene_composer_test.dart).

import 'dart:convert';
import 'dart:typed_data';

const int _glbMagic = 0x46546C67; // "glTF"
const int _glbVersion = 2;
const int _jsonChunkType = 0x4E4F534A; // "JSON"
const int _binChunkType = 0x004E4942; // "BIN\0"

/// One asset to compose: its GLB bytes and the column-major (glTF `node.matrix`)
/// world transform to place it at within the merged scene. The matrix carries
/// the asset's resolved TRS + anchor chain; the legacy parallax placement is a
/// translation-only matrix.
class GlbScenePart {
  const GlbScenePart({required this.glb, required this.matrix});

  final Uint8List glb;

  /// 16 doubles, column-major. `matrix[12..14]` is the translation column.
  final List<double> matrix;
}

/// Merge [parts] (back-to-front) into a single GLB, or return null if any part
/// uses a feature the merger does not support losslessly.
Uint8List? composeSceneGlb(List<GlbScenePart> parts) {
  if (parts.isEmpty) return null;
  if (parts.length == 1) return parts.first.glb;

  final merged = _MergedDoc();
  for (final part in parts) {
    final parsed = _parseGlb(part.glb);
    if (parsed == null) return null; // unsupported / malformed → bail
    if (!merged.append(parsed, part.matrix)) return null;
  }
  return merged.toGlb();
}

class _ParsedGlb {
  _ParsedGlb(this.doc, this.bin);
  final Map<String, dynamic> doc;
  final Uint8List bin;
}

_ParsedGlb? _parseGlb(Uint8List data) {
  if (data.lengthInBytes < 20) return null;
  final view = ByteData.sublistView(data);
  if (view.getUint32(0, Endian.little) != _glbMagic) return null;
  if (view.getUint32(4, Endian.little) != _glbVersion) return null;
  if (view.getUint32(8, Endian.little) != data.lengthInBytes) return null;

  Map<String, dynamic>? doc;
  Uint8List bin = Uint8List(0);
  var offset = 12;
  while (offset + 8 <= data.lengthInBytes) {
    final chunkLength = view.getUint32(offset, Endian.little);
    final chunkType = view.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    final end = start + chunkLength;
    if (end > data.lengthInBytes) return null;
    if (chunkType == _jsonChunkType) {
      final decoded = json.decode(utf8.decode(data.sublist(start, end)));
      if (decoded is! Map<String, dynamic>) return null;
      doc = decoded;
    } else if (chunkType == _binChunkType) {
      bin = Uint8List.sublistView(data, start, end);
    }
    offset = end;
  }
  if (doc == null) return null;

  // Bail on anything we don't merge losslessly.
  if (doc.containsKey('extensionsRequired')) return null;
  for (final key in const ['images', 'animations', 'skins', 'cameras']) {
    final v = doc[key];
    if (v is List && v.isNotEmpty) return null;
  }
  final buffers = doc['buffers'];
  if (buffers is! List || buffers.length != 1) return null;
  if ((buffers.first as Map).containsKey('uri'))
    return null; // must be embedded
  final accessors = doc['accessors'];
  if (accessors is List) {
    for (final a in accessors) {
      if (a is! Map || a['bufferView'] is! int || a.containsKey('sparse')) {
        return null;
      }
    }
  }
  return _ParsedGlb(doc, bin);
}

class _MergedDoc {
  final List<dynamic> bufferViews = <dynamic>[];
  final List<dynamic> accessors = <dynamic>[];
  final List<dynamic> materials = <dynamic>[];
  final List<dynamic> meshes = <dynamic>[];
  final List<dynamic> nodes = <dynamic>[];
  final List<int> sceneRootNodes = <int>[];
  final BytesBuilder bin = BytesBuilder();

  bool append(_ParsedGlb src, List<double> matrix) {
    final binBase = bin.length; // already 4-aligned (we pad after each append)
    bin.add(src.bin);
    _padTo4(bin);

    final bufferViewBase = bufferViews.length;
    final accessorBase = accessors.length;
    final materialBase = materials.length;
    final meshBase = meshes.length;
    final nodeBase = nodes.length;

    for (final raw in (src.doc['bufferViews'] as List? ?? const [])) {
      final bv = Map<String, dynamic>.from(raw as Map);
      bv['buffer'] = 0;
      bv['byteOffset'] = (bv['byteOffset'] as int? ?? 0) + binBase;
      bufferViews.add(bv);
    }
    for (final raw in (src.doc['accessors'] as List? ?? const [])) {
      final ac = Map<String, dynamic>.from(raw as Map);
      ac['bufferView'] = (ac['bufferView'] as int) + bufferViewBase;
      accessors.add(ac);
    }
    for (final raw in (src.doc['materials'] as List? ?? const [])) {
      materials.add(_deepCopy(raw));
    }
    for (final raw in (src.doc['meshes'] as List? ?? const [])) {
      final mesh = Map<String, dynamic>.from(raw as Map);
      final prims = <dynamic>[];
      for (final praw in (mesh['primitives'] as List? ?? const [])) {
        final prim = Map<String, dynamic>.from(praw as Map);
        final attrs = Map<String, dynamic>.from(prim['attributes'] as Map);
        for (final k in attrs.keys.toList()) {
          attrs[k] = (attrs[k] as int) + accessorBase;
        }
        prim['attributes'] = attrs;
        if (prim['indices'] is int) {
          prim['indices'] = (prim['indices'] as int) + accessorBase;
        }
        if (prim['material'] is int) {
          prim['material'] = (prim['material'] as int) + materialBase;
        }
        prims.add(prim);
      }
      mesh['primitives'] = prims;
      meshes.add(mesh);
    }
    final srcNodes = (src.doc['nodes'] as List? ?? const []);
    for (final raw in srcNodes) {
      final node = Map<String, dynamic>.from(raw as Map);
      if (node['mesh'] is int) node['mesh'] = (node['mesh'] as int) + meshBase;
      if (node['children'] is List) {
        node['children'] = (node['children'] as List)
            .map((c) => (c as int) + nodeBase)
            .toList();
      }
      nodes.add(node);
    }

    // Determine this source's root nodes (scene 0, else all nodes).
    final scenes = src.doc['scenes'] as List?;
    final sceneIndex = src.doc['scene'] as int? ?? 0;
    List<int> roots;
    if (scenes != null && sceneIndex < scenes.length) {
      roots = ((scenes[sceneIndex] as Map)['nodes'] as List? ?? const [])
          .map((n) => (n as int) + nodeBase)
          .toList();
    } else {
      roots = List<int>.generate(srcNodes.length, (i) => i + nodeBase);
    }

    // Parent the source under a wrapper node carrying its world matrix. An
    // identity matrix is omitted so trivially-placed assets stay clean.
    final wrapperIndex = nodes.length;
    nodes.add(<String, dynamic>{
      if (!_isIdentity(matrix)) 'matrix': List<double>.of(matrix),
      if (roots.isNotEmpty) 'children': roots,
    });
    sceneRootNodes.add(wrapperIndex);
    return true;
  }

  Uint8List toGlb() {
    final binBytes = bin.toBytes();
    final doc = <String, dynamic>{
      'asset': <String, dynamic>{
        'version': '2.0',
        'generator': 'echo glb scene composer',
      },
      'scene': 0,
      'scenes': <dynamic>[
        <String, dynamic>{'nodes': sceneRootNodes},
      ],
      'nodes': nodes,
      'meshes': meshes,
      if (materials.isNotEmpty) 'materials': materials,
      'accessors': accessors,
      'bufferViews': bufferViews,
      'buffers': <dynamic>[
        <String, dynamic>{'byteLength': binBytes.lengthInBytes},
      ],
    };

    final List<int> jsonBytes = _padBytes(
      utf8.encode(json.encode(doc)),
      0x20, // pad with spaces to 4 bytes
    );
    final total = 12 + 8 + jsonBytes.length + 8 + binBytes.lengthInBytes;

    final out = BytesBuilder();
    final header = ByteData(12)
      ..setUint32(0, _glbMagic, Endian.little)
      ..setUint32(4, _glbVersion, Endian.little)
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
}

const List<double> _identity = <double>[
  1, 0, 0, 0, //
  0, 1, 0, 0,
  0, 0, 1, 0,
  0, 0, 0, 1,
];

bool _isIdentity(List<double> m) {
  if (m.length != 16) return false;
  for (var i = 0; i < 16; i++) {
    if ((m[i] - _identity[i]).abs() > 1e-12) return false;
  }
  return true;
}

void _padTo4(BytesBuilder builder) {
  while (builder.length % 4 != 0) {
    builder.addByte(0);
  }
}

List<int> _padBytes(List<int> bytes, int pad) {
  final out = List<int>.from(bytes);
  while (out.length % 4 != 0) {
    out.add(pad);
  }
  return out;
}

dynamic _deepCopy(dynamic value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry(k as String, _deepCopy(v)));
  }
  if (value is List) {
    return value.map(_deepCopy).toList();
  }
  return value;
}
