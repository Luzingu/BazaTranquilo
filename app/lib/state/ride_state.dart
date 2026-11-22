import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../services/notifier.dart';
import '../services/voice.dart';
import 'session.dart';

/// A corrida em curso do utilizador (como passageiro ou motorista).
/// Depois de terminar, a corrida fica aqui até o ecrã chamar [clear].
class RideState extends ChangeNotifier {
  RideState(this.session) {
    session.on('ride:update', _onUpdate);
    session.on('driver:location', _onDriverLocation);
    session.on('chat:message', _onChatMessage);
    // Rede de segurança caso o socket perca algum evento.
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
    // Tempo de chegada e percurso que falta, actualizados durante a corrida.
    _etaTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => refreshEta(),
    );
  }

  final Session session;
  Ride? ride;
  AppMode? role;
  LatLng? driverLocation;

  /// Tempo e distância que faltam ao motorista: até ao ponto de recolha
  /// enquanto vai a caminho, e até ao destino durante a viagem.
  int? etaSeconds, etaMeters;

  /// Percurso que falta, do carro até ao próximo ponto.
  List<LatLng> liveRoute = const [];
  Timer? _etaTimer;
  String? _etaFor; // "<corrida>:<estado>" a que o tempo se refere

  static const _onTrip = ['accepted', 'arrived', 'in_progress'];

  Future<void> refreshEta() async {
    final current = ride;
    if (current == null || !_onTrip.contains(current.status)) return;
    final key = '${current.id}:${current.status}';
    try {
      final res = await session.api.get('/rides/${current.id}/eta');
      if (_disposed || ride?.id != current.id || ride?.status != current.status)
        return;
      _etaFor = key;
      etaSeconds = (res['durationS'] as num).round();
      etaMeters = (res['distanceM'] as num).round();
      liveRoute = decodePolyline(res['geometry'] as String?);
      // Se o aviso em tempo real falhou, a posição vem daqui.
      final loc = res['driverLocation'] as Map<String, dynamic>?;
      if (loc != null && role == AppMode.passenger) {
        driverLocation = LatLng(
          (loc['lat'] as num).toDouble(),
          (loc['lng'] as num).toDouble(),
        );
      }
      _notify();
    } on ApiException {
      // Sem rede ou sem posição ainda: tenta de novo no próximo ciclo.
    }
  }

  bool loaded = false;
  Timer? _poll;
  bool _disposed = false;

  bool get isPassengerRide => ride != null && role == AppMode.passenger;
  bool get isDriverRide => ride != null && role == AppMode.driver;

  Future<void> load() async {
    try {
      final res = await session.api.get('/rides/active');
      if (res['ride'] != null) {
        _set(Ride.fromJson(res['ride'] as Map<String, dynamic>));
      }
    } on ApiException {
      // Tenta de novo no próximo ciclo.
    } finally {
      loaded = true;
      _notify();
    }
  }

  /// Volta a perguntar ao servidor se há corrida em curso (rede de segurança
  /// para quando o aviso em tempo real se perde).
  Future<void> recheck() async {
    if (ride == null) await load();
  }

  void setRide(Ride r) {
    _set(r);
    _notify();
  }

  // ── Chat da corrida ───────────────────────────────────────────────────────
  final _chat = StreamController<Map<String, dynamic>>.broadcast();

  /// Mensagens que chegam em tempo real, para o ecrã do chat.
  Stream<Map<String, dynamic>> get chatMessages => _chat.stream;

  /// Mensagens por ler (mostradas no botão "Mensagem").
  int unreadMessages = 0;

  /// O ecrã do chat está aberto: as mensagens novas contam como lidas.
  bool chatOpen = false;

  void markChatRead() {
    if (unreadMessages == 0) return;
    unreadMessages = 0;
    _notify();
  }

  void _onChatMessage(dynamic data) {
    if (data is! Map || data['rideId'] != ride?.id || data['message'] is! Map)
      return;
    _chat.add(Map<String, dynamic>.from(data['message'] as Map));
    if (!chatOpen) {
      unreadMessages++;
      HapticFeedback.mediumImpact();
      final text = (data['message'] as Map)['text'];
      if (text is String)
        Notifier.instance.show(Notifier.chatId, 'Nova mensagem', text);
      _notify();
    }
  }

  void clear() {
    unreadMessages = 0;
    ride = null;
    role = null;
    driverLocation = null;
    etaSeconds = null;
    etaMeters = null;
    liveRoute = const [];
    _etaFor = null;
    _notify();
  }

  void _set(Ride r) {
    // À espera de motorista: pede (uma vez) a permissão para avisar na barra de notificações.
    if (ride == null && r.status == 'searching')
      Notifier.instance.askPermission();
    // Outro estado (ou outra corrida): o tempo e o percurso anteriores já não servem.
    if (_etaFor != '${r.id}:${r.status}') {
      etaSeconds = null;
      etaMeters = null;
      liveRoute = const [];
      _etaFor = null;
      if (_onTrip.contains(r.status)) Future.microtask(refreshEta);
    }
    if (ride?.id != r.id) unreadMessages = 0;
    ride = r;
    role = r.passenger?.id == session.user?.id
        ? AppMode.passenger
        : AppMode.driver;
    if (r.driverLocation != null) driverLocation = r.driverLocation;
    if (!r.isActive) driverLocation = null;
  }

  void _onUpdate(dynamic data) {
    if (data is! Map) return;
    final r = Ride.fromJson(Map<String, dynamic>.from(data));
    // Sem corrida em curso, só interessa uma coisa: o passageiro aceitou a
    // proposta de preço deste motorista e a corrida passou a ser dele.
    final assignedToMe =
        ride == null &&
        r.status == 'accepted' &&
        r.driver?.id == session.user?.id;
    if (ride?.id != r.id && !assignedToMe) return;
    _announce(ride?.status, r, assignedToMe);
    _set(r);
    _notify();
  }

  /// Quando a corrida muda de estado: aviso falado ao passageiro (toque e
  /// frase gravada) e aviso na barra de notificações se o app não estiver no
  /// ecrã.
  void _announce(String? before, Ride r, bool assignedToMe) {
    if (before == r.status && !assignedToMe) return;
    final isDriver = session.user?.isDriver ?? false;
    String? title, body;
    if (isDriver) {
      if (assignedToMe) {
        title = 'A corrida é sua';
        body =
            'O passageiro aceitou o seu preço. Recolha em ${r.pickup.address}.';
      } else if (r.status == 'cancelled') {
        title = 'Corrida cancelada';
        body = 'O passageiro cancelou a corrida.';
      }
    } else {
      switch (r.status) {
        case 'accepted':
          title = 'Motorista a caminho';
          body = '${r.driver?.name ?? 'O motorista'} aceitou a sua corrida.';
          Voice.instance.say(Voice.accepted);
        case 'arrived':
          title = 'O motorista chegou';
          body = 'Está à sua espera em ${r.pickup.address}.';
          Voice.instance.say(Voice.arrived);
        case 'in_progress':
          title = 'Viagem iniciada';
          body = 'Destino: ${r.dropoff.address}.';
          Voice.instance.say(Voice.started);
        case 'completed':
          title = 'Chegou ao destino';
          body = 'Total: ${kz(r.fare)}. Obrigado por viajar com o Bazá.';
          Voice.instance.say(Voice.finished);
        case 'cancelled':
          title = 'Corrida cancelada';
          body = 'A sua corrida foi cancelada.';
      }
    }
    if (title != null)
      Notifier.instance.show(
        Notifier.rideId,
        title,
        body ?? '',
        urgent: r.status == 'arrived',
      );
  }

  void _onDriverLocation(dynamic data) {
    if (data is! Map ||
        data['rideId'] != ride?.id ||
        !(ride?.isActive ?? false))
      return;
    driverLocation = LatLng(
      (data['lat'] as num).toDouble(),
      (data['lng'] as num).toDouble(),
    );
    _notify();
  }

  Future<void> _refresh() async {
    final current = ride;
    if (current == null) {
      if (!loaded) await load();
      return;
    }
    if (!current.isActive) return;
    try {
      final res = await session.api.get('/rides/${current.id}');
      if (ride?.id != current.id) return;
      final fresh = Ride.fromJson(res['ride'] as Map<String, dynamic>);
      final changed =
          fresh.status != current.status ||
          fresh.exclusive != current.exclusive ||
          fresh.fare != current.fare ||
          fresh.bids.length != current.bids.length ||
          fresh.driverLocation != driverLocation;
      _set(fresh);
      if (changed) _notify();
    } on ApiException {
      // Ignora falhas temporárias de rede.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _etaTimer?.cancel();
    session.off('ride:update', _onUpdate);
    session.off('driver:location', _onDriverLocation);
    session.off('chat:message', _onChatMessage);
    _chat.close();
    super.dispose();
  }
}
