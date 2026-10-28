import 'dart:io';

import 'package:airbridge_mobile/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AirbridgeVersion', () {
    test('orders numeric preview identifiers numerically', () {
      final preview2 = AirbridgeVersion.tryParse('v4.0.0-preview.2')!;
      final preview10 = AirbridgeVersion.tryParse('v4.0.0-preview.10')!;
      expect(preview10.compareTo(preview2), greaterThan(0));
    });

    test('stable versions sort after their pre-releases', () {
      final stable = AirbridgeVersion.tryParse('v4.0.0')!;
      final preview = AirbridgeVersion.tryParse('4.0.0-preview.99')!;
      expect(stable.compareTo(preview), greaterThan(0));
    });

    test('rejects malformed tags', () {
      expect(AirbridgeVersion.tryParse('latest'), isNull);
      expect(AirbridgeVersion.tryParse('v4.0'), isNull);
    });
  });

  group('pre-release selection', () {
    final publishedAt = DateTime.utc(2026, 10, 25);

    UpdateRelease release(
      String tag, {
      bool prerelease = true,
      bool draft = false,
    }) =>
        UpdateRelease(
          tagName: tag,
          isPrerelease: prerelease,
          isDraft: draft,
          publishedAt: publishedAt,
          assets: const <UpdateAsset>[],
        );

    test('selects the highest newer pre-release and skips stable/draft tags', () {
      final releases = <UpdateRelease>[
        release('v5.0.0', prerelease: false),
        release('v4.0.0-preview.9'),
        release('v4.0.0-preview.12'),
        release('v9.0.0-preview.1', draft: true),
      ];

      expect(
        selectNewerPrerelease(releases, 'v4.0.0-preview.2')?.tagName,
        'v4.0.0-preview.12',
      );
      expect(
        selectNewerPrerelease(releases, 'v4.0.0-preview.12')?.tagName,
        isNull,
      );
    });

    test('finds the latest pre-release independently of stable releases', () {
      final releases = <UpdateRelease>[
        release('v6.0.0', prerelease: false),
        release('v4.0.0-preview.3'),
        release('v4.0.0-preview.4'),
      ];
      expect(latestPrerelease(releases)?.tagName, 'v4.0.0-preview.4');
    });
  });

  test('maps release tags to the native installer names', () {
    expect(
      updateAssetNameFor(UpdatePlatform.windows, 'v4.0.0-preview.2'),
      'Airbridge-Windows-Setup-4.0.0.exe',
    );
    expect(
      updateAssetNameFor(UpdatePlatform.linux, 'v4.0.0-preview.2'),
      'Airbridge-Linux-x86_64.AppImage',
    );
    expect(
      updateAssetNameFor(UpdatePlatform.macos, 'v4.0.0-preview.2'),
      'Airbridge-macOS.dmg',
    );
    expect(updateAssetNameFor(UpdatePlatform.ios, 'v4.0.0-preview.2'), isNull);
  });

  test('parses and validates release checksum manifests', () {
    final checksum = List<String>.filled(64, 'a').join();
    final otherChecksum = List<String>.filled(64, 'b').join();
    final parsed = parseSha256Manifest(
      '$checksum  Airbridge-Android.apk\n$otherChecksum *Airbridge-macOS.dmg\n',
    );
    expect(parsed['Airbridge-Android.apk'], checksum);
    expect(parsed['Airbridge-macOS.dmg'], otherChecksum);
    expect(
      () => parseSha256Manifest('not a sha256 manifest'),
      throwsFormatException,
    );
  });

  test('reports mobile OS install limits without opening an installer', () async {
    final support = await Directory.systemTemp.createTemp('airbridge-updater-test-');
    final service = AutoUpdateService(
      supportDirectory: support,
      releaseTag: 'v4.0.0-preview.1',
      platform: UpdatePlatform.android,
      releaseFetcher: () async => <UpdateRelease>[
        UpdateRelease(
          tagName: 'v4.0.0-preview.2',
          isPrerelease: true,
          isDraft: false,
          publishedAt: DateTime.utc(2026, 10, 25),
          assets: const <UpdateAsset>[],
        ),
      ],
    );

    addTearDown(() async {
      service.dispose();
      await support.delete(recursive: true);
    });

    await service.checkForUpdates(force: true);

    expect(service.latestTag, 'v4.0.0-preview.2');
    expect(service.updateAvailable, isTrue);
    expect(service.status, contains('Android requires OS approval'));
    expect(File('${support.path}${Platform.pathSeparator}updates${Platform.pathSeparator}pending.json').existsSync(), isFalse);
  });
}
