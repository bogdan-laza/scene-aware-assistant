import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SceneAssistantApp());
}

class SceneAssistantApp extends StatelessWidget {
  const SceneAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scene Assistant',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const VoiceHomeScreen(),
    );
  }
}

class VoiceHomeScreen extends StatefulWidget {
  const VoiceHomeScreen({super.key});

  @override
  State<VoiceHomeScreen> createState() => _VoiceHomeScreenState();
}

class _VoiceHomeScreenState extends State<VoiceHomeScreen> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _listening = false;
  String _lastHeard = '';

  @override
  void initState() {
    super.initState();
    _initAndListen();
  }

  Future<void> _initAndListen() async {
  await _requestPermissions();

  final available = await _speech.initialize(
    onStatus: (status) async {
      // Restart automatically when stopped for any reason
      if (status == 'notListening' && mounted && !_listening) {
        await Future.delayed(const Duration(milliseconds: 300));
        _startListening();
      }
    },
    onError: (error) {
      debugPrint('Speech error: $error');
      if (mounted) {
        setState(() => _listening = false);
        _startListening();
      }
    },
  );

  if (available && mounted) _startListening();
}

  
Future<void> _startListening() async {
  if (_listening) return;
  setState(() => _listening = true);

  await _speech.listen(
    listenMode: stt.ListenMode.dictation,
    partialResults: true,
    onResult: (result) async {
      final recognized = result.recognizedWords.toLowerCase().trim();
      if (!mounted) return;

      setState(() => _lastHeard = recognized);

      // Check if command is detected
      if (recognized.contains('open camera')) {
        await _speech.stop();
        setState(() => _listening = false);
        _navigateToCamera();
      }
    },
    cancelOnError: false,
    listenFor: const Duration(minutes: 10), // keep listening for 10 minutes
    pauseFor: const Duration(seconds: 60),  // allow long pauses
  );
}
  Future<void> _navigateToCamera() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CameraPreviewScreen()),
    );
    if (mounted) {
      setState(() {
        _listening = false;
      });
      _startListening();
    }
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.speech,
      Permission.camera,
    ].request();
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scene Assistant')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _listening ? Icons.mic : Icons.mic_off,
              color: _listening ? Colors.red : Colors.grey,
              size: 120, // Bigger mic icon
            ),
            const SizedBox(height: 20),
            Text(
              _lastHeard.isEmpty ? 'Listening...' : 'Heard: $_lastHeard',
              style: const TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            FilledButton.icon(
              icon: const Icon(Icons.camera_alt),
              label: const Text('Open Camera (Tap)'),
              onPressed: _navigateToCamera,
            ),
          ],
        ),
      ),

    );
  }
}
class CameraPreviewScreen extends StatefulWidget {
  const CameraPreviewScreen({super.key});

  @override
  State<CameraPreviewScreen> createState() => _CameraPreviewScreenState();
}

class _CameraPreviewScreenState extends State<CameraPreviewScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  bool _initializing = true;

  final FlutterTts _tts = FlutterTts();
  Timer? _speakTimer;
  final List<String> _phrases = const [
    'There is a person',
    'There is a tree',
    'There is a chair',
    'There is a car',
    'There is a door',
    'There is a table',
    'There is a dog',
  ];

  // 🎙 Speech-to-text for voice commands
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _setupTts();
    _initSpeech();
  }

 Future<void> _setupTts() async {
  await _tts.setLanguage('en-US');
  await _tts.setSpeechRate(0.5);
  await _tts.setVolume(1.0);
  await _tts.setPitch(1.0);
  await _tts.awaitSpeakCompletion(true);
}

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      final CameraDescription camera =
          _cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back,
              orElse: () => _cameras.first);

      _controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (!mounted) return;

      setState(() => _initializing = false);

      // Wait a moment before starting TTS & speech
      Future.delayed(const Duration(seconds: 1), () {
        _startTtsLoop();
        _startListening();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _initializing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Camera init failed: $e')),
      );
    }
  }

void _startTtsLoop() {
  _speakTimer?.cancel();
  _speakTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
    if (!mounted) return;

    // Pause listening so we don't hear our own TTS
    if (_listening) {
      await _speech.stop();
      _listening = false;
    }

    final phrase = (_phrases.toList()..shuffle()).first;
    try {
      await _tts.stop();
      await _tts.speak(phrase);
    } catch (e) {
      debugPrint('TTS error: $e');
    }

    // Resume listening after TTS finishes
    if (mounted && !_listening) {
      _startListening();
    }
  });
}

  Future<void> _initSpeech() async {
  final available = await _speech.initialize(
    onStatus: (status) {
      if (status == 'notListening' && mounted) {
        _listening = false;
        // Avoid immediate thrash; slight delay before resuming
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) _startListening();
        });
      }
    },
    onError: (error) {
      debugPrint('speech error: $error');
      _listening = false;
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _startListening();
      });
    },
  );
  if (available && mounted) _startListening();
}

Future<void> _startListening() async {
  if (_listening) return;
  _listening = true;

  await _speech.listen(
    listenMode: stt.ListenMode.dictation,
    partialResults: true,
    pauseFor: const Duration(seconds: 2),
    onResult: (result) {
      final command = result.recognizedWords.toLowerCase().trim();
      if (command.contains('close camera')) {
        _closeCamera();
      }
    },
  );
}

  Future<void> _closeCamera() async {
    _speakTimer?.cancel();
    await _tts.stop();
    await _speech.stop();

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _speakTimer?.cancel();
    _tts.stop();
    _speech.stop();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

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