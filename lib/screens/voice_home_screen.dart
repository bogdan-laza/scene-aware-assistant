import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'camera_screen.dart';

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
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
      ),
      onResult: (result) async {
        final recognized = result.recognizedWords.toLowerCase().trim();
        if (!mounted) return;

        setState(() => _lastHeard = recognized);

        if (recognized.contains('open camera')) {
          await _speech.stop();
          setState(() => _listening = false);
          _navigateToCamera();
        }
      },
      listenFor: const Duration(minutes: 10),
      pauseFor: const Duration(seconds: 60),
    );
  }

  Future<void> _navigateToCamera() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CameraPreviewScreen()),
    );
    if (mounted) {
      setState(() => _listening = false);
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
              size: 120,
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