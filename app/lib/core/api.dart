import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'config.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class ApiClient {
  String? token;
  final _http = http.Client();

  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) =>
      _send('GET', path, query: query);
  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) => _send('POST', path, body: body ?? const {});
  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      _send('PATCH', path, body: body);

  Future<Map<String, dynamic>> put(String path) => _send('PUT', path);
  Future<Map<String, dynamic>> putJson(
    String path,
    Map<String, dynamic> body,
  ) => _send('PUT', path, body: body);
  Future<Map<String, dynamic>> delete(String path) => _send('DELETE', path);

  /// Envia um ficheiro (ex.: a foto de perfil) como corpo do pedido.
  Future<Map<String, dynamic>> putBytes(
    String path,
    List<int> bytes,
    String contentType,
  ) => _send('PUT', path, bytes: bytes, contentType: contentType);

  /// Descarrega um ficheiro protegido (ex.: a foto de um documento do motorista).
  Future<Uint8List> getBytes(String path) async {
    try {
      final response = await _http
          .get(
            Uri.parse('$apiBaseUrl$path'),
            headers: {if (token != null) 'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode >= 400)
        throw ApiException(
          response.statusCode,
          'Não foi possível carregar a imagem.',
        );
      return response.bodyBytes;
    } on SocketException {
      throw ApiException(0, 'Sem ligação ao servidor.');
    } on http.ClientException {
      throw ApiException(0, 'Sem ligação ao servidor.');
    } on TimeoutException {
      throw ApiException(0, 'O servidor demorou a responder.');
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    List<int>? bytes,
    String? contentType,
  }) async {
    final uri = Uri.parse('$apiBaseUrl$path').replace(queryParameters: query);
    final request = http.Request(method, uri);
    request.headers['Accept'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (bytes != null) {
      request.headers['Content-Type'] =
          contentType ?? 'application/octet-stream';
      request.bodyBytes = bytes;
    }
    try {
      final response = await http.Response.fromStream(
        await _http.send(request).timeout(const Duration(seconds: 20)),
      );
      final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
      final json = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
      if (response.statusCode >= 400) {
        throw ApiException(
          response.statusCode,
          json['error'] as String? ?? 'Erro ${response.statusCode}',
        );
      }
      return json;
    } on SocketException {
      throw ApiException(0, 'Sem ligação ao servidor.');
    } on http.ClientException {
      throw ApiException(0, 'Sem ligação ao servidor.');
    } on TimeoutException {
      throw ApiException(0, 'O servidor demorou a responder.');
    } on FormatException {
      throw ApiException(0, 'Resposta inesperada do servidor.');
    }
  }
}
