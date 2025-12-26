import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/api_client.dart';

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

  // PVA-6 integration state
  late final ApiClient _api;
  bool _sending = false;
  String _backendText = "";

  @override
  void initState() {
    super.initState();

    // CHANGE THIS when testing on real phone:
    // emulator: http://10.0.2.2:8000
    // real phone: http://<YOUR_PC_IP>:8000
    _api = ApiClient(baseUrl: 'http://10.0.2.2:8000');

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

      // PVA-6: auto capture + send loop
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

    _pictureTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted || _controller == null || !_controller!.value.isInitialized) return;
      if (_controller!.value.isTakingPicture) return;
      if (_sending) return; // don’t spam backend

      try {
        final XFile file = await _controller!.takePicture();
        debugPrint("Auto-capture success: ${file.path}");
        await _sendToBackend(file);
      } catch (e) {
        debugPrint("Error capturing photo: $e");
      }
    });
  }

  Future<void> _sendToBackend(XFile image) async {
    setState(() {
      _sending = true;
      _backendText = "";
    });

    try {
      final prompt = _currentWords.trim();

      Map<String, dynamic> json;
      if (prompt.isNotEmpty) {
        json = await _api.custom(image, prompt);
      } else {
        json = await _api.obstacles(image);
      }

      final resultText = (json['result'] ?? '').toString();

      if (!mounted) return;
      setState(() {
        _backendText = resultText;
      });

      if (resultText.isNotEmpty) {
        await _tts.stop();
        await _tts.speak(resultText);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _backendText = 'Network error: $e';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _sending = false;
      });
    }
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
