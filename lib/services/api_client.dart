import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;

class ApiClient {
  ApiClient({required this.baseUrl});

  final String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> obstacles(XFile image) async {
    return _sendImageOnly('/obstacles', image);
  }

  Future<Map<String, dynamic>> crosswalk(XFile image) async {
    return _sendImageOnly('/crosswalk', image);
  }

  Future<Map<String, dynamic>> custom(XFile image, String prompt) async {
    final request = http.MultipartRequest('POST', _uri('/custom'));
    request.files.add(await http.MultipartFile.fromPath('file', image.path));
    request.fields['prompt'] = prompt;

    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      return jsonDecode(body) as Map<String, dynamic>;
    }

    return _errorFromBody(streamed.statusCode, body);
  }

  Future<Map<String, dynamic>> _sendImageOnly(String endpoint, XFile image) async {
    final request = http.MultipartRequest('POST', _uri(endpoint));
    request.files.add(await http.MultipartFile.fromPath('file', image.path));

    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      return jsonDecode(body) as Map<String, dynamic>;
    }

    return _errorFromBody(streamed.statusCode, body);
  }

  Map<String, dynamic> _errorFromBody(int status, String body) {
    try {
      final json = jsonDecode(body);
      return {
        "type": "error",
        "result": json["detail"]?.toString() ?? "Server error ($status)"
      };
    } catch (_) {
      return {"type": "error", "result": "Server error ($status)"};
    }
  }
}
