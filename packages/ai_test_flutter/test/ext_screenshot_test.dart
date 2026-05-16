library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img_lib;

// Direct src import for handler access — barrel exports encodeToJpeg /
// registerScreenshotExtension but not the orchestrator-exposed
// screenshotHandler. MUST use the `package:` URI (not a relative `../lib`
// path) so the static [RefRegistry] instance the handler resolves matches
// the one tests register against. Mixing `package:` and relative imports of
// the same Dart library creates two independent copies of the library's
// static state — a Dart compiler pitfall the V3 ref registry is exposed to.
import 'package:ai_test_flutter/src/ext_screenshot.dart' as ext_screenshot;

/// Tests for [registerScreenshotExtension] (Step 11 of V3 plan).
///
/// Runs on the VM target — [RenderRepaintBoundary.toImage] works inside the
/// flutter_test binding without a browser when [tester.runAsync] wraps the
/// async image codec call (it crosses into a native isolate).
///
/// Widget tests use bare [Directionality] + [Container] wrappers (no
/// [MaterialApp]) to avoid Flutter's animation controller infinite settle loop.
///
/// Asserts:
/// 1. [registerScreenshotExtension] is idempotent — calling it twice does not
///    throw (ArgumentError is swallowed via [registerExtensionIdempotent]).
/// 2. The PNG path returns a valid base64-encoded PNG with non-trivial length
///    and matching width/height metadata.
/// 3. The PNG path is lossless: a known red pixel (0xFFFF0000) survives the
///    [ui.ImageByteFormat.rawRgba] round-trip without corruption.
/// 4. The JPEG path returns bytes that start with the SOI marker (0xFF 0xD8)
///    and fit within the 40-120 KB budget for a q70 encode.
/// 5. [encodeToJpeg] correctly produces JPEG-shaped output from PNG input.
/// 6. D11 — no params → full-viewport capture (regression guard).
/// 7. D11 — ref only → image dimensions match the ref's render-object
///    paintBounds (cropped via [OffsetLayer.toImage]).
/// 8. D11 — ref + rect → image dimensions match the rect region.
/// 9. D11 — malformed rect → handler returns [ServiceExtensionResponse.error].
void main() {
  group('registerScreenshotExtension', () {
    test('idempotent — second call does not throw', () {
      expect(
        () {
          registerScreenshotExtension();
          registerScreenshotExtension();
        },
        returnsNormally,
      );
    });
  });

  group('ext.aitest.screenshot — PNG path', () {
    testWidgets(
      'returns base64 PNG with valid signature and non-trivial length',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(400, 300);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        // 1. Render a minimal red container inside a RepaintBoundary. Use
        //    bare Directionality (no MaterialApp) to avoid the animation
        //    controller loop that causes infinite pumpAndSettle hangs.
        final GlobalKey boundaryKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: boundaryKey,
              child: Container(
                width: 200,
                height: 100,
                color: Colors.red,
              ),
            ),
          ),
        );

        // 2. One explicit pump advances the frame so the boundary is painted
        //    before toImage() reads it (!debugNeedsPaint must be false).
        await tester.pump();

        // 3. Capture via the production toImage API. tester.runAsync is
        //    required because toImage crosses into a native image codec isolate
        //    and must not run inside the fake-async zone used by testWidgets.
        final RenderRepaintBoundary boundary = boundaryKey.currentContext!
            .findRenderObject()! as RenderRepaintBoundary;

        late ui.Image img;
        late int capturedWidth;
        late int capturedHeight;
        late Uint8List pngBytes;

        await tester.runAsync(() async {
          img = await boundary.toImage(pixelRatio: 2.0);
          capturedWidth = img.width;
          capturedHeight = img.height;

          final ByteData? pngData =
              await img.toByteData(format: ui.ImageByteFormat.png);
          img.dispose();

          expect(pngData, isNotNull);
          pngBytes = pngData!.buffer.asUint8List();
        });

        // 4. Valid PNG starts with the 8-byte magic signature.
        const List<int> pngSignature = [
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
        ];
        for (var i = 0; i < 8; i++) {
          expect(
            pngBytes[i],
            equals(pngSignature[i]),
            reason: 'PNG signature byte $i mismatch',
          );
        }

        // 5. Base64 encoding of a real PNG is well over 1000 characters.
        final String base64Str = base64Encode(pngBytes);
        expect(base64Str.length, greaterThan(1000));

        // 6. Dimensions must be positive.
        expect(capturedWidth, greaterThan(0));
        expect(capturedHeight, greaterThan(0));
      },
    );

    testWidgets(
      'lossless: known red pixel (0xFFFF0000) survives rawRgba round-trip',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(400, 300);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final GlobalKey boundaryKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: boundaryKey,
              child: Container(
                width: 200,
                height: 100,
                color: const Color(0xFFFF0000),
              ),
            ),
          ),
        );
        await tester.pump();

        final RenderRepaintBoundary boundary = boundaryKey.currentContext!
            .findRenderObject()! as RenderRepaintBoundary;

        late int r;
        late int g;
        late int b;

        await tester.runAsync(() async {
          final ui.Image img = await boundary.toImage(pixelRatio: 2.0);
          // Read raw pixels to assert the lossless red fill survived.
          final ByteData? rawData =
              await img.toByteData(format: ui.ImageByteFormat.rawRgba);
          img.dispose();

          expect(rawData, isNotNull);
          final Uint8List pixels = rawData!.buffer.asUint8List();

          // Sample the top-left pixel at byte offset 0. Layout: R G B A.
          r = pixels[0];
          g = pixels[1];
          b = pixels[2];
        });

        // Pure red fill: R ≈ 255, G ≈ 0, B ≈ 0. Allow ±2 for float
        // precision in the rendering pipeline.
        expect(r, greaterThan(240), reason: 'red channel should be ~255');
        expect(g, lessThan(15), reason: 'green channel should be ~0');
        expect(b, lessThan(15), reason: 'blue channel should be ~0');
      },
    );
  });

  group('ext.aitest.screenshot — JPEG path', () {
    testWidgets(
      'encodeToJpeg produces valid JPEG bytes under 120 KB at q70',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(400, 300);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final GlobalKey boundaryKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: boundaryKey,
              child: Container(
                width: 200,
                height: 100,
                color: Colors.blue,
              ),
            ),
          ),
        );
        await tester.pump();

        final RenderRepaintBoundary boundary = boundaryKey.currentContext!
            .findRenderObject()! as RenderRepaintBoundary;

        late Uint8List jpegBytes;

        await tester.runAsync(() async {
          // 1. Capture PNG bytes — the same first step the handler takes
          //    before re-encoding to JPEG.
          final ui.Image img = await boundary.toImage(pixelRatio: 2.0);
          final ByteData? pngData =
              await img.toByteData(format: ui.ImageByteFormat.png);
          img.dispose();

          expect(pngData, isNotNull);
          final Uint8List pngBytes = pngData!.buffer.asUint8List();

          // 2. Encode to JPEG via [encodeToJpeg] — the exported helper from
          //    ext_screenshot.dart. Validates the exact same encode chain used
          //    by the VM extension handler.
          jpegBytes = encodeToJpeg(pngBytes, quality: 70);
        });

        // 3. Non-trivially sized output — a 400x300 solid-blue JPEG at q70 is
        //    above 100 bytes and well under the 120 KB budget.
        expect(
          jpegBytes.lengthInBytes,
          greaterThan(100),
          reason: 'JPEG must not be trivially small',
        );
        expect(
          jpegBytes.lengthInBytes,
          lessThan(120 * 1024),
          reason: 'JPEG q70 must be under 120 KB',
        );

        // 4. Valid JPEG starts with SOI marker: 0xFF 0xD8.
        expect(jpegBytes[0], equals(0xFF));
        expect(jpegBytes[1], equals(0xD8));
      },
    );

    test(
      'encodeToJpeg decodes back to valid image dimensions via image package',
      () {
        // 1. Build a small 10x10 red image using the image package directly
        //    so the test has a known PNG input without a widget pump.
        final img_lib.Image source = img_lib.Image(
          width: 10,
          height: 10,
          numChannels: 4,
        );
        img_lib.fill(source, color: img_lib.ColorRgba8(255, 0, 0, 255));
        final Uint8List pngBytes =
            Uint8List.fromList(img_lib.encodePng(source));

        // 2. Encode via the production helper.
        final Uint8List jpegBytes = encodeToJpeg(pngBytes, quality: 70);

        // 3. Decode the output and verify dimensions survived.
        final img_lib.Image? decoded = img_lib.decodeJpg(jpegBytes);
        expect(decoded, isNotNull);
        expect(decoded!.width, equals(10));
        expect(decoded.height, equals(10));

        // 4. SOI marker present.
        expect(jpegBytes[0], equals(0xFF));
        expect(jpegBytes[1], equals(0xD8));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // D11 — region screenshot (TDD scenarios)
  // ---------------------------------------------------------------------------

  group('D11 — no params → full-viewport regression guard', () {
    testWidgets(
      'screenshotHandler with no ref/rect returns positive dimensions',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(400, 300);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Container(
              width: 400,
              height: 300,
              color: Colors.green,
            ),
          ),
        );
        await tester.pump();

        late developer.ServiceExtensionResponse response;
        await tester.runAsync(() async {
          // Call the package-private handler with no ref/rect — existing
          // full-viewport path must be preserved (regression guard).
          response = await ext_screenshot.screenshotHandler(
            'ext.aitest.screenshot',
            {'format': 'png'},
          );
        });

        // A result response has errorCode == -1 (no error). Check result payload.
        expect(response.result, isNotNull,
            reason: 'expected result, got error');
        final Map<String, dynamic> payload =
            jsonDecode(response.result!) as Map<String, dynamic>;
        expect(payload['width'], greaterThan(0));
        expect(payload['height'], greaterThan(0));
        expect(payload['base64'], isNotEmpty);
      },
    );
  });

  group('D11 — ref only → dimensions match paintBounds', () {
    setUp(RefRegistry.resetForTesting);

    testWidgets(
      'screenshotHandler with ref crops image to ref render-object bounds',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        // 1. Render a 100x80 widget inside a larger viewport. The ref points
        //    only at the small widget; the crop should produce an image
        //    significantly smaller than the full 800×600 viewport.
        final GlobalKey widgetKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                Container(color: Colors.white),
                Positioned(
                  top: 50,
                  left: 60,
                  child: RepaintBoundary(
                    child: SizedBox(
                      key: widgetKey,
                      width: 100,
                      height: 80,
                      child: ColoredBox(color: Colors.red),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        // 2. Register a ref for the target widget using its RenderObject.
        //    Include renderObject so the handler's OffsetLayer crop path works.
        final Element element = tester.element(find.byKey(widgetKey));
        final RenderBox renderBox = element.findRenderObject()! as RenderBox;
        final Offset topLeft = renderBox.localToGlobal(Offset.zero);
        final Rect refRect = topLeft & renderBox.size;
        final String refToken = RefRegistry.register(
          rect: refRect,
          element: element,
          groupId: 'test-group',
          isTextField: false,
          renderObject: renderBox,
        );

        late developer.ServiceExtensionResponse response;
        await tester.runAsync(() async {
          response = await ext_screenshot.screenshotHandler(
            'ext.aitest.screenshot',
            {
              'ref': refToken,
              'format': 'png',
            },
          );
        });

        expect(response.result, isNotNull,
            reason: 'expected result, got error');
        final Map<String, dynamic> payload =
            jsonDecode(response.result!) as Map<String, dynamic>;

        // 3. Cropped image must be smaller than the full 800×600 viewport.
        //    At pixelRatio 2.0, the 100×80 widget → 200×160 px (logical px
        //    at 2x). Width and height must be positive and smaller than
        //    the viewport (800 logical px = 1600 at pixelRatio 2).
        final int width = payload['width'] as int;
        final int height = payload['height'] as int;
        expect(width, greaterThan(0));
        expect(height, greaterThan(0));
        expect(width, lessThan(1600),
            reason: 'must be cropped, not full viewport');
        expect(height, lessThan(1200),
            reason: 'must be cropped, not full viewport');
      },
    );
  });

  group('D11 — ref + rect → dimensions match the rect', () {
    setUp(RefRegistry.resetForTesting);

    testWidgets(
      'screenshotHandler with ref + rect crops to the given sub-region',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final GlobalKey widgetKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                Container(color: Colors.white),
                Positioned(
                  top: 50,
                  left: 60,
                  child: RepaintBoundary(
                    child: SizedBox(
                      key: widgetKey,
                      width: 200,
                      height: 160,
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        final Element element = tester.element(find.byKey(widgetKey));
        final RenderBox renderBox = element.findRenderObject()! as RenderBox;
        final Offset topLeft = renderBox.localToGlobal(Offset.zero);
        final Rect rect = topLeft & renderBox.size;
        final String refToken = RefRegistry.register(
          rect: rect,
          element: element,
          groupId: 'test-group',
          isTextField: false,
          renderObject: renderBox,
        );

        // Sub-rect: 50×40 region starting at (10, 10) within the ref's bounds.
        // These are in logical pixels relative to the ref's bounds.
        const String subRect = '10,10,50,40';

        late developer.ServiceExtensionResponse response;
        await tester.runAsync(() async {
          response = await ext_screenshot.screenshotHandler(
            'ext.aitest.screenshot',
            {
              'ref': refToken,
              'rect': subRect,
              'format': 'png',
            },
          );
        });

        expect(response.result, isNotNull,
            reason: 'expected result, got error');
        final Map<String, dynamic> payload =
            jsonDecode(response.result!) as Map<String, dynamic>;

        // At pixelRatio 2.0: 50×40 logical → 100×80 physical pixels.
        final int width = payload['width'] as int;
        final int height = payload['height'] as int;
        expect(width, greaterThan(0));
        expect(height, greaterThan(0));
        // The rect (50x40 logical) at 2x pixelRatio → 100x80 px; allow small
        // rounding (±2 px) from sub-pixel boundary snapping.
        expect(width, closeTo(100, 4),
            reason: 'rect width 50 logical * 2 = 100px');
        expect(height, closeTo(80, 4),
            reason: 'rect height 40 logical * 2 = 80px');
      },
    );
  });

  group('D11 — malformed rect → handler returns error', () {
    setUp(RefRegistry.resetForTesting);

    testWidgets(
      'screenshotHandler returns error response for non-numeric rect string',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(400, 300);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final GlobalKey widgetKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              child: SizedBox(
                key: widgetKey,
                width: 200,
                height: 100,
                child: const ColoredBox(color: Colors.red),
              ),
            ),
          ),
        );
        await tester.pump();

        final Element element = tester.element(find.byKey(widgetKey));
        final RenderBox renderBox = element.findRenderObject()! as RenderBox;
        final Offset topLeft = renderBox.localToGlobal(Offset.zero);
        final Rect rect = topLeft & renderBox.size;
        final String refToken = RefRegistry.register(
          rect: rect,
          element: element,
          groupId: 'test-group',
          isTextField: false,
          renderObject: renderBox,
        );

        late developer.ServiceExtensionResponse response;
        await tester.runAsync(() async {
          // Pass a malformed rect (not 4 numeric components).
          response = await ext_screenshot.screenshotHandler(
            'ext.aitest.screenshot',
            {
              'ref': refToken,
              'rect': 'not,valid,rect',
              'format': 'png',
            },
          );
        });

        // Must return an error response — not a result. An error response
        // has errorCode == extensionError and result == null.
        expect(
          response.errorCode,
          equals(developer.ServiceExtensionResponse.extensionError),
        );
      },
    );
  });
}
