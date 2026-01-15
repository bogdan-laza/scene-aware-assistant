/*import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:scene_aware_assistant_app/services/sound_service.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:vibration/vibration.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';

enum ScanMode { obstacles, crosswalk, custom }
enum _SpeechKind { system, result, error }

class CameraPreviewScreen extends StatefulWidget {
  const CameraPreviewScreen({super.key});

  @override
  State<CameraPreviewScreen> createState() => _CameraPreviewScreenState();
}

class _CameraPreviewScreenState extends State<CameraPreviewScreen> {
  CameraController? _controller;
  final SoundService _sounds = SoundService();
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

  bool _modeSelected = false;
  bool _waitingForCustomQuestion = false;

  DateTime _lastCommandAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastCommandKey = '';

  bool _autoScanEnabled = false;
  ScanMode _mode = ScanMode.obstacles;

  late final ApiClient _api;
  bool _sending = false;
  String _backendText = "";

  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastSpokenText = '';

  // TTS Queue Logic
  Future<void> _ttsChain = Future<void>.value();
  _SpeechKind? _activeSpeechKind;

  String _lastErrorText = '';

  static const Duration _captureInterval = Duration(seconds: 5);
  static const Duration _minRequestGap = Duration(seconds: 8);
  static const Duration _sttMuteAfterTts = Duration(milliseconds: 100);
  static const Duration _commandCooldown = Duration(seconds: 2);

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

    Future.delayed(const Duration(seconds: 1), () async {
      if (mounted && !_modeSelected) {
        await _speakSystem("Welcome. Please select a mode: Obstacles, Crosswalk, or Custom.", force: true);
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
      if (_mode == ScanMode.custom) return;
      await _captureAndSendOnce();
    });
  }

  Future<void> _captureAndSendOnce({String? explicitPrompt}) async {
    if (_closing) return;
    
    // Safety Checks
    if (!mounted || _controller == null || !_controller!.value.isInitialized) {
      debugPrint("Camera not ready");
      return;
    }
    if (_controller!.value.isTakingPicture || _sending || _captureInFlight) {
      debugPrint("Busy: Sending or capturing");
      return;
    }

    // Gap Check (Skip if too soon, unless manual)
    final now = DateTime.now();
    if (explicitPrompt == null && now.difference(_lastRequestAt) < _minRequestGap) {
      return;
    }

    _captureInFlight = true;
    try {
      _lastRequestAt = now;

      // 1. FEEDBACK FIRST (So user knows it's working)
      // Only speak "Processing" if it's a manual action or the first auto-scan
      // to avoid annoying repetition every 8 seconds.
      if (explicitPrompt != null || !_modeSelected) {
        await _speakSystem("Processing scene...");
      } else {
        // For auto-scans, just a subtle click is better
         _scanFeedback();
      }

      setState(() {
        _sending = true;
        _backendText = "Capturing...";
      });

      // 2. Take Picture
      final XFile file = await _controller!.takePicture();
      
      // 3. Send
      await _sendToBackend(file, explicitPrompt: explicitPrompt);

    } catch (e) {
      debugPrint('Error in capture sequence: $e');
      _speakError("Camera error.");
    } finally {
      _captureInFlight = false;
    }
  }

  Future<void> _sendToBackend(XFile image, {String? explicitPrompt}) async {
    if (_closing) return;

    setState(() {
      _sending = true;
      _backendText = "Analyzing...";
    });

    try {
      Map<String, dynamic> json;
      if (_mode == ScanMode.custom) {
        if (explicitPrompt == null || explicitPrompt.isEmpty) throw ApiException('Missing prompt');
        json = await _api.sendCustom(image, explicitPrompt);
      } else if (_mode == ScanMode.crosswalk) {
        json = await _api.sendCrosswalk(image);
      } else {
        json = await _api.sendObstacles(image);
      }

      if (_mode == ScanMode.custom) {
        _waitingForCustomQuestion = false;
        setState(() {
          _backendText = "Answer received. Say 'I have a question' to ask again.";
        });
      }

      final resultText = (json['result'] ?? '').toString().trim();
      final spoken = resultText.trim();

      if (!mounted) return;
      setState(() => _backendText = resultText);
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

  // --- SPEECH LOGIC ---

  Future<void> _initSpeech() async {
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
            listenMode: stt.ListenMode.search,
            partialResults: true
        ),
        pauseFor: const Duration(seconds: 3),
        onResult: (result) {
          if (!mounted) return;
          setState(() => _currentWords = result.recognizedWords);

          if (_handleSpeechCommand(result.recognizedWords)) {
            return;
          }

          if (result.finalResult && _mode == ScanMode.custom && _waitingForCustomQuestion) {
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
    setState(() => _waitingForCustomQuestion = false);
    _captureAndSendOnce(explicitPrompt: question);
  }

  bool _handleSpeechCommand(String words) {
    final lower = words.toLowerCase().trim();
    if (lower.isEmpty) return false;

    final now = DateTime.now();
    if (now.difference(_lastCommandAt) < _commandCooldown) return false;

    String? commandKey;
    VoidCallback? action;

    if (lower.contains('obstacle')) {
      commandKey = 'mode_obstacles';
      action = () => _switchMode(ScanMode.obstacles, "Obstacle mode active.");
    } else if (lower.contains('crosswalk') || lower.contains('cross walk')) {
      commandKey = 'mode_crosswalk';
      action = () => _switchMode(ScanMode.crosswalk, "Crosswalk mode active.");
    } else if (lower.contains('custom') || lower.contains('question mode')) {
      commandKey = 'mode_custom';
      action = () => _switchMode(ScanMode.custom, "Custom mode. Say 'I have a question' when ready.");
    }
    else if (_mode == ScanMode.custom && lower.contains('i have a question')) {
      commandKey = 'trigger_question';
      action = () {
        setState(() => _waitingForCustomQuestion = true);
        _speakSystem("I'm listening, ask away.");
      };
    }
    else if (lower.contains('close camera')) {
      commandKey = 'close';
      action = _closeCamera;
    } else if (lower.contains('stop')) {
      commandKey = 'stop';
      action = () => _tts.stop();
    }

    if (commandKey != null && action != null) {
      if (commandKey == _lastCommandKey && now.difference(_lastCommandAt) < _commandCooldown) return true;

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
      _waitingForCustomQuestion = false;
      _autoScanEnabled = (newMode != ScanMode.custom);
      
      // Reset request timer so the first scan happens immediately
      _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
    });

    _speakSystem(speechFeedback);

    _pictureTimer?.cancel();
    if (_autoScanEnabled) {
      _startPictureLoop();
      // FIX: No delay. Start immediately.
      _captureAndSendOnce();
    }
  }

  // --- TTS & HELPERS ---

  Future<void> _speakIfNeeded(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || clean == _lastSpokenText) return;
    await _speak(clean, kind: _SpeechKind.result, interrupt: true, force: false);
  }

  Future<void> _speakError(String text) async {
    if (text == _lastErrorText) return;
    _lastErrorText = text;
    await _speak(text, kind: _SpeechKind.error, interrupt: true, force: false);
  }

  Future<void> _speakSystem(String text, {bool force = false}) async {
    await _speak(text, kind: _SpeechKind.system, interrupt: false, force: force);
  }

  Future<void> _speak(String text, {required _SpeechKind kind, required bool interrupt, required bool force}) async {
    if (_closing) return;

    final completer = Completer<void>();

    _ttsChain = _ttsChain.then((_) async {
      _activeSpeechKind = kind;
      _lastSpokenText = text;
      try {
        // Safe stop logic
        await _stopListeningForTts();
        if (interrupt) await _tts.stop();
        
        await _tts.speak(text); 
      } catch (_) {
      } finally {
        completer.complete();
        _speechMutedUntil = DateTime.now().add(_sttMuteAfterTts);
        _scheduleListeningResume();
        _activeSpeechKind = null;
      }
    });

    return completer.future;
  }

  Future<void> _stopListeningForTts() async {
    try { 
      // Add a small timeout to stop() to prevent hanging
      await _speech.stop().timeout(const Duration(milliseconds: 200)); 
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
      if (await Vibration.hasVibrator() == true) Vibration.vibrate(duration: 40);
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
    _tts.stop();
    _speech.stop();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String overlayText;
    if (!_modeSelected) {
      overlayText = "Say: Obstacles, Crosswalk, or Custom";
    } else if (_sending) {
      overlayText = "Processing scene...";
    } else if (_waitingForCustomQuestion) {
      overlayText = "Listening for question...";
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

          Positioned(
            bottom: 100, left: 20, right: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: Text(
                overlayText,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          
          Positioned(
            left: 0, right: 0, bottom: 24,
            child: Center(child: FilledButton(onPressed: _closeCamera, child: const Text('Close'))),
          ),
        ],
      ),
    );
  }
}*/
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:scene_aware_assistant_app/services/sound_service.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:vibration/vibration.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';

enum ScanMode { obstacles, crosswalk, custom }
enum _SpeechKind { system, result, error }

class CameraPreviewScreen extends StatefulWidget {
  const CameraPreviewScreen({super.key});

  @override
  State<CameraPreviewScreen> createState() => _CameraPreviewScreenState();
}

class _CameraPreviewScreenState extends State<CameraPreviewScreen> {
  CameraController? _controller;
  final SoundService _sounds = SoundService();
  Timer? _listenResumeTimer;
  List<CameraDescription> _cameras = const [];
  bool _initializing = true;
  bool _closing = false;
  bool _captureInFlight = false;



  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speech = stt.SpeechToText();
  
  // Logic flag: Do we WANT to be listening? (Vs hardware actually listening)
  bool _shouldBeListening = false; 
  String _currentWords = "";

  DateTime _speechMutedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  bool _modeSelected = false; 
  bool _waitingForCustomQuestion = false;

  DateTime _lastCommandAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastCommandKey = '';

  ScanMode _mode = ScanMode.obstacles;

  late final ApiClient _api;
  bool _sending = false;
  String _backendText = "";

  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastSpokenText = '';

  Future<void> _ttsChain = Future<void>.value();
  _SpeechKind? _activeSpeechKind;
  String _lastErrorText = '';

  static const Duration _minRequestGap = Duration(milliseconds: 500); 
  static const Duration _sttMuteAfterTts = Duration(milliseconds: 100);
  static const Duration _commandCooldown = Duration(seconds: 1); 

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

    Future.delayed(const Duration(seconds: 1), () async {
      if (mounted && !_modeSelected) {
        await _speakSystem("Welcome. Please select a mode: Obstacles, Crosswalk, or Custom.", force: true);
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _initializing = false);
    }
  }

  // --- CAPTURE LOGIC ---

  Future<void> _captureAndSendOnce({String? explicitPrompt}) async {
    if (_closing) return;
    
    if (!mounted || _controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isTakingPicture || _sending || _captureInFlight) return;

    final now = DateTime.now();
    if (explicitPrompt == null && now.difference(_lastRequestAt) < _minRequestGap) return;

    _captureInFlight = true;
    try {
      _lastRequestAt = now;

      // Feedback: Speak if mode switch or custom; Click if just "Scan"
      if (explicitPrompt != null || !_modeSelected) {
         await _speakSystem("Processing scene...");
      } else {
         _scanFeedback(); 
      }

      setState(() {
        _sending = true;
        _backendText = "Capturing...";
        _currentWords = ""; 
      });

      final XFile file = await _controller!.takePicture();
      await _sendToBackend(file, explicitPrompt: explicitPrompt);

    } catch (e) {
      debugPrint('Error in capture sequence: $e');
      _speakError("Camera error.");
    } finally {
      _captureInFlight = false;
    }
  }

  Future<void> _sendToBackend(XFile image, {String? explicitPrompt}) async {
    if (_closing) return;

    setState(() {
      _sending = true;
      _backendText = "Analyzing...";
    });

    try {
      Map<String, dynamic> json;
      if (_mode == ScanMode.custom) {
        if (explicitPrompt == null || explicitPrompt.isEmpty) throw ApiException('Missing prompt');
        json = await _api.sendCustom(image, explicitPrompt);
      } else if (_mode == ScanMode.crosswalk) {
        json = await _api.sendCrosswalk(image);
      } else {
        json = await _api.sendObstacles(image);
      }

      if (_mode == ScanMode.custom) {
        _waitingForCustomQuestion = false;
        setState(() {
          _backendText = "Answer received. Say 'I have a question' to ask again.";
        });
      }

      final resultText = (json['result'] ?? '').toString().trim();
      final spoken = resultText.trim();

      if (!mounted) return;
      setState(() => _backendText = resultText);
      
      await _speak(spoken, kind: _SpeechKind.result, interrupt: true, force: true);

    } catch (e) {
      if (!mounted) return;
      String msg = "I couldn't process that.";
      setState(() => _backendText = msg);
      await _speakError(msg);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // --- "ZOMBIE LOOP" SPEECH LOGIC (Infinite Listen) ---

  Future<void> _initSpeech() async {
    await _speech.initialize(
      onStatus: (status) {
        debugPrint("Speech Status: $status");
        // If the OS stops the listener (done or timeout), restart it immediately
        if ((status == 'notListening' || status == 'done') && mounted && !_closing) {
           if (_shouldBeListening) {
             _scheduleListeningResume();
           }
        }
      },
      onError: (e) {
        debugPrint("Speech Error: $e");
        if (mounted && _shouldBeListening) {
          _scheduleListeningResume();
        }
      },
    );
  }

  Future<void> _startListening() async {
    if (_closing) return;
    
    // Check if we are blocked by TTS
    if (DateTime.now().isBefore(_speechMutedUntil)) {
       _scheduleListeningResume(); 
       return;
    }

    if (mounted) setState(() => _shouldBeListening = true);

    if (_speech.isListening) return;

    try {
      await _speech.listen(
        listenOptions: stt.SpeechListenOptions(
            listenMode: stt.ListenMode.search,
            partialResults: true,
            cancelOnError: false, 
        ),
        // Use short duration to refresh the session frequently (Zombie Loop)
        listenFor: const Duration(seconds: 30), 
        pauseFor: const Duration(seconds: 5),
        
        onResult: (result) {
          if (!mounted) return;
          setState(() => _currentWords = result.recognizedWords);

          if (_handleSpeechCommand(result.recognizedWords)) {
            return;
          }

          if (result.finalResult && _mode == ScanMode.custom && _waitingForCustomQuestion) {
            String question = result.recognizedWords.trim();
            if (question.isNotEmpty) {
              _handleCustomQuestionSubmit(question);
            }
          }
        },
      );
    } catch (_) {
      _scheduleListeningResume();
    }
  }

  void _handleCustomQuestionSubmit(String question) {
    _sounds.playMicClose();
    setState(() => _waitingForCustomQuestion = false);
    _captureAndSendOnce(explicitPrompt: question);
  }

  bool _handleSpeechCommand(String words) {
    final lower = words.toLowerCase().trim();
    if (lower.isEmpty) return false;

    final now = DateTime.now();
    if (now.difference(_lastCommandAt) < _commandCooldown) return false;

    String? commandKey;
    VoidCallback? action;

    // --- 1. SCAN TRIGGERS ---
    if (_modeSelected && (
        lower.contains('scan') || 
        lower.contains('next') || 
        lower.contains('go') || 
        lower.contains('capture'))) {
       commandKey = 'trigger_scan';
       action = () => _captureAndSendOnce(); 
    }

    // --- 2. MODE SWITCHING ---
    // Note: .contains() handles "Change to obstacle", "Switch obstacle", "Obstacles" etc.
    else if (lower.contains('obstacle')) {
      commandKey = 'mode_obstacles';
      action = () => _switchMode(ScanMode.obstacles, "Obstacle mode active.");
    } 
    else if (lower.contains('crosswalk') || lower.contains('cross walk')) {
      commandKey = 'mode_crosswalk';
      action = () => _switchMode(ScanMode.crosswalk, "Crosswalk mode active.");
    } 
    else if (lower.contains('custom') || lower.contains('question mode')) {
      commandKey = 'mode_custom';
      action = () => _switchMode(ScanMode.custom, "Custom mode. Say 'I have a question' when ready.");
    }
    
    // --- 3. CUSTOM MODE SPECIFIC ---
    else if (_mode == ScanMode.custom && lower.contains('i have a question')) {
      commandKey = 'trigger_question';
      action = () {
        setState(() => _waitingForCustomQuestion = true);
        _speakSystem("I'm listening, ask away.");
      };
    }

    // --- 4. UTILITIES ---
    else if (lower.contains('close camera')) {
      commandKey = 'close';
      action = _closeCamera;
    } else if (lower.contains('stop')) {
      commandKey = 'stop';
      action = () => _tts.stop();
    }

    // EXECUTE COMMAND
    if (commandKey != null && action != null) {
      if (commandKey == _lastCommandKey && now.difference(_lastCommandAt) < _commandCooldown) return true;

      _lastCommandKey = commandKey;
      _lastCommandAt = now;
      _sounds.playMicClose(); 

      setState(() => _currentWords = ""); // Clear text so user sees update
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
      _waitingForCustomQuestion = false;
      _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
    });

    _speakSystem(speechFeedback);

    // KEY FEATURE: Scans immediately when switching modes (except custom)
    if (newMode != ScanMode.custom) {
      _captureAndSendOnce();
    }
  }

  // --- TTS & HELPERS ---

  Future<void> _speakIfNeeded(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    await _speak(clean, kind: _SpeechKind.result, interrupt: true, force: false);
  }

  Future<void> _speakError(String text) async {
    if (text == _lastErrorText) return;
    _lastErrorText = text;
    await _speak(text, kind: _SpeechKind.error, interrupt: true, force: false);
  }

  Future<void> _speakSystem(String text, {bool force = false}) async {
    await _speak(text, kind: _SpeechKind.system, interrupt: false, force: force);
  }

  Future<void> _speak(String text, {required _SpeechKind kind, required bool interrupt, required bool force}) async {
    if (_closing) return;

    final completer = Completer<void>();

    _ttsChain = _ttsChain.then((_) async {
      _activeSpeechKind = kind;
      _lastSpokenText = text;
      try {
        // Pause listening while speaking to avoid feedback loop
        setState(() => _shouldBeListening = false); 
        await _speech.stop();
        
        if (interrupt) await _tts.stop();
        await _tts.speak(text); 
      } catch (_) {
      } finally {
        completer.complete();
        _speechMutedUntil = DateTime.now().add(_sttMuteAfterTts);
        _activeSpeechKind = null;

        // RESUME LISTENING IMMEDIATELY AFTER SPEAKING
        setState(() => _shouldBeListening = true);
        _scheduleListeningResume();
      }
    });

    return completer.future;
  }

  Future<void> _stopListeningForTts() async {
    try { 
      await _speech.stop().timeout(const Duration(milliseconds: 200)); 
    } catch (_) {}
  }

  void _scheduleListeningResume() {
    _listenResumeTimer?.cancel();
    _listenResumeTimer = Timer(_sttMuteAfterTts, () {
      if (mounted && !_closing && _shouldBeListening) {
        _startListening();
      }
    });
  }

  Future<void> _scanFeedback() async {
    try {
      SystemSound.play(SystemSoundType.click);
      if (await Vibration.hasVibrator() == true) Vibration.vibrate(duration: 40);
    } catch (_) {}
  }

  Future<void> _closeCamera() async {
    _closing = true;
    _shouldBeListening = false;
    await _tts.stop();
    await _speech.stop();
    _controller?.dispose();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _closing = true;
    _shouldBeListening = false;
    _tts.stop();
    _speech.stop();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String overlayText;

    if (_currentWords.isNotEmpty) {
      overlayText = _currentWords;
    } 
    else if (!_modeSelected) {
      overlayText = "Say: Obstacles, Crosswalk, or Custom";
    } else if (_sending) {
      overlayText = "Scanning...";
    } else if (_waitingForCustomQuestion) {
      overlayText = "Listening for question...";
    } else {
      overlayText = _backendText.isEmpty ? "Say 'Scan', 'Next', or change mode" : _backendText;
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
          
          if (_shouldBeListening)
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.greenAccent.withOpacity(0.5), width: 8),
              ),
            ),

          Positioned(
            bottom: 100, left: 20, right: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: Text(
                overlayText,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          
          Positioned(
             top: 50, right: 20,
             child: Icon(
                _shouldBeListening ? Icons.mic : Icons.mic_off, 
                color: _shouldBeListening ? Colors.greenAccent : Colors.red,
                size: 36
             )
          ),

          Positioned(
            left: 0, right: 0, bottom: 24,
            child: Center(child: FilledButton(onPressed: _closeCamera, child: const Text('Close'))),
          ),
        ],
      ),
    );
  }
}