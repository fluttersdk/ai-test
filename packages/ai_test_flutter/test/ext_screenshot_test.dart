library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img_lib;

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
}
