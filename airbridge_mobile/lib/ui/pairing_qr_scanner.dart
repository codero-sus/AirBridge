import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_lite_camera/flutter_lite_camera.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/airbridge_link.dart';
import '../services/qr_frame_decoder.dart';

Future<String?> scanAirbridgePairingQr(BuildContext context) {
  final useDesktopCamera = Platform.isWindows || Platform.isLinux;
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (_) => useDesktopCamera
          ? const _DesktopPairingQrScannerPage(isWebcam: true)
          : const _MobilePairingQrScannerPage(),
    ),
  );
}

class _MobilePairingQrScannerPage extends StatefulWidget {
  const _MobilePairingQrScannerPage();

  @override
  State<_MobilePairingQrScannerPage> createState() =>
      _MobilePairingQrScannerPageState();
}

class _MobilePairingQrScannerPageState extends State<_MobilePairingQrScannerPage> {
  late final MobileScannerController _controller;
  bool _didRead = false;
  bool _cameraErrorVisible = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      autoStart: true,
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_didRead) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      final uri = value == null ? null : Uri.tryParse(value);
      if (uri != null && isAirbridgePairingUri(uri)) {
        _didRead = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  Future<void> _switchCamera() async {
    try {
      await _controller.switchCamera();
    } on Object catch (error) {
      _showCameraActionError(error);
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } on Object catch (error) {
      _showCameraActionError(error);
    }
  }

  void _showCameraActionError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Camera control failed: $error')),
    );
  }

  Future<void> _retryCamera() async {
    if (mounted) setState(() => _cameraErrorVisible = false);
    try {
      await _controller.start();
    } on Object catch (error) {
      _showCameraActionError(error);
    }
  }

  Future<void> _openCompatibilityScanner() async {
    try {
      await _controller.stop();
    } on Object catch (error) {
      debugPrint('Could not pause the native camera before fallback: $error');
    }
    if (!mounted) return;
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const _DesktopPairingQrScannerPage(),
      ),
    );
    if (!mounted) return;
    if (payload != null) {
      Navigator.of(context).pop(payload);
    } else {
      await _retryCamera();
    }
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF0B0F19),
        appBar: AppBar(
          title: const Text('Scan Airbridge QR'),
          backgroundColor: const Color(0xFF111827),
          actions: <Widget>[
            IconButton(
              tooltip: 'Switch camera',
              onPressed: _didRead ? null : _switchCamera,
              icon: const Icon(Icons.cameraswitch_rounded),
            ),
            if (Platform.isAndroid || Platform.isIOS)
              IconButton(
                tooltip: 'Toggle flashlight',
                onPressed: _didRead ? null : _toggleTorch,
                icon: const Icon(Icons.flashlight_on_rounded),
              ),
          ],
        ),
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error, child) {
                if (!_cameraErrorVisible) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_cameraErrorVisible) {
                      setState(() => _cameraErrorVisible = true);
                    }
                  });
                }
                return _MobileCameraError(
                  error: error,
                  onRetry: _retryCamera,
                  onUseAlternate: _openCompatibilityScanner,
                );
              },
            ),
            if (!_cameraErrorVisible)
              IgnorePointer(
                child: Center(
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFF63E6BE),
                        width: 3,
                      ),
                    ),
                  ),
                ),
              ),
            if (!_cameraErrorVisible)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  minimum: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xDD111827),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Text(
                          'Center the pairing QR in the frame. You can switch to the alternate camera scanner if focus or compatibility is poor.',
                          textAlign: TextAlign.center,
                          style: TextStyle(height: 1.35),
                        ),
                        const SizedBox(height: 4),
                        TextButton.icon(
                          onPressed: _openCompatibilityScanner,
                          icon: const Icon(Icons.camera_alt_rounded, size: 18),
                          label: const Text('Use alternate scanner'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

class _MobileCameraError extends StatelessWidget {
  const _MobileCameraError({
    required this.error,
    required this.onRetry,
    required this.onUseAlternate,
  });

  final MobileScannerException error;
  final VoidCallback onRetry;
  final VoidCallback onUseAlternate;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFF0B0F19),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.no_photography_rounded, size: 42),
                const SizedBox(height: 12),
                const Text(
                  'Airbridge could not start the native camera.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Allow camera access for Airbridge in system settings, close other apps using the camera, then retry. Details: $error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF92A0B8), height: 1.4),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry camera'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: onUseAlternate,
                  icon: const Icon(Icons.camera_alt_rounded),
                  label: const Text('Use alternate camera scanner'),
                ),
              ],
            ),
          ),
        ),
      );
}

class _DesktopPairingQrScannerPage extends StatefulWidget {
  const _DesktopPairingQrScannerPage({this.isWebcam = false});

  final bool isWebcam;

  @override
  State<_DesktopPairingQrScannerPage> createState() =>
      _DesktopPairingQrScannerPageState();
}

class _DesktopPairingQrScannerPageState
    extends State<_DesktopPairingQrScannerPage> {
  final FlutterLiteCamera _camera = FlutterLiteCamera();
  List<String> _devices = <String>[];
  Timer? _scanTimer;
  int _selectedCamera = 0;
  int? _textureId;
  int _frameWidth = 4;
  int _frameHeight = 3;
  int _rotationDegrees = 0;
  bool _loading = true;
  bool _cameraOpened = false;
  bool _scanInProgress = false;
  bool _didRead = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCameras());
  }

  Future<void> _loadCameras() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await _camera.getDeviceList();
      if (!mounted) return;
      final selectedCamera = _selectedCamera < devices.length ? _selectedCamera : 0;
      setState(() {
        _devices = devices;
        _selectedCamera = selectedCamera;
        _loading = false;
      });
      if (devices.isEmpty) {
        setState(() {
          _error =
              'No ${widget.isWebcam ? 'webcam' : 'camera'} was detected. Connect or enable a camera, then retry.';
        });
        return;
      }
      await _openCamera(selectedCamera);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _cameraErrorMessage(error);
      });
    }
  }

  String _cameraErrorMessage(Object error) {
    final platformHint = Platform.isWindows
        ? 'Check Settings > Privacy & security > Camera and allow desktop apps to use it.'
        : Platform.isLinux
            ? 'Check that the user can access the webcam device (usually through the video group).'
            : 'Check camera permissions and confirm the camera is not in use by another app.';
    final cameraName = widget.isWebcam ? 'webcam' : 'camera';
    return 'Could not open the $cameraName. $platformHint Details: $error';
  }

  Future<void> _openCamera(int index) async {
    _scanTimer?.cancel();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _textureId = null;
      });
    }
    await _releaseCamera();

    try {
      final opened = await _camera.open(index);
      if (!opened) throw StateError('The selected camera refused to open.');
      _cameraOpened = true;
      await _camera.setResolutionPreset(ResolutionPreset.high);
      final textureId = await _camera.startPreview();
      final width = await _camera.getWidth();
      final height = await _camera.getHeight();
      final rotationDegrees = await _camera.getRotation();
      if (!mounted) {
        await _releaseCamera();
        return;
      }
      setState(() {
        _selectedCamera = index;
        _textureId = textureId;
        _frameWidth = width > 0 ? width : 4;
        _frameHeight = height > 0 ? height : 3;
        _rotationDegrees = rotationDegrees;
        _loading = false;
      });
      _scanTimer = Timer.periodic(
        const Duration(milliseconds: 450),
        (_) => unawaited(_scanCameraFrame()),
      );
    } on Object catch (error) {
      await _releaseCamera();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _cameraErrorMessage(error);
      });
    }
  }

  Future<void> _releaseCamera() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (!_cameraOpened) return;
    try {
      await _camera.stopPreview();
    } on Object catch (error) {
      debugPrint('Could not stop pairing webcam preview: $error');
    }
    try {
      await _camera.release();
    } on Object catch (error) {
      debugPrint('Could not release pairing webcam: $error');
    }
    _cameraOpened = false;
  }

  Future<void> _scanCameraFrame() async {
    if (_didRead || _scanInProgress || !_cameraOpened) return;
    _scanInProgress = true;
    try {
      final frame = await _camera.captureFrame(byteOrder: 0);
      final rgb = frame['data'];
      final width = frame['width'];
      final height = frame['height'];
      if (rgb is! Uint8List || width is! int || height is! int) return;
      final rotationDegrees = _rotationDegrees;
      final payload = await Isolate.run<String?>(
        () => decodeRgb888QrFrame(
          rgb,
          width,
          height,
          rotationDegrees: rotationDegrees,
        ),
      );
      final uri = payload == null ? null : Uri.tryParse(payload);
      if (uri == null || !isAirbridgePairingUri(uri) || !mounted) return;
      _didRead = true;
      _scanTimer?.cancel();
      Navigator.of(context).pop(payload);
    } on Object catch (error) {
      if (!mounted) return;
      _scanTimer?.cancel();
      setState(() {
        _error = 'The webcam stopped sending frames. Retry the camera. Details: $error';
      });
    } finally {
      _scanInProgress = false;
    }
  }

  Future<void> _retry() => _loadCameras();

  @override
  void dispose() {
    _scanTimer?.cancel();
    unawaited(_releaseCamera());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF0B0F19),
        appBar: AppBar(
          title: Text(widget.isWebcam ? 'Scan with webcam' : 'Alternate camera scanner'),
          backgroundColor: const Color(0xFF111827),
          actions: <Widget>[
            if (_devices.length > 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButton<int>(
                  value: _selectedCamera,
                  dropdownColor: const Color(0xFF111827),
                  items: <DropdownMenuItem<int>>[
                    for (final entry in _devices.indexed)
                      DropdownMenuItem<int>(
                        value: entry.$1,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: Text(
                            entry.$2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                  onChanged: _loading
                      ? null
                      : (index) {
                          if (index != null) unawaited(_openCamera(index));
                        },
                ),
              ),
          ],
        ),
        body: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: _buildCameraView(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
              child: Column(
                children: <Widget>[
                  Text(
                    _error ??
                        (widget.isWebcam
                            ? 'Show the Airbridge QR clearly to the webcam. Select the wired webcam from the top-right menu if more than one camera is connected.'
                            : 'Show the Airbridge QR clearly to the camera.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF92A0B8),
                      height: 1.4,
                    ),
                  ),
                  if (_error != null || _devices.isEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : _retry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(widget.isWebcam ? 'Retry webcam' : 'Retry camera'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  Widget _buildCameraView() {
    final textureId = _textureId;
    if (_loading) return const CircularProgressIndicator();
    if (_error != null || textureId == null) {
      return const Icon(Icons.videocam_off_rounded, size: 56, color: Color(0xFF92A0B8));
    }
    final rotateQuarterTurns = (_rotationDegrees ~/ 90) % 4;
    final displayAspectRatio = rotateQuarterTurns.isOdd
        ? _frameHeight / _frameWidth
        : _frameWidth / _frameHeight;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960, maxHeight: 640),
      child: AspectRatio(
        aspectRatio: displayAspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            RotatedBox(
              quarterTurns: rotateQuarterTurns,
              child: _camera.buildPreview(textureId),
            ),
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFF63E6BE), width: 3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
