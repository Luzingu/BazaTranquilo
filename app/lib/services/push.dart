import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Notificações "push" (Firebase): chegam mesmo com o Bazá fechado. O servidor
/// só as envia a quem não tem o app ligado; com o app aberto, os avisos chegam
/// pela ligação em tempo real.
///
/// Só no Android por agora (o iPhone precisa de uma conta de programador Apple).
class Push {
  Push._();

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static Future<bool>? _ready;

  static Future<bool> _init() => _ready ??= () async {
    if (!_supported) return false;
    try {
      await Firebase.initializeApp();
      return true;
    } catch (e) {
      debugPrint('Push indisponível: $e');
      return false;
    }
  }();

  /// Identificador deste dispositivo para o servidor lhe enviar avisos, ou
  /// null se o push não estiver disponível.
  static Future<String?> token() async {
    if (!await _init()) return null;
    try {
      return await FirebaseMessaging.instance.getToken().timeout(
        const Duration(seconds: 15),
      );
    } catch (e) {
      debugPrint('Sem token de push: $e');
      return null;
    }
  }

  /// Avisa quando o Firebase troca o identificador do dispositivo.
  static Future<StreamSubscription<String>?> onTokenChange(
    void Function(String) handler,
  ) async {
    if (!await _init()) return null;
    return FirebaseMessaging.instance.onTokenRefresh.listen(
      handler,
      onError: (_) {},
    );
  }
}
