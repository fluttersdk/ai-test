import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img_lib;

import 'v3_plugin.dart';
import 'v3_register.dart';

/// Registers the `ext.aitest.screenshot` VM Service extension.
///
/// The extension captures the current app frame as a JPEG (default, q70) or
/// PNG image and returns a base64-encoded payload with size metadata. The
/// JPEG default keeps payloads in the 40-120 KB range; PNG is opt-in for
/// lossless use cases (e.g., pixel-exact test assertions).
///
/// Call this from the Wave 3 aggregator (`registerAllAiTestExtensions`) — it
/// is a no-op per extension name on repeated calls via
/// [registerExtensionIdempotent].
void registerScreenshotExtension() {
  registerExtensionIdempotent(
    'ext.aitest.screenshot',
    _screenshotHandler,
  );
}

/// Handler for `ext.aitest.screenshot`.
///
/// Accepted parameters:
///
/// | Name      | Type   | Default  | Notes                                    |
/// |-----------|--------|----------|------------------------------------------|
/// | `ref`     | String | absent   | If absent, uses the app root boundary    |
/// | `format`  | String | `'jpeg'` | `'png'` for lossless, `'jpeg'` for q70  |
/// | `quality` | int    | 70       | JPEG quality 1-100 (ignored for PNG)     |
///
/// Returns JSON:
/// ```json
/// { "format": "jpeg", "base64": "<base64>", "width": 2880, "height": 1800 }
/// ```
Future<developer.ServiceExtensionResponse> _screenshotHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    final String format = params['format'] ?? 'jpeg';
    final int quality = int.tryParse(params['quality'] ?? '') ?? 70;

    // 1. Resolve the RenderRepaintBoundary. When `ref` is absent fall back to
    //    the app-root boundary registered by AiTestPluginV3 at install time.
    final RenderRepaintBoundary boundary = _resolveBoundary(params['ref']);

    // 2. Rasterise the current frame at 2× device pixels for retina fidelity.
    //    toImage() asserts !debugNeedsPaint — called only after a paint phase.
    final ui.Image img = await boundary.toImage(pixelRatio: 2.0);
    final int width = img.width;
    final int height = img.height;

    // 3. Encode to the requested format and base64-encode the byte stream.
    final String base64Payload;
    if (format == 'png') {
      // 3a. PNG path: lossless, larger payload (~300-800 KB for a full HD
      //     screen at 2x). Use only when pixel-exact output is required.
      final ByteData? byteData =
          await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();

      if (byteData == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          'toByteData returned null for PNG format',
        );
      }

      base64Payload = base64Encode(byteData.buffer.asUint8List());
    } else {
      // 3b. JPEG path (default): lossy q70 encode via the `image` package.
      //     Steps: toImage() → PNG bytes → decodePng → encodeJpg. This keeps
      //     payloads in the 40-120 KB range for typical app screens.
      final ByteData? pngByteData =
          await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();

      if (pngByteData == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          'toByteData returned null for intermediate PNG (JPEG path)',
        );
      }

      final Uint8List pngBytes = pngByteData.buffer.asUint8List();
      final Uint8List jpegBytes = encodeToJpeg(pngBytes, quality: quality);
      base64Payload = base64Encode(jpegBytes);
    }

    // 4. Return the payload with format, encoded bytes, and dimensions.
    return developer.ServiceExtensionResponse.result(
      jsonEncode(<String, dynamic>{
        'format': format == 'png' ? 'png' : 'jpeg',
        'base64': base64Payload,
        'width': width,
        'height': height,
      }),
    );
  } catch (e, stackTrace) {
    developer.log(
      '[ai-test-v3] ext.aitest.screenshot error: $e\n$stackTrace',
      name: 'ai-test',
    );
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

/// Resolves the [RenderRepaintBoundary] to capture.
///
/// When [ref] is non-null and non-empty this function logs a warning and falls
/// back to [AiTestPluginV3.rootRepaintBoundaryKey] — full Semantics-node-id to
/// RenderObject mapping lands in the snapshot extension (Step 6) and will wire
/// ref-based boundary resolution at that point.
///
/// Throws [StateError] when the root boundary is unavailable (plugin not
/// installed or main.dart not wrapped with [RepaintBoundary]).
RenderRepaintBoundary _resolveBoundary(String? ref) {
  if (ref != null && ref.isNotEmpty) {
    // Full ref → element lookup lands in Step 6 (snapshot). Until then, log
    // and fall through to the root boundary so whole-screen captures work.
    developer.log(
      '[ai-test-v3] screenshot: ref="$ref" lookup not yet implemented; '
      'falling back to root boundary',
      name: 'ai-test',
    );
  }

  final BuildContext? context =
      AiTestPluginV3.rootRepaintBoundaryKey.currentContext;
  if (context == null) {
    throw StateError(
      'ext.aitest.screenshot: rootRepaintBoundaryKey has no currentContext. '
      'Ensure AiTestPluginV3.install() was called and main.dart wraps the '
      'app root in RepaintBoundary(key: AiTestPluginV3.rootRepaintBoundaryKey).',
    );
  }

  final RenderObject? renderObject = context.findRenderObject();
  if (renderObject is! RenderRepaintBoundary) {
    throw StateError(
      'ext.aitest.screenshot: rootRepaintBoundaryKey is not backed by a '
      'RenderRepaintBoundary. Found: ${renderObject.runtimeType}',
    );
  }

  return renderObject;
}

/// Encodes PNG [bytes] to JPEG at the given [quality] using the `image`
/// package (v4.x, pure-Dart, cross-platform, no platform channels).
///
/// Steps:
/// 1. Decode the PNG bytes via [img_lib.decodePng] into the package's
///    intermediate [img_lib.Image] representation.
/// 2. Re-encode via [img_lib.encodeJpg] at the requested [quality].
///
/// Throws [ArgumentError] when [bytes] is not valid PNG data or [quality] is
/// outside 1-100.
///
/// Exposed as a top-level function (not private) so the test suite can
/// validate the exact same encode chain as the VM extension handler.
Uint8List encodeToJpeg(Uint8List bytes, {required int quality}) {
  if (quality < 1 || quality > 100) {
    throw ArgumentError.value(
      quality,
      'quality',
      'JPEG quality must be in the range 1-100',
    );
  }

  // 1. Decode PNG into the image package's intermediate representation.
  final img_lib.Image? decoded = img_lib.decodePng(bytes);
  if (decoded == null) {
    throw ArgumentError('encodeToJpeg: input bytes are not valid PNG data');
  }

  // 2. Encode to JPEG at the requested quality. encodeJpg returns a List<int>
  //    which we convert to Uint8List for typed binary handling downstream.
  return Uint8List.fromList(img_lib.encodeJpg(decoded, quality: quality));
}
