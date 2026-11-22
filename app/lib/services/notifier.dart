import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Avisos na barra de notificações do telemóvel quando o Bazá não está no ecrã
/// (motorista com outra aplicação aberta ou com o ecrã bloqueado).
///
/// São notificações locais: funcionam enquanto o app está vivo em segundo
/// plano — o que acontece com o motorista online, por causa do serviço de
/// localização. Com o app totalmente fechado é preciso notificações "push".
class Notifier with WidgetsBindingObserver {
  Notifier._();
  static final instance = Notifier._();

  static const offerId = 1, callId = 2, chatId = 3, rideId = 4;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _foreground = true;

  /// Chamado quando o app passa para segundo plano ou volta ao ecrã.
  void Function(bool foreground)? onForegroundChanged;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> init() async {
    if (!_supported || _ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      // Os canais têm de existir antes de chegar um aviso push com o app fechado.
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          'baza_urgente',
          'Corridas e chamadas',
          description: 'Novos pedidos de corrida e chamadas recebidas',
          importance: Importance.max,
        ),
      );
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          'baza_avisos',
          'Avisos',
          description: 'Mensagens e estado da corrida',
          importance: Importance.high,
        ),
      );
      // Avisos falados: cada gravação tem o seu canal, porque no Android o som
      // pertence ao canal. O servidor escolhe o canal ao enviar o aviso push,
      // e assim a voz toca mesmo com o app fechado.
      const voices = {
        // Alerta de perigo para os agentes dos postos policiais (sirene).
        'alerta_perigo': 'Alertas de perigo',
        'voz_aceite': 'Motorista a caminho',
        'voz_chegou': 'O motorista chegou',
        'voz_inicio': 'Início da viagem',
        'voz_fim': 'Fim da viagem',
      };
      for (final v in voices.entries) {
        await android?.createNotificationChannel(
          AndroidNotificationChannel(
            'baza_${v.key}',
            v.value,
            description: 'Aviso falado durante a corrida',
            importance: Importance.max,
            sound: RawResourceAndroidNotificationSound(v.key),
            audioAttributesUsage: AudioAttributesUsage.notification,
          ),
        );
      }
      WidgetsBinding.instance.addObserver(this);
      _ready = true;
    } catch (e) {
      debugPrint('Notificações indisponíveis: $e');
    }
  }

  /// Pede a permissão de notificações (Android 13+). Chamado quando faz
  /// sentido para o utilizador: ao ficar online ou ao pedir uma corrida.
  Future<void> askPermission() async {
    if (!_ready) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Sem permissão, o app continua a funcionar sem avisos.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground != _foreground) onForegroundChanged?.call(foreground);
    _foreground = foreground;
    // De volta ao app: os avisos já cumpriram a função.
    if (_foreground) clearAll();
  }

  /// Mostra o aviso, mas só se o app não estiver no ecrã.
  Future<void> show(
    int id,
    String title,
    String body, {
    bool urgent = false,
  }) async {
    if (!_ready || _foreground) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            urgent ? 'baza_urgente' : 'baza_avisos',
            urgent ? 'Corridas e chamadas' : 'Avisos',
            channelDescription: urgent
                ? 'Novos pedidos de corrida e chamadas recebidas'
                : 'Mensagens e estado da corrida',
            importance: urgent ? Importance.max : Importance.high,
            priority: urgent ? Priority.max : Priority.high,
            category: urgent
                ? AndroidNotificationCategory.call
                : AndroidNotificationCategory.message,
            visibility: NotificationVisibility.public,
            autoCancel: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Falha ao mostrar a notificação: $e');
    }
  }

  Future<void> cancel(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: id);
    } catch (_) {}
  }

  Future<void> clearAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }
}
