import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? defaultBaseUrl,
        _client = client ?? http.Client();

  /// Override at build/run time with:
  /// `--dart-define=API_BASE_URL=http://10.0.2.2:8000`
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  final String baseUrl;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 30);

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Sends only an image to `/obstacles`.
  Future<Map<String, dynamic>> sendObstacles(XFile file) async {
    return _sendImageOnly('/obstacles', file);
  }

  /// Sends only an image to `/crosswalk`.
  Future<Map<String, dynamic>> sendCrosswalk(XFile file) async {
    return _sendImageOnly('/crosswalk', file);
  }

  /// Sends an image + prompt string to `/custom`.
  Future<Map<String, dynamic>> sendCustom(XFile file, String prompt) async {
    final request = http.MultipartRequest('POST', _uri('/custom'));
    request.files.add(await _imagePart(file));
    request.fields['prompt'] = prompt;

    final streamed = await _client.send(request).timeout(_timeout);
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      return _decodeJsonObject(body);
    }

    throw _exceptionFromBody(streamed.statusCode, body);
  }

  Future<Map<String, dynamic>> _sendImageOnly(String endpoint, XFile file) async {
    final request = http.MultipartRequest('POST', _uri(endpoint));
    request.files.add(await _imagePart(file));

    final streamed = await _client.send(request).timeout(_timeout);
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      return _decodeJsonObject(body);
    }

    throw _exceptionFromBody(streamed.statusCode, body);
  }

  Map<String, dynamic> _decodeJsonObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException('Response was not a JSON object');
    } catch (_) {
      throw ApiException('Invalid JSON response from server');
    }
  }

  ApiException _exceptionFromBody(int status, String body) {
    try {
      final decoded = jsonDecode(body);
      final detail = (decoded is Map && decoded['detail'] != null)
          ? decoded['detail'].toString()
          : null;
      return ApiException(detail ?? 'Server error ($status)', statusCode: status);
    } catch (_) {
      return ApiException('Server error ($status)', statusCode: status);
    }
  }

  Future<http.MultipartFile> _imagePart(XFile file) async {
    // package:http defaults to application/octet-stream; our backend validates
    // content-type, so we must set it correctly.
    final lower = file.path.toLowerCase();
    final MediaType contentType;
    if (lower.endsWith('.png')) {
      contentType = MediaType('image', 'png');
    } else {
      // Treat .jpg/.jpeg/.heic and unknown as jpeg for MVP.
      contentType = MediaType('image', 'jpeg');
    }

    return http.MultipartFile.fromPath(
      'file',
      file.path,
      contentType: contentType,
    );
  }

  // Backwards-compatible wrappers (internal use). Safe to remove later.
  Future<Map<String, dynamic>> obstacles(XFile image) => sendObstacles(image);
  Future<Map<String, dynamic>> crosswalk(XFile image) => sendCrosswalk(image);
  Future<Map<String, dynamic>> custom(XFile image, String prompt) =>
      sendCustom(image, prompt);
}
