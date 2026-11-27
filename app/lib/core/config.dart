import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'servidores.dart';

const _apiUrl = String.fromEnvironment('API_URL');

/// Liga a escolha de servidor (2026-11-27) quando a app foi compilada contra a produção. Chamar no `main()`.
void ligarEscolhaDeServidor() => Servidores.activa = _apiUrl == Servidores.principalProducao;

/// Endereço da API. Defina com `--dart-define=API_URL=http://192.168.x.x:4000`
/// para testar num telemóvel real.
String get apiBaseUrl {
  // Produção: o servidor escolhido (bazatranquilo.com ou, sem saldo de dados, angoschool.org/baza) — core/servidores.dart
  if (Servidores.activa) return Servidores.baseActiva;
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
    await Servidores.garantir(); // pergunta ao servidor escolhido (sem saldo: angoschool.org/baza — tem os mesmos mapas)
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
