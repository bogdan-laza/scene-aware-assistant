import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class SoundService {
  final AudioPlayer _player = AudioPlayer();

  Future<void> init() async {
    // Pre-load sounds to avoid delay on first playback
    await _player.setReleaseMode(ReleaseMode.stop);
  }

  Future<void> playMicOpen() async {
    try {
      await _player.stop();
      // Ensure you have this file in assets/sounds/mic_open.mp3
      await _player.play(AssetSource('sounds/mic_open.mp3'));
    } catch (e) {
      debugPrint("Error playing open sound: $e");
    }
  }

  Future<void> playMicClose() async {
    try {
      await _player.stop();
      // Ensure you have this file in assets/sounds/mic_close.mp3
      await _player.play(AssetSource('sounds/mic_close.mp3'));
    } catch (e) {
      debugPrint("Error playing close sound: $e");
    }
  }
}