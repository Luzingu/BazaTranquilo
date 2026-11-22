import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const _apiUrl = String.fromEnvironment('API_URL');

/// Endereço da API. Defina com `--dart-define=API_URL=http://192.168.x.x:4000`
/// para testar num telemóvel real.
String get apiBaseUrl {
  if (_apiUrl.isNotEmpty) return _apiUrl;
  // No emulador Android, 10.0.2.2 aponta para o computador anfitrião.
  if (!kIsWeb && Platform.isAndroid) return 'http://10.0.2.2:4000';
  return 'http://localhost:4000';
}

/// Endereço completo de um ficheiro servido pela API (ex.: foto de perfil).
String? fileUrl(String? path) => path == null ? null : '$apiBaseUrl$path';

/// Imagens do mapa: as do nosso servidor quando ele as tem (ver
/// [loadMapConfig]); caso contrário, as públicas do OpenStreetMap.
bool ownTiles = false;
String get tileUrlTemplate => ownTiles
    ? '$apiBaseUrl/map/tiles/{z}/{x}/{y}.png'
    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Pergunta ao servidor se tem mapas próprios. Sem resposta, fica o mapa público.
Future<void> loadMapConfig() async {
  try {
    final res = await http
        .get(Uri.parse('$apiBaseUrl/map/config'))
        .timeout(const Duration(seconds: 4));
    if (res.statusCode == 200)
      ownTiles = (jsonDecode(res.body) as Map)['ownTiles'] == true;
  } catch (_) {
    // mantém o valor actual
  }
}

/// Páginas legais, servidas pela API.
String get termsUrl => '$apiBaseUrl/termos';
String get privacyUrl => '$apiBaseUrl/privacidade';

/// Centro de Luanda, usado quando não há localização disponível.
const defaultCenter = LatLng(-8.8383, 13.2344);
