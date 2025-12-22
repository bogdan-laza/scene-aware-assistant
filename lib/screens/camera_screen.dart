import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

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
  Timer? _speakTimer;
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _listening = false;
  String _currentWords = "";

  final List<String> _phrases = const [
    'There is a person',
    'There is a tree',
    'There is a chair',
  ];

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
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      final CameraDescription camera = _cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => _cameras.first);

      _controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (!mounted) return;

      setState(() => _initializing = false);

      _startPictureLoop();

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

  void _startPictureLoop() {
    _pictureTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted || _controller == null || !_controller!.value.isInitialized) return;
      if (_controller!.value.isTakingPicture) return;

      try {
        final XFile file = await _controller!.takePicture();
        debugPrint("Auto-capture success: ${file.path}");
      } catch (e) {
        debugPrint("Error capturing photo: $e");
      }
    });
  }

  void _startTtsLoop() {
    _speakTimer?.cancel();
    _speakTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!mounted) return;

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
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted) _startListening();
          });
        }
      },
      onError: (error) {
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
        setState(() {
          _currentWords = result.recognizedWords;
        });
        final command = _currentWords.toLowerCase().trim();
        if (command.contains('close camera')) {
          _closeCamera();
        }
      },
    );
  }

  Future<void> _closeCamera() async {
    _pictureTimer?.cancel();
    _speakTimer?.cancel();
    await _tts.stop();
    await _speech.stop();

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _pictureTimer?.cancel();
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
                      bottom: 100, // Above the "Close" button
                      left: 20,
                      right: 20,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black54, // Semi-transparent black
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _currentWords.isEmpty ? "Listening..." : _currentWords,
                          style: const TextStyle(
                            color: Colors.white, 
                            fontSize: 20, 
                            fontWeight: FontWeight.bold
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