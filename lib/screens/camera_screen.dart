import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:vibration/vibration.dart';
import 'package:flutter/services.dart'; // SystemSound

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
  Timer? _listenResumeTimer;
  List<CameraDescription> _cameras = const [];
  bool _initializing = true;
  bool _closing = false;
  bool _captureInFlight = false;

  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _listening = false;
  String _currentWords = "";

  DateTime _speechMutedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  String _customPromptCandidate = '';
  DateTime _lastCommandAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastCommandKey = '';

  bool _autoScanEnabled = true;
  ScanMode _mode = ScanMode.obstacles;
  bool _autoScanBeforeCustom = true;
  String _pendingPrompt = '';

  static const String _offlineMessage =
      "I can’t analyze the scene right now. Please check your connection.";
    static const String _badRequestMessage =
      "I couldn’t process the photo. Please try again.";

  // PVA-6 integration state
  late final ApiClient _api;
  bool _sending = false;
  String _backendText = "";

  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastSpokenText = '';

  static const Duration _captureInterval = Duration(seconds: 8);
  static const Duration _minRequestGap = Duration(seconds: 8);
  static const Duration _minSpeakGap = Duration(seconds: 4);
  static const Duration _sttMuteAfterTts = Duration(milliseconds: 1200);
  static const Duration _commandCooldown = Duration(seconds: 2);

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
      if (_closing) return;
      if (!_autoScanEnabled) return;
      if (_mode == ScanMode.custom) return;
      await _captureAndSendOnce();
    });
  }

  Future<void> _captureAndSendOnce({bool force = false}) async {
    if (_mode == ScanMode.custom && _pendingPrompt.isEmpty) {
      return ; // NEVER  send in custom mode without a prompt
    }
    if (_closing) return;
    if (!mounted || _controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isTakingPicture) return;
    if (_sending || _captureInFlight) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastRequestAt) < _minRequestGap) return;

    _captureInFlight = true;
    try {
      _lastRequestAt = now;
      final XFile file = await _controller!.takePicture();
      debugPrint('Capture success: ${file.path}');
      await _scanFeedback(); 
      await _sendToBackend(file);
    } catch (e) {
      debugPrint('Error capturing photo: $e');
    } finally {
      _captureInFlight = false;
    }
  }

  Future<void> _sendToBackend(XFile image) async {
    if (_closing) return;
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
        debugPrint('API: POST /custom (prompt="${prompt.replaceAll('\n', ' ')}")');
        json = await _api.sendCustom(image, prompt);
      } else if (_mode == ScanMode.crosswalk) {
        debugPrint('API: POST /crosswalk');
        json = await _api.sendCrosswalk(image);
      } else {
        debugPrint('API: POST /obstacles');
        json = await _api.sendObstacles(image);
      }

      // Custom mode is one-shot: it resets after one answer.
      if (_mode == ScanMode.custom) {
         _pendingPrompt = '';
         _customPromptCandidate = '';

         setState(() {
            _mode = ScanMode.obstacles;
           _autoScanEnabled = _autoScanBeforeCustom;
         });

         // Restart the auto-scan timer cleanly 
         _startPictureLoop();
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

      final message = (e.statusCode != null && e.statusCode! >= 500)
          ? _offlineMessage
          : (e.statusCode != null ? _badRequestMessage : _offlineMessage);

      setState(() {
        _backendText = message;
      });
      debugPrint('API error: ${e.message}');
      await _speakIfNeeded(message);
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

  Future<void> _speakSystem(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;

    // System confirmations must be immediate and predictable.
    _lastSpokenAt = DateTime.now();
    _lastSpokenText = clean;

    try {
      await _stopListeningForTts();
      await _tts.stop();
      await _tts.speak(clean);
      _speechMutedUntil = DateTime.now().add(_sttMuteAfterTts);
      _scheduleListeningResume();
    } catch (_) {
      // ignore
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
    if (!mounted || _closing) return;

    _listenResumeTimer?.cancel();

    final now = DateTime.now();
    final delay = _speechMutedUntil.isAfter(now)
        ? _speechMutedUntil.difference(now)
        : Duration.zero;

    _listenResumeTimer = Timer(delay, () {
      if (mounted && !_closing) _startListening();
    });
  }


  Future <void> _scanFeedback () async {
    try{ 
      //Subtle system click sound 
      SystemSound.play(SystemSoundType.click); 

      // Short vibration if supported
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(duration: 40);
      }
    } catch (_) {
      // Fail silently (accessibility-first)
    }
  }


  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'notListening' && mounted) {
          setState(() => _listening = false);

          // If we're in custom mode and we have a candidate prompt but never got
          // a finalResult callback, submit it once the recognizer stops.
          if (_mode == ScanMode.custom && _customPromptCandidate.trim().isNotEmpty) {
            final prompt = _customPromptCandidate.trim();
            _customPromptCandidate = '';
            _pendingPrompt = prompt;
            setState(() => _backendText = 'Asking...');
            _captureAndSendOnce(force: true);
          }

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
    if (_closing) return;
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

          // Handle commands as soon as they are recognized (partial or final).
          if (_handleSpeechCommand(words, isFinal: result.finalResult)) {
            return;
          }

          if (result.finalResult) {
            _handleFinalSpeech(words);
          }
        },
      );
    } catch (_) {
      // Backoff: speech engines can transiently report "busy".
      _speechMutedUntil = DateTime.now().add(const Duration(milliseconds: 800));
      if (mounted) setState(() => _listening = false);
      _scheduleListeningResume();
    }
  }

  void _handleFinalSpeech(String words) {
    // In custom mode, any final speech that isn't a command becomes the prompt.
    if (_mode == ScanMode.custom) {
      final prompt = words.trim();
      if (prompt.isEmpty) return;
      _customPromptCandidate = '';
      _pendingPrompt = prompt;
      setState(() {
        _backendText = 'Asking...';
      });
      Future.microtask(() => _captureAndSendOnce(force: true)); 
    }
  }

  bool _handleSpeechCommand(String words, {required bool isFinal}) {
    final lower = words.toLowerCase().trim();
    if (lower.isEmpty) return false;

    // If we're in custom mode, keep the latest candidate prompt.
    if (_mode == ScanMode.custom) {
      _customPromptCandidate = words;
    }

    // Basic cooldown so partial results don't trigger repeatedly.
    final now = DateTime.now();
    if (now.difference(_lastCommandAt) < _commandCooldown) {
      return false;
    }

    String? commandKey;
    VoidCallback? action;
    
    if (lower.contains('close camera')) {
      commandKey = 'close';
      action = () {
        _closeCamera();
      }; 

   } else if (lower.contains('repeat') || lower.contains('say again')) {
      commandKey = 'repeat'; 
      action = () {
        if (_lastSpokenText.isNotEmpty) {
          _speakSystem(_lastSpokenText); 
        }
      };
    } else if (lower.contains('stop talking') || lower.contains('be quiet')){
      commandKey = 'stop_tts'; 
      action =() async {
        await _tts.stop(); 
        _lastSpokenText = ''; 
        if (mounted) {
          setState(() {
            _backendText = 'Speech stopped'; 
          });
        }
      };     
    } else if (lower.contains('pause scanning') || lower.contains('stop scanning')) {
      commandKey = 'pause';
      action = () {
        setState(() {
          _autoScanEnabled = false;
          _backendText = 'Scanning paused';
        });
        _speakSystem('Scanning paused');
      };

    } else if (lower.contains('resume scanning') || lower.contains('start scanning')) {
      commandKey = 'resume';
      action = () {
        setState(() {
          _autoScanEnabled = true;
          _backendText = 'Scanning resumed';
        });
        _speakSystem('Scanning resumed');
        _captureAndSendOnce(force: true);
      };
      
    } else if (lower.contains('obstacle mode') ||
        lower.contains('obstacles mode') ||
        lower == 'obstacles' ||
        lower == 'obstacle') {
      commandKey = 'mode_obstacles';
      action = () {
        setState(() {
          _mode = ScanMode.obstacles;
          _backendText = 'Obstacle mode';
        });
        _speakSystem('Obstacle mode');
        _captureAndSendOnce(force: true);
      };
    } else if (lower.contains('crosswalk mode') ||
        lower.contains('cross walk mode') ||
        lower == 'crosswalk' ||
        lower == 'cross walk') {

      commandKey = 'mode_crosswalk';
      action = () {
        setState(() {
          // Set mode FIRST
          _mode = ScanMode.crosswalk;
          
          // Reset custom-mode state defensively
          _pendingPrompt = ''; 
          _customPromptCandidate = ''; 
          _autoScanEnabled = true; 

          // UI Feedback
          _backendText = 'Crosswalk mode';
        });

        // System feedback 
        _speakSystem('Crosswalk mode');

        // Reset scan loop for safety 
        _pictureTimer?.cancel(); 
        _startPictureLoop(); 

        // Immediate capture
        _captureAndSendOnce(force: true);
      };

    } else if (lower.contains('custom mode') ||
        lower.contains('question mode') ||
        lower.contains('ask question')) {
      commandKey = 'mode_custom';
      action = () {
        _autoScanBeforeCustom = _autoScanEnabled;

        // HARD stop auto scan immediately 
        _autoScanEnabled = false; 
        _pictureTimer?.cancel(); 

        setState(() {
          _mode = ScanMode.custom;
          _pendingPrompt = '';
          _customPromptCandidate = '';
          _backendText = 'Custom mode: ask your question.';
        });
        _speakSystem('Custom mode. Ask your question.');
      };
    }

    if (commandKey == null || action == null) {
      return false;
    }

    // Prevent duplicate triggers of the same command.
    if (commandKey == _lastCommandKey && now.difference(_lastCommandAt) < _commandCooldown) {
      return true;
    }

    _lastCommandKey = commandKey;
    _lastCommandAt = now;
    action();
    return true;
  }

  Future<void> _closeCamera() async {
    if (_closing) return;
    _closing = true;
    _pictureTimer?.cancel();
    _listenResumeTimer?.cancel();
    await _tts.stop();
    try {
      await _speech.cancel();
    } catch (_) {
      try {
        await _speech.stop();
      } catch (_) {
        // ignore
      }
    }

    try {
      if (_controller != null) {
        await _controller!.dispose();
        _controller = null;
      }
    } catch (_) {
      // ignore
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _closing = true;
    _pictureTimer?.cancel();
    _listenResumeTimer?.cancel();
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
