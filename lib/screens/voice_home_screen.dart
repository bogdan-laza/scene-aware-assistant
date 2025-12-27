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
  bool _suspendListening = false;

  @override
  void initState() {
    super.initState();
    _initAndListen();
  }

  Future<void> _initAndListen() async {
    await _requestPermissions();

    final available = await _speech.initialize(
      onStatus: (status) async {
        if (!mounted || _suspendListening) return;
        if (status == 'notListening' && mounted && !_listening) {
          await Future.delayed(const Duration(milliseconds: 300));
          if (!mounted || _suspendListening) return;
          _startListening();
        }
      },
      onError: (error) {
        if (!mounted || _suspendListening) return;
        debugPrint('Speech error: $error');
        setState(() => _listening = false);
        _startListening();
      },
    );

    if (available && mounted) _startListening();
  }

  Future<void> _startListening() async {
    if (_suspendListening) return;
    if (_listening) return;
    setState(() => _listening = true);

    await _speech.listen(
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
      ),
      onResult: (result) async {
        if (!mounted || _suspendListening) return;
        final recognized = result.recognizedWords.toLowerCase().trim();
        if (!mounted) return;

        setState(() => _lastHeard = recognized);

        if (recognized.contains('open camera')) {
          _suspendListening = true;
          try {
            // cancel() is more aggressive than stop(): it releases resources and
            // avoids "busy" loops when switching screens.
            await _speech.cancel();
          } catch (_) {
            try {
              await _speech.stop();
            } catch (_) {
              // ignore
            }
          }
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

    // IMPORTANT (blind-user friendly): ensure only one STT instance holds the mic.
    // If the camera is opened via tap, the home screen was previously still
    // listening in the background, which prevents camera voice commands from
    // working reliably.
    _suspendListening = true;
    try {
      await _speech.cancel();
    } catch (_) {
      try {
        await _speech.stop();
      } catch (_) {
        // ignore
      }
    }
    if (mounted) setState(() => _listening = false);

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CameraPreviewScreen()),
    );
    if (mounted) {
      _suspendListening = false;
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