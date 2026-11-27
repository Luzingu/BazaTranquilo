import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'servidores.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message, [this.data = const {}]);
  final int status;
  final String message;

  /// A resposta inteira do servidor (ex.: `otherRole` quando o número é de outro tipo de conta).
  final Map<String, dynamic> data;
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
  Future<Uint8List> getBytes(String path) => _comOutroServidor('GET', () => _getBytes(path));

  Future<Uint8List> _getBytes(String path) async {
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
      throw _SemLigacao(antesDeSair: true);
    } on http.ClientException {
      throw _SemLigacao();
    } on TimeoutException {
      throw _SemLigacao(demorou: true);
    }
  }

  /// Escolha de servidor (2026-11-27, `core/servidores.dart`): espera pela escolha e, SEM LIGAÇÃO (ou 502/503/504),
  /// repete UMA vez no outro servidor (bazatranquilo.com ↔ angoschool.org/baza). Leituras sempre; escritas só se a
  /// ligação falhou ANTES de o pedido sair — senão podia gravar duas vezes (uma corrida pedida em dobro).
  Future<T> _comOutroServidor<T>(String method, Future<T> Function() pedido) async {
    if (Servidores.activa) await Servidores.garantir();
    final usado = Servidores.activo.value;
    try {
      return await pedido();
    } on _SemLigacao catch (e) {
      if (Servidores.activa && (method == 'GET' || e.antesDeSair)) {
        final alt = await Servidores.pedirAlternativa(usado);
        if (alt != null && alt.id != usado.id) {
          try {
            return await pedido();
          } on _SemLigacao catch (e2) {
            throw e2.excepcao;
          }
        }
      }
      throw e.excepcao;
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    List<int>? bytes,
    String? contentType,
  }) => _comOutroServidor(method, () => _sendUma(method, path, query: query, body: body, bytes: bytes, contentType: contentType));

  Future<Map<String, dynamic>> _sendUma(
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
      if (response.statusCode == 502 || response.statusCode == 503 || response.statusCode == 504) {
        throw _SemLigacao(estado: response.statusCode); // o proxy não chegou à API: conta como sem ligação
      }
      if (response.statusCode >= 400) {
        throw ApiException(
          response.statusCode,
          json['error'] as String? ?? 'Erro ${response.statusCode}',
          json,
        );
      }
      return json;
    } on SocketException {
      throw _SemLigacao(antesDeSair: true);
    } on http.ClientException {
      throw _SemLigacao();
    } on TimeoutException {
      throw _SemLigacao(demorou: true);
    } on FormatException {
      throw ApiException(0, 'Resposta inesperada do servidor.');
    }
  }
}

/// Falha de LIGAÇÃO (não uma resposta do servidor): pode repetir-se no outro servidor. [antesDeSair]: a ligação nem
/// se fez (`SocketException`), por isso o pedido não chegou a sair e até uma escrita se pode repetir.
class _SemLigacao implements Exception {
  _SemLigacao({this.antesDeSair = false, this.demorou = false, this.estado});
  final bool antesDeSair, demorou;
  final int? estado;

  ApiException get excepcao => estado != null
      ? ApiException(estado!, 'O servidor não está disponível. Tente de novo.')
      : demorou
      ? ApiException(0, 'O servidor demorou a responder.')
      : ApiException(0, 'Sem ligação ao servidor.');
}
