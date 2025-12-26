import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/api_client.dart';

enum ScanMode { obstacles, crosswalk, custom }

class CameraPreviewScreen extends StatefulWidget {
  const CameraPreviewScreen({super.key});

  @override
  State<CameraPreviewScreen> createState() => _CameraPreviewScreenState();
}

class _CameraPreviewScreenState extends State<CameraPreviewScreen> {
  CameraController? _controller;
  Timer? _pictureTimer;
  List<CameraDescription> _cameras = const [];
  bool _initializing = true;

  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _listening = false;
  String _currentWords = "";

  DateTime _speechMutedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  bool _autoScanEnabled = true;
  ScanMode _mode = ScanMode.obstacles;
  bool _autoScanBeforeCustom = true;
  String _pendingPrompt = '';

  static const String _offlineMessage =
      "I can’t analyze the scene right now. Please check your connection.";

  // PVA-6 integration state
  late final ApiClient _api;
  bool _sending = false;
  String _backendText = "";

  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastSpokenText = '';

  static const Duration _captureInterval = Duration(seconds: 5);
  static const Duration _minRequestGap = Duration(seconds: 6);
  static const Duration _minSpeakGap = Duration(seconds: 4);
  static const Duration _sttMuteAfterTts = Duration(milliseconds: 700);

  @override
  void initState() {
    super.initState();

    // Configure base URL with:
    // `--dart-define=API_BASE_URL=http://10.0.2.2:8000` (Android emulator)
    // `--dart-define=API_BASE_URL=http://<YOUR_PC_IP>:8000` (physical phone)
    _api = ApiClient();

    _initCamera();
    _setupTts();
    _initSpeech();
  }

  Future<void> _setupTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      final CameraDescription camera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      _controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (!mounted) return;

      setState(() => _initializing = false);

      //  auto capture + send loop
      _startPictureLoop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _initializing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Camera init failed: $e')),
      );
    }
  }

  void _startPictureLoop() {
    _pictureTimer?.cancel();

    _pictureTimer = Timer.periodic(_captureInterval, (_) async {
      if (!_autoScanEnabled) return;
      if (_mode == ScanMode.custom) return;
      await _captureAndSendOnce();
    });
  }

  Future<void> _captureAndSendOnce() async {
    if (!mounted || _controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isTakingPicture) return;
    if (_sending) return;

    final now = DateTime.now();
    if (now.difference(_lastRequestAt) < _minRequestGap) return;

    try {
      _lastRequestAt = now;
      final XFile file = await _controller!.takePicture();
      debugPrint('Capture success: ${file.path}');
      await _sendToBackend(file);
    } catch (e) {
      debugPrint('Error capturing photo: $e');
    }
  }

  Future<void> _sendToBackend(XFile image) async {
    setState(() {
      _sending = true;
      _backendText = "";
    });

    try {
      final prompt = _pendingPrompt.trim();

      Map<String, dynamic> json;
      if (_mode == ScanMode.custom) {
        if (prompt.isEmpty) {
          // In custom mode we require an explicit prompt.
          throw ApiException('Missing prompt', statusCode: 400);
        }
        json = await _api.sendCustom(image, prompt);
      } else if (_mode == ScanMode.crosswalk) {
        json = await _api.sendCrosswalk(image);
      } else {
        json = await _api.sendObstacles(image);
      }

      // Custom mode is one-shot: it resets after one answer.
      _pendingPrompt = '';
      if (_mode == ScanMode.custom) {
        _mode = ScanMode.obstacles;
        _autoScanEnabled = _autoScanBeforeCustom;
      }

      final resultText = (json['result'] ?? '').toString().trim();

      // Optional: confidence indicator (0..1)
      final confidence = json['confidence'];
      final spoken = _formatSpokenResult(resultText, confidence);

      if (!mounted) return;
      setState(() {
        _backendText = resultText;
      });

      await _speakIfNeeded(spoken);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _backendText = _offlineMessage;
      });
      debugPrint('API error: ${e.message}');
      await _speakIfNeeded(_offlineMessage);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _backendText = _offlineMessage;
      });
      debugPrint('Unexpected error: $e');
      await _speakIfNeeded(_offlineMessage);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  String _formatSpokenResult(String resultText, Object? confidence) {
    final clean = resultText.trim();
    if (clean.isEmpty) return clean;

    final value = (confidence is num) ? confidence.toDouble() : null;
    if (value == null) return clean;

    // MVP phrasing: add uncertainty for low confidence.
    if (value < 0.7) {
      return 'I might be wrong, but $clean';
    }
    return clean;
  }

  Future<void> _speakIfNeeded(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;

    // Avoid repeating the same message every scan.
    if (clean == _lastSpokenText) return;

    final now = DateTime.now();
    if (now.difference(_lastSpokenAt) < _minSpeakGap) return;

    _lastSpokenAt = now;
    _lastSpokenText = clean;

    try {
      await _stopListeningForTts();
      await _tts.stop();
      await _tts.speak(clean);
      _speechMutedUntil = DateTime.now().add(_sttMuteAfterTts);
      _scheduleListeningResume();
    } catch (_) {
      // Ignore TTS failures; UI still shows the text.
    }
  }

  Future<void> _stopListeningForTts() async {
    try {
      await _speech.stop();
    } catch (_) {
      // ignore
    }
    if (mounted) setState(() => _listening = false);
  }

  void _scheduleListeningResume() {
    if (!mounted) return;
    if (_mode == ScanMode.custom) {
      // We still want listening in custom mode to capture the question.
    }
    final now = DateTime.now();
    final delay = _speechMutedUntil.isAfter(now)
        ? _speechMutedUntil.difference(now)
        : Duration.zero;
    Future.delayed(delay, () {
      if (mounted) _startListening();
    });
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'notListening' && mounted) {
          setState(() => _listening = false);
          _scheduleListeningResume();
        }
      },
      onError: (error) {
        if (mounted) setState(() => _listening = false);
        _scheduleListeningResume();
      },
    );
    if (available && mounted) _startListening();
  }

  Future<void> _startListening() async {
    if (DateTime.now().isBefore(_speechMutedUntil)) return;
    if (_listening || _speech.isListening) return;
    setState(() => _listening = true);

    try {
      await _speech.listen(
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
        ),
        pauseFor: const Duration(seconds: 2),
        onResult: (result) {
          if (!mounted) return;

          final words = result.recognizedWords;
          setState(() => _currentWords = words);

          if (result.finalResult) {
            _handleFinalSpeech(words);
          }
        },
      );
    } catch (_) {
      if (mounted) setState(() => _listening = false);
    }
  }

  void _handleFinalSpeech(String words) {
    final command = words.toLowerCase().trim();
    if (command.isEmpty) return;

    if (command.contains('close camera')) {
      _closeCamera();
      return;
    }

    if (command.contains('pause scanning') || command.contains('stop scanning')) {
      setState(() {
        _autoScanEnabled = false;
        _backendText = 'Scanning paused';
      });
      _speakIfNeeded('Scanning paused');
      return;
    }

    if (command.contains('resume scanning') || command.contains('start scanning')) {
      setState(() {
        _autoScanEnabled = true;
        _backendText = 'Scanning resumed';
      });
      _speakIfNeeded('Scanning resumed');
      _captureAndSendOnce();
      return;
    }

    if (command.contains('obstacle mode') || command.contains('obstacles mode')) {
      setState(() {
        _mode = ScanMode.obstacles;
        _backendText = 'Obstacle mode';
      });
      _speakIfNeeded('Obstacle mode');
      return;
    }

    if (command.contains('crosswalk mode') ||
        command.contains('cross walk mode') ||
        command == 'crosswalk') {
      setState(() {
        _mode = ScanMode.crosswalk;
        _backendText = 'Crosswalk mode';
      });
      _speakIfNeeded('Crosswalk mode');
      return;
    }

    if (command.contains('custom mode') ||
        command.contains('question mode') ||
        command.contains('ask question')) {
      _autoScanBeforeCustom = _autoScanEnabled;
      setState(() {
        _mode = ScanMode.custom;
        _pendingPrompt = '';
        _autoScanEnabled = false;
        _backendText = 'Custom mode: ask your question.';
      });
      _speakIfNeeded('Custom mode. Ask your question.');
      return;
    }

    // In custom mode, any final speech that isn't a command becomes the prompt.
    if (_mode == ScanMode.custom) {
      _pendingPrompt = words.trim();
      setState(() {
        _backendText = 'Asking...';
      });
      _captureAndSendOnce();
    }
  }

  Future<void> _closeCamera() async {
    _pictureTimer?.cancel();
    await _tts.stop();
    await _speech.stop();

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _pictureTimer?.cancel();
    _tts.stop();
    _speech.stop();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    String overlayText;
    if (_sending) {
      overlayText = "Processing...";
    } else if (_backendText.isNotEmpty) {
      overlayText = _backendText;
    } else if (!_autoScanEnabled) {
      overlayText = 'Scanning paused';
    } else if (_currentWords.isEmpty) {
      overlayText = "Listening...";
    } else {
      overlayText = _currentWords;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Camera')),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : (controller == null || !controller.value.isInitialized)
              ? const Center(child: Text('Camera not available'))
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    CameraPreview(controller),

                    // subtitle / result overlay
                    Positioned(
                      bottom: 100,
                      left: 20,
                      right: 20,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          overlayText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),

                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 24,
                      child: Center(
                        child: FilledButton(
                          onPressed: _closeCamera,
                          child: const Text('Close'),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
