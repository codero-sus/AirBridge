import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

const String _compiledReleaseTag = String.fromEnvironment(
  'AIRBRIDGE_RELEASE_TAG',
  defaultValue: '',
);

/// The target for which a native update package can be selected.
enum UpdatePlatform { windows, linux, macos, android, ios, unsupported }

/// A strict-enough SemVer value for comparing Airbridge release tags.
///
/// Build metadata is ignored for ordering, as required by SemVer. A `v` prefix
/// is accepted because Airbridge's GitHub tags use names such as
/// `v4.0.0-preview.2`.
@immutable
class AirbridgeVersion implements Comparable<AirbridgeVersion> {
  const AirbridgeVersion({
    required this.major,
    required this.minor,
    required this.patch,
    required this.prerelease,
  });

  static final RegExp _pattern = RegExp(
    r'^[vV]?(\d+)\.(\d+)\.(\d+)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;

  static AirbridgeVersion? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = int.tryParse(match.group(3)!);
    if (major == null || minor == null || patch == null) return null;
    final suffix = match.group(4);
    return AirbridgeVersion(
      major: major,
      minor: minor,
      patch: patch,
      prerelease: suffix == null ? const <String>[] : suffix.split('.'),
    );
  }

  String get baseVersion => '$major.$minor.$patch';

  @override
  int compareTo(AirbridgeVersion other) {
    final coreComparison = major.compareTo(other.major);
    if (coreComparison != 0) return coreComparison;
    final minorComparison = minor.compareTo(other.minor);
    if (minorComparison != 0) return minorComparison;
    final patchComparison = patch.compareTo(other.patch);
    if (patchComparison != 0) return patchComparison;

    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;

    final commonLength = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var index = 0; index < commonLength; index++) {
      final left = prerelease[index];
      final right = other.prerelease[index];
      final leftNumber = BigInt.tryParse(left);
      final rightNumber = BigInt.tryParse(right);
      if (leftNumber != null && rightNumber != null) {
        final comparison = leftNumber.compareTo(rightNumber);
        if (comparison != 0) return comparison;
      } else if (leftNumber != null) {
        return -1;
      } else if (rightNumber != null) {
        return 1;
      } else {
        final comparison = left.compareTo(right);
        if (comparison != 0) return comparison;
      }
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}

@immutable
class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final String downloadUrl;
  final int size;

  factory UpdateAsset.fromJson(Map<String, dynamic> json) => UpdateAsset(
        name: json['name'] as String? ?? '',
        downloadUrl: json['browser_download_url'] as String? ?? '',
        size: json['size'] as int? ?? 0,
      );
}

@immutable
class UpdateRelease {
  const UpdateRelease({
    required this.tagName,
    required this.isPrerelease,
    required this.isDraft,
    required this.publishedAt,
    required this.assets,
  });

  final String tagName;
  final bool isPrerelease;
  final bool isDraft;
  final DateTime publishedAt;
  final List<UpdateAsset> assets;

  AirbridgeVersion? get version => AirbridgeVersion.tryParse(tagName);

  factory UpdateRelease.fromJson(Map<String, dynamic> json) {
    final rawAssets = json['assets'];
    final assets = <UpdateAsset>[];
    if (rawAssets is List) {
      for (final rawAsset in rawAssets) {
        if (rawAsset is Map<String, dynamic>) {
          assets.add(UpdateAsset.fromJson(rawAsset));
        }
      }
    }
    return UpdateRelease(
      tagName: json['tag_name'] as String? ?? '',
      isPrerelease: json['prerelease'] as bool? ?? false,
      isDraft: json['draft'] as bool? ?? false,
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      assets: List<UpdateAsset>.unmodifiable(assets),
    );
  }
}

/// Chooses the highest SemVer pre-release that is newer than [currentTag].
/// Stable releases are intentionally excluded: Airbridge's update channel is
/// the GitHub pre-release channel.
UpdateRelease? selectNewerPrerelease(
  Iterable<UpdateRelease> releases,
  String currentTag,
) {
  final current = AirbridgeVersion.tryParse(currentTag);
  if (current == null) return null;
  UpdateRelease? selected;
  for (final release in releases) {
    final version = release.version;
    if (!release.isPrerelease || release.isDraft || version == null) continue;
    if (version.compareTo(current) <= 0) continue;
    final selectedVersion = selected?.version;
    if (selectedVersion == null || version.compareTo(selectedVersion) > 0) {
      selected = release;
    }
  }
  return selected;
}

UpdateRelease? latestPrerelease(Iterable<UpdateRelease> releases) {
  UpdateRelease? selected;
  for (final release in releases) {
    final version = release.version;
    if (!release.isPrerelease || release.isDraft || version == null) continue;
    final selectedVersion = selected?.version;
    if (selectedVersion == null || version.compareTo(selectedVersion) > 0) {
      selected = release;
    }
  }
  return selected;
}

String? updateAssetNameFor(UpdatePlatform platform, String releaseTag) {
  final version = AirbridgeVersion.tryParse(releaseTag);
  if (version == null) return null;
  return switch (platform) {
    UpdatePlatform.windows => 'Airbridge-Windows-Setup-${version.baseVersion}.exe',
    UpdatePlatform.linux => 'Airbridge-Linux-x86_64.AppImage',
    UpdatePlatform.macos => 'Airbridge-macOS.dmg',
    UpdatePlatform.android => 'Airbridge-Android.apk',
    UpdatePlatform.ios || UpdatePlatform.unsupported => null,
  };
}

Map<String, String> parseSha256Manifest(String contents) {
  final checksums = <String, String>{};
  final linePattern = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$');
  for (final line in const LineSplitter().convert(contents)) {
    if (line.trim().isEmpty) continue;
    final match = linePattern.firstMatch(line);
    if (match == null) {
      throw const FormatException('The release checksum manifest is malformed.');
    }
    final name = match.group(2)!;
    if (checksums.containsKey(name)) {
      throw FormatException('Duplicate checksum entry for $name.');
    }
    checksums[name] = match.group(1)!.toLowerCase();
  }
  return Map<String, String>.unmodifiable(checksums);
}

class AutoUpdateService extends ChangeNotifier {
  AutoUpdateService({
    required this.supportDirectory,
    String? releaseTag,
    UpdatePlatform? platform,
    Future<List<UpdateRelease>> Function()? releaseFetcher,
  })  : releaseTag = releaseTag ?? _compiledReleaseTag,
        platform = platform ?? _currentPlatform(),
        _releaseFetcher = releaseFetcher;

  static const String repository = 'codero-sus/AirBridge';
  static const Duration checkInterval = Duration(hours: 12);
  static const int maxPackageBytes = 1024 * 1024 * 1024;

  final Directory supportDirectory;
  final String releaseTag;
  final UpdatePlatform platform;
  final Future<List<UpdateRelease>> Function()? _releaseFetcher;

  String status = 'Automatic update status will appear here.';
  String? latestTag;
  DateTime? lastCheckedAt;
  bool isChecking = false;
  bool _disposed = false;
  Timer? _periodicTimer;
  String? _applyFailure;

  bool get isOfficialReleaseBuild => AirbridgeVersion.tryParse(releaseTag) != null;
  String get currentVersionLabel => isOfficialReleaseBuild ? releaseTag : 'Local/development build';
  bool get updateAvailable {
    final current = AirbridgeVersion.tryParse(releaseTag);
    final latest = latestTag == null ? null : AirbridgeVersion.tryParse(latestTag!);
    return current != null && latest != null && latest.compareTo(current) > 0;
  }

  static UpdatePlatform _currentPlatform() {
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isLinux) return UpdatePlatform.linux;
    if (Platform.isMacOS) return UpdatePlatform.macos;
    if (Platform.isAndroid) return UpdatePlatform.android;
    if (Platform.isIOS) return UpdatePlatform.ios;
    return UpdatePlatform.unsupported;
  }

  /// Applies an already downloaded package before the Flutter UI is shown.
  /// Returns true when a helper or updated process has been started and the
  /// caller should exit immediately. Mobile platforms never invoke installers.
  Future<bool> applyPendingUpdateBeforeLaunch() async {
    if (!isOfficialReleaseBuild) return false;
    await _restoreStatus();
    final pending = await _readPendingUpdate();
    if (pending == null) return false;

    final pendingVersion = AirbridgeVersion.tryParse(pending.tagName);
    final currentVersion = AirbridgeVersion.tryParse(releaseTag);
    if (pendingVersion == null ||
        currentVersion == null ||
        pendingVersion.compareTo(currentVersion) <= 0) {
      await _removePendingUpdate(pending);
      return false;
    }

    final expectedAsset = updateAssetNameFor(platform, pending.tagName);
    if (expectedAsset == null || expectedAsset != pending.assetName) {
      _applyFailure = 'incompatible staged package';
      await _setStatus(
        'A staged update is not compatible with this platform. No files were changed.',
      );
      return false;
    }
    final packageFile = _packageFile(pending.tagName, pending.assetName);
    if (!await packageFile.exists()) {
      _applyFailure = 'staged package missing';
      await _setStatus('The staged update package is missing; it will be checked again later.');
      return false;
    }
    if (await packageFile.length() > maxPackageBytes ||
        await _sha256Of(packageFile) != pending.sha256) {
      await _removePendingUpdate(pending);
      await _setStatus('The staged update failed its SHA-256 verification and was discarded.');
      return false;
    }

    try {
      switch (platform) {
        case UpdatePlatform.windows:
          return await _scheduleWindowsInstall(pending, packageFile);
        case UpdatePlatform.linux:
          return await _applyLinuxAppImage(pending, packageFile);
        case UpdatePlatform.macos:
          return await _scheduleMacOSInstall(pending, packageFile);
        case UpdatePlatform.android:
          await _setStatus(
            'Update ${pending.tagName} is available. Android requires OS approval to install a sideloaded APK; no install prompt was opened.',
          );
          return false;
        case UpdatePlatform.ios:
          await _setStatus(
            'iOS updates must be delivered by the App Store or device management; Airbridge cannot install a GitHub build silently.',
          );
          return false;
        case UpdatePlatform.unsupported:
          await _setStatus('Automatic installation is not supported on this platform.');
          return false;
      }
    } on Object catch (error, stackTrace) {
      _applyFailure ??= 'automatic installation failed';
      debugPrint('Airbridge staged update could not be applied: $error\n$stackTrace');
      await _setStatus('The update is staged but could not be applied automatically. The current app remains unchanged.');
      return false;
    }
  }

  /// Starts a background check immediately and repeats it every twelve hours.
  void startBackgroundChecks() {
    if (_periodicTimer != null) return;
    unawaited(checkForUpdates());
    _periodicTimer = Timer.periodic(checkInterval, (_) {
      unawaited(checkForUpdates());
    });
  }

  Future<void> checkForUpdates({bool force = false}) async {
    if (isChecking) return;
    if (!isOfficialReleaseBuild) {
      await _setStatus(
        'Automatic updates run only in official, tagged GitHub release builds.',
      );
      return;
    }

    await _restoreStatus();
    final pending = await _readPendingUpdate();
    if (pending != null) {
      latestTag = pending.tagName;
      if (_applyFailure == null) {
        await _setStatus(
          'Update ${pending.tagName} is downloaded and will install automatically on the next launch.',
        );
      }
      return;
    }

    final previousCheck = lastCheckedAt;
    if (!force &&
        previousCheck != null &&
        DateTime.now().toUtc().difference(previousCheck) < checkInterval) {
      return;
    }

    isChecking = true;
    _notifyListeners();
    await _setStatus('Checking the GitHub pre-release channel…');
    try {
      final releases = await (_releaseFetcher ?? _fetchGitHubReleases)();
      final newest = latestPrerelease(releases);
      latestTag = newest?.tagName;
      final current = AirbridgeVersion.tryParse(releaseTag)!;
      final newestVersion = newest?.version;
      if (newest == null || newestVersion == null) {
        lastCheckedAt = DateTime.now().toUtc();
        await _setStatus('No GitHub pre-release is available yet.');
        return;
      }
      if (newestVersion.compareTo(current) <= 0) {
        lastCheckedAt = DateTime.now().toUtc();
        await _setStatus('Airbridge is up to date on the pre-release channel.');
        return;
      }

      if (platform == UpdatePlatform.android) {
        lastCheckedAt = DateTime.now().toUtc();
        await _setStatus(
          'Update ${newest.tagName} is available. Android requires OS approval to install a sideloaded APK; no install prompt was opened.',
        );
        return;
      }
      if (platform == UpdatePlatform.ios) {
        lastCheckedAt = DateTime.now().toUtc();
        await _setStatus(
          'Update ${newest.tagName} is available. iOS updates must come from the App Store or device management; no install prompt was opened.',
        );
        return;
      }

      final assetName = updateAssetNameFor(platform, newest.tagName);
      if (assetName == null) {
        lastCheckedAt = DateTime.now().toUtc();
        await _setStatus('A newer pre-release exists, but no compatible installer is published for this platform.');
        return;
      }
      if (platform == UpdatePlatform.linux &&
          (Platform.environment['APPIMAGE']?.trim().isEmpty ?? true)) {
        lastCheckedAt = DateTime.now().toUtc();
        await _setStatus(
          'Update ${newest.tagName} is available. Silent installation is supported only for the official AppImage distribution.',
        );
        return;
      }
      if (platform == UpdatePlatform.unsupported) {
        lastCheckedAt = DateTime.now().toUtc();
        await _setStatus('A newer pre-release exists, but this platform has no automatic installer.');
        return;
      }

      await _setStatus('Downloading and verifying update ${newest.tagName}…');
      final manifest = await _downloadChecksumManifest(newest);
      final checksum = manifest[assetName];
      if (checksum == null) {
        throw FormatException('The SHA-256 manifest does not contain $assetName.');
      }
      final package = await _downloadVerifiedPackage(newest, assetName);
      final actualChecksum = await _sha256Of(package);
      if (actualChecksum != checksum) {
        await package.delete();
        throw FormatException('The update package checksum does not match the release manifest.');
      }

      await _writePendingUpdate(
        _PendingUpdate(
          tagName: newest.tagName,
          assetName: assetName,
          sha256: checksum,
        ),
      );
      latestTag = newest.tagName;
      lastCheckedAt = DateTime.now().toUtc();
      await _setStatus(
        'Update ${newest.tagName} is downloaded and verified. It will install automatically on the next launch.',
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Airbridge update check failed: $error\n$stackTrace');
      lastCheckedAt = DateTime.now().toUtc();
      await _setStatus('Could not check or download updates. Airbridge will retry in 12 hours.');
    } finally {
      isChecking = false;
      _notifyListeners();
    }
  }

  Future<List<UpdateRelease>> _fetchGitHubReleases() async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$repository/releases',
      <String, String>{'per_page': '100'},
    );
    final bytes = await _readUrl(uri, maxBytes: 4 * 1024 * 1024);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! List) {
      throw const FormatException('GitHub returned an invalid release list.');
    }
    final releases = <UpdateRelease>[];
    for (final item in decoded) {
      if (item is Map<String, dynamic>) {
        releases.add(UpdateRelease.fromJson(item));
      }
    }
    return releases;
  }

  Future<File> _downloadVerifiedPackage(
    UpdateRelease release,
    String assetName,
  ) async {
    final asset = _findAsset(release, assetName);
    if (asset.size <= 0 || asset.size > maxPackageBytes) {
      throw FormatException('The release package size is invalid for $assetName.');
    }
    final directory = Directory(
      '${_updatesDirectory.path}${Platform.pathSeparator}${_safeTagDirectory(release.tagName)}',
    );
    await directory.create(recursive: true);
    final output = File('${directory.path}${Platform.pathSeparator}$assetName');
    if (await output.exists()) await output.delete();
    final partial = File('${output.path}.partial');
    if (await partial.exists()) await partial.delete();

    HttpClientResponse? response;
    try {
      response = await _openReleaseUrl(asset.downloadUrl);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('GitHub returned HTTP ${response.statusCode} for $assetName.');
      }
      if (response.contentLength > maxPackageBytes) {
        await response.drain<void>();
        throw HttpException('The update package exceeds the 1 GiB safety limit.');
      }
      final sink = partial.openWrite();
      var receivedBytes = 0;
      try {
        await for (final chunk in response) {
          receivedBytes += chunk.length;
          if (receivedBytes > maxPackageBytes) {
            throw HttpException('The update package exceeds the 1 GiB safety limit.');
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (receivedBytes != asset.size) {
        throw HttpException('The downloaded $assetName size did not match GitHub release metadata.');
      }
      return await partial.rename(output.path);
    } on Object {
      if (await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      if (response != null) _closeDownloadClient(response);
    }
  }

  Future<Map<String, String>> _downloadChecksumManifest(UpdateRelease release) async {
    final asset = _findAsset(release, 'SHA256SUMS.txt');
    if (asset.size <= 0 || asset.size > 1024 * 1024) {
      throw const FormatException('The release checksum manifest has an invalid size.');
    }
    final bytes = await _readUrl(Uri.parse(asset.downloadUrl), maxBytes: 1024 * 1024);
    if (bytes.length != asset.size) {
      throw const FormatException('The downloaded checksum manifest size is invalid.');
    }
    return parseSha256Manifest(utf8.decode(bytes));
  }

  UpdateAsset _findAsset(UpdateRelease release, String name) {
    for (final asset in release.assets) {
      if (asset.name == name && asset.downloadUrl.isNotEmpty) return asset;
    }
    throw FormatException('Release ${release.tagName} is missing $name.');
  }

  Future<List<int>> _readUrl(Uri uri, {required int maxBytes}) async {
    final client = _newHttpClient();
    try {
      final response = await _openUri(client, uri);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('GitHub returned HTTP ${response.statusCode}.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) {
          throw HttpException('The GitHub response exceeds the allowed size.');
        }
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> _openReleaseUrl(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith('/$repository/releases/download/')) {
      throw const FormatException('The GitHub release asset URL is not trusted.');
    }
    final client = _newHttpClient();
    try {
      final response = await _openUri(client, uri);
      // The caller owns the response stream. Closing this client is deferred
      // until its body has been consumed by the download helper.
      _activeDownloadClients[response] = client;
      return response;
    } on Object {
      client.close(force: true);
      rethrow;
    }
  }

  final Map<HttpClientResponse, HttpClient> _activeDownloadClients =
      <HttpClientResponse, HttpClient>{};

  void _closeDownloadClient(HttpClientResponse response) {
    _activeDownloadClients.remove(response)?.close(force: true);
  }

  Future<HttpClientResponse> _openUri(HttpClient client, Uri uri) async {
    if (uri.scheme != 'https' ||
        (uri.host != 'api.github.com' && uri.host != 'github.com')) {
      throw const FormatException('Only HTTPS GitHub update URLs are allowed.');
    }
    final request = await client.getUrl(uri);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'Airbridge-Updater/$releaseTag');
    final response = await request.close().timeout(const Duration(seconds: 45));
    for (final redirect in response.redirects) {
      final location = redirect.location;
      if (location.scheme != 'https' ||
          (location.host != 'github.com' &&
              location.host != 'api.github.com' &&
              !location.host.endsWith('.githubusercontent.com') &&
              !location.host.endsWith('.s3.amazonaws.com'))) {
        await response.drain<void>();
        throw const FormatException('GitHub redirected an update to an untrusted host.');
      }
    }
    return response;
  }

  HttpClient _newHttpClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 30)
    ..userAgent = 'Airbridge-Updater/$releaseTag';

  Directory get _updatesDirectory => Directory(
        '${supportDirectory.path}${Platform.pathSeparator}updates',
      );

  File get _stateFile => File(
        '${_updatesDirectory.path}${Platform.pathSeparator}status.json',
      );

  File get _pendingFile => File(
        '${_updatesDirectory.path}${Platform.pathSeparator}pending.json',
      );

  File _packageFile(String tagName, String assetName) => File(
        '${_updatesDirectory.path}${Platform.pathSeparator}'
        '${_safeTagDirectory(tagName)}${Platform.pathSeparator}$assetName',
      );

  Future<void> _writePendingUpdate(_PendingUpdate pending) async {
    await _updatesDirectory.create(recursive: true);
    final temporary = File('${_pendingFile.path}.tmp');
    await temporary.writeAsString(jsonEncode(pending.toJson()), flush: true);
    if (await _pendingFile.exists()) await _pendingFile.delete();
    await temporary.rename(_pendingFile.path);
  }

  Future<_PendingUpdate?> _readPendingUpdate() async {
    try {
      final decoded = jsonDecode(await _pendingFile.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final pending = _PendingUpdate.fromJson(decoded);
      if (pending == null ||
          AirbridgeVersion.tryParse(pending.tagName) == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(pending.sha256) ||
          _safeTagDirectory(pending.tagName).isEmpty) {
        return null;
      }
      return pending;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _removePendingUpdate(_PendingUpdate pending) async {
    try {
      final package = _packageFile(pending.tagName, pending.assetName);
      if (await package.exists()) await package.delete();
      if (await _pendingFile.exists()) await _pendingFile.delete();
    } on FileSystemException {
      // A stale package is harmless and can be removed by the next check.
    }
  }

  String _safeTagDirectory(String tag) {
    if (!RegExp(r'^[vV]?[0-9A-Za-z.+-]+$').hasMatch(tag)) return '';
    return tag;
  }

  Future<String> _sha256Of(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _restoreStatus() async {
    try {
      final decoded = jsonDecode(
        (await _stateFile.readAsString()).replaceFirst('\uFEFF', ''),
      );
      if (decoded is! Map<String, dynamic>) return;
      final savedTag = decoded['latestTag'];
      final savedStatus = decoded['status'];
      final savedTimeValue = decoded['lastCheckedAt'];
      if (savedTag is String) latestTag = savedTag;
      if (savedStatus is String) status = savedStatus;
      final savedTime = DateTime.tryParse(
        savedTimeValue is String ? savedTimeValue : '',
      );
      if (savedTime != null) lastCheckedAt = savedTime.toUtc();
      final savedVersion = savedTag is String
          ? AirbridgeVersion.tryParse(savedTag)
          : null;
      final currentVersion = AirbridgeVersion.tryParse(releaseTag);
      if (savedVersion != null &&
          currentVersion != null &&
          savedVersion.compareTo(currentVersion) <= 0 &&
          (status.startsWith('Update ') || status.startsWith('The update is staged'))) {
        status = 'Airbridge is up to date on the pre-release channel.';
      }
    } on FileSystemException {
      // First launch: no saved updater state.
    } on FormatException {
      // Corrupt status is ignored; the next successful check rewrites it.
    }
  }

  Future<void> _setStatus(String value) async {
    status = value;
    _notifyListeners();
    try {
      await _updatesDirectory.create(recursive: true);
      final state = <String, Object?>{
        'latestTag': latestTag,
        'status': status,
        'lastCheckedAt': lastCheckedAt?.toUtc().toIso8601String(),
      };
      final temporary = File('${_stateFile.path}.tmp');
      await temporary.writeAsString(jsonEncode(state), flush: true);
      if (await _stateFile.exists()) await _stateFile.delete();
      await temporary.rename(_stateFile.path);
    } on FileSystemException catch (error) {
      debugPrint('Could not persist Airbridge update status: $error');
    }
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> _scheduleWindowsInstall(
    _PendingUpdate pending,
    File installer,
  ) async {
    final executable = File(Platform.resolvedExecutable).absolute;
    final installDirectory = executable.parent;
    if (!await _isDirectoryWritable(installDirectory)) {
      _applyFailure = 'install path is protected';
      await _setStatus(
        'Update ${pending.tagName} is ready, but this Windows install is in a protected folder. Airbridge will not request administrator approval.',
      );
      return false;
    }

    final helper = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'airbridge-update-${pid}.ps1',
    );
    final arguments = <String>[
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/SP-',
      '/CLOSEAPPLICATIONS',
      '/DIR="${installDirectory.path}"',
    ];
    final launchArguments = Platform.executableArguments;
    final successState = jsonEncode(<String, Object?>{
      'latestTag': pending.tagName,
      'status': 'Updated to ${pending.tagName}.',
      'lastCheckedAt': DateTime.now().toUtc().toIso8601String(),
    });
    final failureState = jsonEncode(<String, Object?>{
      'latestTag': pending.tagName,
      'status': 'The automatic Windows update failed; the previous app was reopened.',
      'lastCheckedAt': DateTime.now().toUtc().toIso8601String(),
    });
    final launchArray = launchArguments.map(_powerShellLiteral).join(', ');
    final script = '''
\$ErrorActionPreference = 'Stop'
\$oldPid = ${pid}
\$installerPath = ${_powerShellLiteral(installer.path)}
\$appPath = ${_powerShellLiteral(executable.path)}
\$installDir = ${_powerShellLiteral(installDirectory.path)}
\$pendingPath = ${_powerShellLiteral(_pendingFile.path)}
\$statePath = ${_powerShellLiteral(_stateFile.path)}
\$packagePath = ${_powerShellLiteral(installer.path)}
while (Get-Process -Id \$oldPid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 500 }
\$installerArguments = @(${arguments.map(_powerShellLiteral).join(', ')})
\$exitCode = 1
try {
  \$setup = Start-Process -FilePath \$installerPath -ArgumentList \$installerArguments -Wait -PassThru -WindowStyle Hidden
  \$exitCode = \$setup.ExitCode
} catch {
  \$exitCode = 1
}
if (\$exitCode -eq 0) {
  Set-Content -LiteralPath \$statePath -Value ${_powerShellLiteral(successState)} -Encoding UTF8
  Remove-Item -LiteralPath \$pendingPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath \$packagePath -Force -ErrorAction SilentlyContinue
  Start-Process -FilePath \$appPath -WorkingDirectory \$installDir -ArgumentList @($launchArray)
} else {
  Set-Content -LiteralPath \$statePath -Value ${_powerShellLiteral(failureState)} -Encoding UTF8
  Remove-Item -LiteralPath \$pendingPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath \$packagePath -Force -ErrorAction SilentlyContinue
  Start-Process -FilePath \$appPath -WorkingDirectory \$installDir -ArgumentList @($launchArray)
}
Remove-Item -LiteralPath \$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
''';
    await helper.writeAsString(script, flush: true);
    await _setStatus('Installing update ${pending.tagName} and restarting Airbridge…');
    await Process.start(
      'powershell.exe',
      <String>[
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        helper.path,
      ],
      mode: ProcessStartMode.detached,
    );
    return true;
  }

  Future<bool> _applyLinuxAppImage(
    _PendingUpdate pending,
    File package,
  ) async {
    final appImageValue = Platform.environment['APPIMAGE']?.trim();
    if (appImageValue == null || appImageValue.isEmpty) {
      _applyFailure = 'not running from an AppImage';
      await _setStatus(
        'Update ${pending.tagName} is ready, but this app was not started from an AppImage. No files were changed.',
      );
      return false;
    }
    var appImagePath = File(appImageValue).absolute.path;
    try {
      appImagePath = await File(appImagePath).resolveSymbolicLinks();
    } on FileSystemException {
      // Keep the absolute APPIMAGE path if it is not a symlink.
    }
    final appImage = File(appImagePath);
    if (!await appImage.exists() || !await _isDirectoryWritable(appImage.parent)) {
      _applyFailure = 'AppImage directory is not writable';
      await _setStatus(
        'Update ${pending.tagName} is ready, but the AppImage folder is not writable. No privilege prompt will be opened.',
      );
      return false;
    }

    final replacement = File(
      '${appImage.path}.airbridge-new-${pid}',
    );
    await package.copy(replacement.path);
    final chmod = await Process.run('chmod', <String>['0755', replacement.path]);
    if (chmod.exitCode != 0) {
      await replacement.delete();
      throw FileSystemException('Could not mark the replacement AppImage executable.');
    }
    final move = await Process.run(
      'mv',
      <String>['-f', '--', replacement.path, appImage.path],
    );
    if (move.exitCode != 0) {
      if (await replacement.exists()) await replacement.delete();
      throw FileSystemException('Could not atomically replace the AppImage.');
    }
    await _removePendingUpdate(pending);
    latestTag = pending.tagName;
    lastCheckedAt = DateTime.now().toUtc();
    await _setStatus('Updated to ${pending.tagName}; restarting with the new AppImage…');
    await Process.start(
      appImage.path,
      Platform.executableArguments,
      workingDirectory: Directory.current.path,
      mode: ProcessStartMode.detached,
    );
    return true;
  }

  Future<bool> _scheduleMacOSInstall(
    _PendingUpdate pending,
    File diskImage,
  ) async {
    final executable = File(Platform.resolvedExecutable).absolute;
    final appBundle = executable.parent.parent.parent;
    final appPath = appBundle.path;
    if (!appPath.toLowerCase().endsWith('.app') ||
        !await appBundle.exists() ||
        !await _isDirectoryWritable(appBundle.parent)) {
      _applyFailure = 'macOS app bundle is not writable';
      await _setStatus(
        'Update ${pending.tagName} is ready, but the macOS app bundle is not writable. Airbridge will not request administrator approval.',
      );
      return false;
    }

    final helper = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'airbridge-update-${pid}.sh',
    );
    final stateSuccess = jsonEncode(<String, Object?>{
      'latestTag': pending.tagName,
      'status': 'Updated to ${pending.tagName}.',
      'lastCheckedAt': DateTime.now().toUtc().toIso8601String(),
    });
    final stateFailure = jsonEncode(<String, Object?>{
      'latestTag': pending.tagName,
      'status': 'The automatic macOS update failed; the previous app was reopened.',
      'lastCheckedAt': DateTime.now().toUtc().toIso8601String(),
    });
    final args = Platform.executableArguments.map(_shellQuote).join(' ');
    final script = '''
#!/bin/sh
set -eu
old_pid=${pid}
while kill -0 "\$old_pid" 2>/dev/null; do sleep 1; done
dmg=${_shellQuote(diskImage.path)}
target=${_shellQuote(appPath)}
pending=${_shellQuote(_pendingFile.path)}
state=${_shellQuote(_stateFile.path)}
updates=${_shellQuote(diskImage.parent.path)}
mount=\$(mktemp -d "\${TMPDIR:-/tmp}/airbridge-update.XXXXXX")
stage="\${target}.airbridge-new"
backup="\${target}.airbridge-old"
mounted=0
completed=0
launch_app() {
  if [ -n ${_shellQuote(args)} ]; then
    open -n -a "\$target" --args $args
  else
    open -n -a "\$target"
  fi
}
cleanup() {
  if [ "\$mounted" -eq 1 ]; then hdiutil detach "\$mount" -quiet >/dev/null 2>&1 || true; fi
  if [ "\$completed" -eq 0 ]; then
    if [ -d "\$backup" ]; then rm -rf "\$target"; mv "\$backup" "\$target"; fi
    printf '%s' ${_shellQuote(stateFailure)} > "\$state" || true
    rm -f "\$pending" || true
    rm -rf "\$updates" || true
    if [ -d "\$target" ]; then launch_app || true; fi
  fi
  rm -rf "\$mount" "\$stage"
}
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -mountpoint "\$mount" "\$dmg" >/dev/null
mounted=1
ditto "\$mount/Airbridge.app" "\$stage"
hdiutil detach "\$mount" -quiet >/dev/null
mounted=0
rm -rf "\$backup"
if [ -d "\$target" ]; then mv "\$target" "\$backup"; fi
if ! mv "\$stage" "\$target"; then
  if [ -d "\$backup" ]; then mv "\$backup" "\$target"; fi
  exit 1
fi
printf '%s' ${_shellQuote(stateSuccess)} > "\$state"
rm -f "\$pending"
rm -rf "\$updates"
launch_app
sleep 3
if ! pgrep -f "\$target/Contents/MacOS/airbridge_mobile" >/dev/null 2>&1; then exit 1; fi
completed=1
rm -rf "\$backup"
''';
    await helper.writeAsString(script, flush: true);
    final chmod = await Process.run('chmod', <String>['0755', helper.path]);
    if (chmod.exitCode != 0) {
      throw FileSystemException('Could not prepare the macOS update helper.');
    }
    await _setStatus('Installing update ${pending.tagName} and restarting Airbridge…');
    await Process.start(
      '/bin/sh',
      <String>[helper.path],
      mode: ProcessStartMode.detached,
    );
    return true;
  }

  Future<bool> _isDirectoryWritable(Directory directory) async {
    final probe = File(
      '${directory.path}${Platform.pathSeparator}'
      '.airbridge-update-write-test-${pid}-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await probe.writeAsString('Airbridge update permission check', flush: true);
      await probe.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  String _powerShellLiteral(String value) => "'${value.replaceAll("'", "''")}'";

  String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  @override
  void dispose() {
    _disposed = true;
    _periodicTimer?.cancel();
    for (final client in _activeDownloadClients.values) {
      client.close(force: true);
    }
    _activeDownloadClients.clear();
    super.dispose();
  }
}

@immutable
class _PendingUpdate {
  const _PendingUpdate({
    required this.tagName,
    required this.assetName,
    required this.sha256,
  });

  final String tagName;
  final String assetName;
  final String sha256;

  Map<String, Object?> toJson() => <String, Object?>{
        'tagName': tagName,
        'assetName': assetName,
        'sha256': sha256,
      };

  static _PendingUpdate? fromJson(Map<String, dynamic> json) {
    final tagName = json['tagName'];
    final assetName = json['assetName'];
    final checksum = json['sha256'];
    if (tagName is! String || assetName is! String || checksum is! String) {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(assetName)) return null;
    return _PendingUpdate(
      tagName: tagName,
      assetName: assetName,
      sha256: checksum.toLowerCase(),
    );
  }
}
