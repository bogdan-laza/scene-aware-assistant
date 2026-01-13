import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:scene_aware_assistant_app/services/sound_service.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:vibration/vibration.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';

enum ScanMode { obstacles, crosswalk, custom, ocr }

enum _SpeechKind { system, result, error }

class CameraPreviewScreen extends StatefulWidget {
  const CameraPreviewScreen({super.key});

  @override
  State<CameraPreviewScreen> createState() => _CameraPreviewScreenState();
}

class _CameraPreviewScreenState extends State<CameraPreviewScreen> {
  CameraController? _controller;
  final SoundService _sounds = SoundService();
  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
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

  // NEW: State variables for the new flow
  bool _modeSelected = false; // Waits for initial mode selection
  bool _waitingForCustomQuestion =
      false; // True after saying "I have a question"

  DateTime _lastCommandAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastCommandKey = '';

  // Default to false so we don't start until user picks a mode
  bool _autoScanEnabled = false;
  ScanMode _mode = ScanMode.obstacles;

  late final ApiClient _api;
  bool _sending = false;
  String _backendText = "";

  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastSpokenText = '';

  DateTime _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);

  // TTS Queue Logic
  Future<void> _ttsChain = Future<void>.value();
  DateTime _lastErrorSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastErrorText = '';

  static const Duration _captureInterval = Duration(seconds: 8);
  static const Duration _minRequestGap = Duration(seconds: 8);
  static const Duration _minSpeakGap = Duration(seconds: 4);
  static const Duration _sttMuteAfterTts = Duration(milliseconds: 100);
  static const Duration _commandCooldown = Duration(seconds: 2);
  static const Duration _minOcrGap = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _api = ApiClient();
    _initCamera();
    _setupTts();
    _initSpeech();
    _sounds.init();
  }

  Future<void> _setupTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.awaitSpeakCompletion(true);

    // Speak welcome message once TTS is ready
    // CRITICAL FIX: Wait for TTS to be fully ready, then speak, THEN start listening.
    Future.delayed(const Duration(seconds: 1), () async {
      if (mounted && !_modeSelected) {
        await _speakSystem(
          "Welcome. Please select a mode: Obstacles, Crosswalk, Custom, or Text.",
          force: true,
        );
        // Only start listening AFTER the system finishes speaking to avoid mic conflict
        _speechMutedUntil = DateTime(0);
        if (mounted) _startListening();
      }
    });
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

      // Note: We do NOT start the picture loop here anymore.
      // We wait for the user to select a mode first.
    } catch (e) {
      if (!mounted) return;
      setState(() => _initializing = false);
    }
  }

  void _startPictureLoop() {
    _pictureTimer?.cancel();
    _pictureTimer = Timer.periodic(_captureInterval, (_) async {
      if (_closing) return;
      if (!_autoScanEnabled) return;
      // In custom mode, the loop does nothing. It waits for commands.
      if (_mode == ScanMode.custom || _mode == ScanMode.ocr) return;
      await _captureAndSendOnce();
    });
  }

  Future<void> _captureAndSendOnce({String? explicitPrompt}) async {
    if (_closing) return;
    if (!mounted || _controller == null || !_controller!.value.isInitialized) {
      return;
    }
    if (_controller!.value.isTakingPicture) return;
    if (_sending || _captureInFlight) return;

    // In custom mode, we only proceed if we have an explicit prompt passed in
    if (_mode == ScanMode.custom &&
        (explicitPrompt == null || explicitPrompt.isEmpty)) {
      return;
    }

    final now = DateTime.now();
    // Force allow if custom prompt, otherwise check gap
    if (explicitPrompt == null &&
        now.difference(_lastRequestAt) < _minRequestGap) {
      return;
    }

    _captureInFlight = true;
    try {
      _lastRequestAt = now;
      final XFile file = await _controller!.takePicture();
      await _scanFeedback(); // Click sound
      await _sendToBackend(file, explicitPrompt: explicitPrompt);
    } catch (e) {
      debugPrint('Error capturing photo: $e');
    } finally {
      _captureInFlight = false;
    }
  }

  Future<void> _sendToBackend(XFile image, {String? explicitPrompt}) async {
    if (_closing) return;

    // Immediate feedback
    await _speakSystem("Processing scene...");
    setState(() {
      _sending = true;
      _backendText = "Processing scene...";
    });

    try {
      Map<String, dynamic> json;
      if (_mode == ScanMode.custom) {
        if (explicitPrompt == null || explicitPrompt.isEmpty) {
          throw ApiException('Missing prompt');
        }
        json = await _api.sendCustom(image, explicitPrompt);
      } else if (_mode == ScanMode.crosswalk) {
        json = await _api.sendCrosswalk(image);
      } else {
        json = await _api.sendObstacles(image);
      }

      // If we were in custom mode, we answered the question.
      // Now reset to idle custom state.
      if (_mode == ScanMode.custom) {
        _waitingForCustomQuestion = false;
        // We stay in custom mode, but stop processing until next "I have a question"
        setState(() {
          _backendText =
              "Answer received. Say 'I have a question' to ask again.";
        });
      }

      final resultText = (json['result'] ?? '').toString().trim();
      final spoken = _formatSpokenResult(resultText);

      if (!mounted) return;
      setState(() {
        _backendText = resultText;
      });

      await _speakIfNeeded(spoken);
    } catch (e) {
      if (!mounted) return;
      String msg = "I couldn't process that.";
      setState(() => _backendText = msg);
      await _speakError(msg);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _captureAndReadTextOnce() async {
    if (_closing) return;
    if (!mounted || _controller == null || !_controller!.value.isInitialized) {
      return;
    }
    if (_controller!.value.isTakingPicture) return;
    if (_sending || _captureInFlight) return;

    final now = DateTime.now();
    if (now.difference(_lastOcrAt) < _minOcrGap) return;
    _lastOcrAt = now;

    _captureInFlight = true;
    try {
      await _speakSystem("Reading text...");
      setState(() {
        _backendText = "Reading text...";
      });

      final XFile file = await _controller!.takePicture();
      await _scanFeedback();
      await _runOcr(file);
    } catch (e) {
      debugPrint('OCR error: $e');
      setState(() {
        _backendText =
            "Couldn't read text. Try moving closer or improving lighting.";
      });
      await _speakError(
        "I couldn't read text. Try moving closer or improving lighting.",
      );
    } finally {
      _captureInFlight = false;
    }
  }

  Future<void> _runOcr(XFile image) async {
    final inputImage = InputImage.fromFilePath(image.path);
    final recognizedText = await _textRecognizer.processImage(inputImage);

    final spoken = _formatOcrSpokenText(recognizedText);
    setState(() {
      _backendText = spoken;
    });
    await _speakIfNeeded(spoken);
  }

  String _formatOcrSpokenText(RecognizedText recognizedText) {
    final lines = <String>[];
    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final t = line.text.trim();
        if (t.isNotEmpty) lines.add(t);
      }
    }

    if (lines.isEmpty) {
      return "No readable text detected. Move closer or adjust the camera.";
    }

    // Demo-safe: keep it short and readable.
    const maxLines = 4;
    const maxChars = 240;

    final take = lines.take(maxLines).toList();
    var combined = take.join('. ');
    combined = combined
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (combined.length > maxChars) {
      combined = combined.substring(0, maxChars).trimRight();
      combined = '$combined…';
    }

    if (lines.length > maxLines) {
      combined = '$combined. More text detected.';
    }
    return combined;
  }

  String _formatSpokenResult(String resultText) {
    // Just return the clean text, no "I might be wrong" logic.
    return resultText.trim();
  }

  // --- SPEECH LOGIC CHANGED HERE ---

  Future<void> _initSpeech() async {
    // Initialize speech, BUT DO NOT START LISTENING YET.
    // We let _setupTts call _startListening after the welcome message.
    await _speech.initialize(
      onStatus: (status) {
        if (status == 'notListening' && mounted) {
          setState(() => _listening = false);
          _scheduleListeningResume();
        }
      },
      onError: (e) {
        if (mounted) setState(() => _listening = false);
        _scheduleListeningResume();
      },
    );
  }

  Future<void> _startListening() async {
    if (_closing) return;
    if (DateTime.now().isBefore(_speechMutedUntil)) return;
    if (_listening || _speech.isListening) return;

    await _sounds.playMicOpen();

    setState(() => _listening = true);

    try {
      await _speech.listen(
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt
              .ListenMode
              .search, // Changed to SEARCH for better compatibility
          partialResults: true,
        ),
        pauseFor: const Duration(seconds: 3),
        onResult: (result) {
          if (!mounted) return;
          setState(() => _currentWords = result.recognizedWords);

          // 1. Check for Commands (Mode switching, "I have a question")
          if (_handleSpeechCommand(result.recognizedWords)) {
            return;
          }

          // 2. Handle Custom Question Input
          if (result.finalResult &&
              _mode == ScanMode.custom &&
              _waitingForCustomQuestion) {
            // The user said "I have a question", app said "Listening", now we have the question.
            String question = result.recognizedWords.trim();
            if (question.isNotEmpty) {
              _handleCustomQuestionSubmit(question);
            }
          }
        },
      );
    } catch (_) {
      _speechMutedUntil = DateTime.now().add(const Duration(seconds: 1));
      if (mounted) setState(() => _listening = false);
      _scheduleListeningResume();
    }
  }

  void _handleCustomQuestionSubmit(String question) {
    _sounds.playMicClose();
    setState(() => _waitingForCustomQuestion = false); // Stop waiting
    // Send it!
    _captureAndSendOnce(explicitPrompt: question);
  }

  bool _handleSpeechCommand(String words) {
    final lower = words.toLowerCase().trim();
    if (lower.isEmpty) return false;

    // Debounce
    final now = DateTime.now();
    if (now.difference(_lastCommandAt) < _commandCooldown) return false;

    String? commandKey;
    VoidCallback? action;

    // --- MODE SELECTION ---
    if (lower.contains('obstacle')) {
      commandKey = 'mode_obstacles';
      action = () => _switchMode(ScanMode.obstacles, "Obstacle mode active.");
    } else if (lower.contains('crosswalk') || lower.contains('cross walk')) {
      commandKey = 'mode_crosswalk';
      action = () => _switchMode(ScanMode.crosswalk, "Crosswalk mode active.");
    } else if (lower.contains('custom') || lower.contains('question mode')) {
      commandKey = 'mode_custom';
      action = () => _switchMode(
        ScanMode.custom,
        "Custom mode. Say 'I have a question' when ready.",
      );
    } else if (lower.contains('text mode') ||
        lower.contains('ocr mode') ||
        lower == 'text' ||
        lower == 'ocr') {
      commandKey = 'mode_ocr';
      action = () =>
          _switchMode(ScanMode.ocr, "Text mode. Say 'read text' when ready.");
    }
    // --- CUSTOM MODE TRIGGER ---
    else if (_mode == ScanMode.custom && lower.contains('i have a question')) {
      commandKey = 'trigger_question';
      action = () {
        setState(() => _waitingForCustomQuestion = true);
        _speakSystem("I'm listening, ask away.");
        // We do NOT stop listening here; we wait for the NEXT result which will be the question
      };
    }
    // --- OCR TRIGGER ---
    else if (_mode == ScanMode.ocr &&
        (lower.contains('read text') ||
            lower.contains('scan text') ||
            lower == 'read')) {
      commandKey = 'read_text';
      action = _captureAndReadTextOnce;
    }
    // --- UTILITIES ---
    else if (lower.contains('close camera')) {
      commandKey = 'close';
      action = _closeCamera;
    } else if (lower.contains('stop')) {
      commandKey = 'stop';
      action = () => _tts.stop();
    }

    if (commandKey != null && action != null) {
      // Prevent duplicates
      if (commandKey == _lastCommandKey &&
          now.difference(_lastCommandAt) < _commandCooldown) {
        return true;
      }

      _lastCommandKey = commandKey;
      _lastCommandAt = now;
      _sounds.playMicClose();

      action();
      return true;
    }

    return false;
  }

  void _switchMode(ScanMode newMode, String speechFeedback) {
    setState(() {
      _modeSelected = true;
      _mode = newMode;
      _backendText = speechFeedback;
      _waitingForCustomQuestion = false; // Reset custom state

      // Auto-scan is ON for Obstacles/Crosswalk, OFF for Custom/OCR
      _autoScanEnabled =
          (newMode == ScanMode.obstacles || newMode == ScanMode.crosswalk);
    });

    _speakSystem(speechFeedback);

    // Restart/Start loop
    _pictureTimer?.cancel();
    if (_autoScanEnabled) {
      _startPictureLoop();
      // Also trigger one immediately so user doesn't wait 8s
      Future.delayed(const Duration(seconds: 2), () => _captureAndSendOnce());
    }
  }

  // --- TTS & HELPERS (Standard) ---

  Future<void> _speakIfNeeded(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || clean == _lastSpokenText) return;

    final now = DateTime.now();
    if (now.difference(_lastSpokenAt) < _minSpeakGap) return;
    _lastSpokenAt = now;

    await _speak(
      clean,
      kind: _SpeechKind.result,
      interrupt: true,
      force: false,
    );
  }

  Future<void> _speakError(String text) async {
    if (text == _lastErrorText) return;

    final now = DateTime.now();
    if (now.difference(_lastErrorSpokenAt) < _minSpeakGap) return;
    _lastErrorSpokenAt = now;

    _lastErrorText = text;
    await _speak(text, kind: _SpeechKind.error, interrupt: true, force: false);
  }

  Future<void> _speakSystem(String text, {bool force = false}) async {
    await _speak(
      text,
      kind: _SpeechKind.system,
      interrupt: false,
      force: force,
    );
  }

  Future<void> _speak(
    String text, {
    required _SpeechKind kind,
    required bool interrupt,
    required bool force,
  }) async {
    if (_closing) return;

    // We use a Completer so we can await the actual end of speaking
    final completer = Completer<void>();

    _ttsChain = _ttsChain.then((_) async {
      _lastSpokenText = text;
      try {
        await _stopListeningForTts();
        if (interrupt) await _tts.stop();

        // This 'await' works because we set awaitSpeakCompletion(true) in init
        await _tts.speak(text);
      } catch (_) {
      } finally {
        // Signal that this specific utterance is done
        completer.complete();

        _speechMutedUntil = DateTime.now().add(_sttMuteAfterTts);
        _scheduleListeningResume();
      }
    });

    return completer.future;
  }

  Future<void> _stopListeningForTts() async {
    try {
      await _speech.stop();
    } catch (_) {}
    if (mounted) setState(() => _listening = false);
  }

  void _scheduleListeningResume() {
    _listenResumeTimer?.cancel();
    _listenResumeTimer = Timer(_sttMuteAfterTts, () {
      if (mounted && !_closing) _startListening();
    });
  }

  Future<void> _scanFeedback() async {
    try {
      SystemSound.play(SystemSoundType.click);
      if (await Vibration.hasVibrator() == true) {
        Vibration.vibrate(duration: 40);
      }
    } catch (_) {}
  }

  Future<void> _closeCamera() async {
    _closing = true;
    _pictureTimer?.cancel();
    await _tts.stop();
    await _speech.stop();
    _controller?.dispose();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _closing = true;
    _pictureTimer?.cancel();
    _textRecognizer.close();
    _tts.stop();
    _speech.stop();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String overlayText;
    if (!_modeSelected) {
      overlayText = "Say: Obstacles, Crosswalk, Custom, or Text";
    } else if (_sending) {
      overlayText = "Processing scene...";
    } else if (_waitingForCustomQuestion) {
      overlayText = "Listening for question...";
    } else if (_mode == ScanMode.ocr) {
      overlayText = _backendText.isEmpty ? "Say 'read text'" : _backendText;
    } else {
      overlayText = _backendText.isEmpty ? _currentWords : _backendText;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Camera')),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              fit: StackFit.expand,
              children: [
                if (_controller != null && _controller!.value.isInitialized)
                  CameraPreview(_controller!),

                // Instructions Overlay
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

                // DEBUG MIC BUTTON (Top Right)
                // Use this if the automatic listener doesn't start!
                Positioned(
                  top: 50,
                  right: 20,
                  child: IconButton(
                    icon: const Icon(
                      Icons.mic,
                      color: Colors.greenAccent,
                      size: 36,
                    ),
                    onPressed: () {
                      debugPrint("Manually starting listener...");
                      _speechMutedUntil = DateTime.now();
                      _startListening();
                    },
                  ),
                ),

                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_modeSelected && _mode == ScanMode.ocr) ...[
                          FilledButton(
                            onPressed: _captureAndReadTextOnce,
                            child: const Text('Read Text'),
                          ),
                          const SizedBox(width: 12),
                        ],
                        FilledButton(
                          onPressed: _closeCamera,
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
