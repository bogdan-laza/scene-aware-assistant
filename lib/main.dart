import 'package:flutter/material.dart';
import 'screens/voice_home_screen.dart';

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