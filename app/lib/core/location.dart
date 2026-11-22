import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Porque é que a última tentativa de obter a posição falhou (null se correu
/// bem). Já vem escrito para mostrar ao utilizador, com o que ele deve fazer.
String? locationProblem;

const _serviceOff =
    'A localização do aparelho está desligada. Ligue-a nas definições e tente de novo.';
const _blocked = kIsWeb
    ? 'O navegador está a bloquear a localização deste site, por isso já não pergunta. '
          'Toque no ícone à esquerda do endereço › Permissões › Localização › Permitir, e actualize a página. '
          'Confirme também que a localização do aparelho está ligada para o navegador.'
    : 'O Bazá não tem permissão de localização. Abra Definições › Aplicações › Bazá › Permissões › Localização e escolha "Permitir".';
const _noFix =
    'Não foi possível obter a sua posição. Confirme que a localização do aparelho está ligada e tente de novo.';

/// Posição actual, ou null se não for possível obtê-la (ver [locationProblem]).
Future<LatLng?> currentLatLng() async {
  locationProblem = null;
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      locationProblem = _serviceOff;
      return null;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      locationProblem = _blocked;
      return null;
    }
    final p = await _position(LocationAccuracy.high, 12);
    return LatLng(p.latitude, p.longitude);
  } on PermissionDeniedException {
    locationProblem = _blocked;
    return null;
  } on LocationServiceDisabledException {
    locationProblem = _serviceOff;
    return null;
  } catch (_) {
    // Sem posição precisa a tempo (GPS fraco, computador sem GPS): aceita uma
    // posição aproximada e, no app nativo, a última conhecida.
    try {
      final p = await _position(LocationAccuracy.low, 15);
      return LatLng(p.latitude, p.longitude);
    } on PermissionDeniedException {
      locationProblem = _blocked;
      return null;
    } catch (_) {
      // continua abaixo
    }
    if (!kIsWeb) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return LatLng(last.latitude, last.longitude);
      } catch (_) {
        // sem última posição
      }
    }
    locationProblem = _noFix;
    return null;
  }
}

Future<Position> _position(LocationAccuracy accuracy, int seconds) =>
    Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: accuracy,
        timeLimit: Duration(seconds: seconds),
      ),
    );
