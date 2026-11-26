import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../services/notifier.dart';
import '../core/location.dart';
import '../core/models.dart';
import 'ride_state.dart';
import 'session.dart';

/// Estado do modo motorista: online/offline, posição e ofertas de corrida.
class DriverState extends ChangeNotifier {
  DriverState(this.session, this.rides) {
    // Quando o motorista passa a ter corrida, o toque pára.
    rides.addListener(_syncRinging);
    session.on('ride:offer', _onOffer);
    session.on('ride:offer_revoked', _onRevoked);
    session.on('ride:bid_declined', _onBidDeclined);
  }

  final Session session;
  final RideState rides;

  LatLng? position;
  List<Ride> offers = [];
  int ridesToday = 0;
  int earningsToday = 0;

  /// Comissões de corridas em dinheiro ainda por pagar ao Bazá, e as regras.
  int commissionDue = 0, commissionLimit = 0;
  bool commissionEnforced = false;
  double commissionRate = 0;

  /// Como pagar comissões e mensalidades (texto definido pela equipa).
  String payInfo = '';

  /// Nota da conta no ecrã principal (saldo, viagens grátis, mensalidade), já
  /// escrita pelo servidor: { text, detail, alert }. null = sem nota.
  Map<String, dynamic>? accountNote;
  bool accountNoteFromServer = false;
  bool busy = false;

  StreamSubscription<Position>? _positions;
  Timer? _heartbeat;
  bool _disposed = false;

  bool get online => session.user?.isOnline ?? false;

  Future<void> init() async {
    position = await currentLatLng();
    _notify();
    unawaited(loadSummary());
    if (online) {
      _startTracking();
      await _fetchOffers();
    }
  }

  Future<void> loadSummary() async {
    try {
      final res = await session.api.get('/driver/summary');
      ridesToday = (res['ridesToday'] as num).round();
      earningsToday = (res['earningsToday'] as num).round();
      accountNoteFromServer = res.containsKey('note');
      accountNote = res['note'] is Map
          ? Map<String, dynamic>.from(res['note'] as Map)
          : null;
      final c = res['commission'];
      if (c is Map) {
        commissionDue = (c['due'] as num? ?? 0).round();
        commissionLimit = (c['limit'] as num? ?? 0).round();
        commissionEnforced = c['enforced'] == true;
        commissionRate = (c['rate'] as num? ?? 0).toDouble();
        payInfo = c['payInfo'] as String? ?? '';
      }
      _notify();
    } on ApiException {
      // O resumo é apenas informativo.
    }
  }

  Future<void> setOnline(bool value) async {
    busy = true;
    _notify();
    try {
      if (value) {
        position = await currentLatLng() ?? position;
        if (position == null) {
          throw ApiException(
            0,
            locationProblem ?? 'Active a localização para ficar online.',
          );
        }
      }
      final res = await session.api.post('/driver/online', {
        'online': value,
        if (value)
          'location': {'lat': position!.latitude, 'lng': position!.longitude},
      });
      session.setUser(User.fromJson(res['user'] as Map<String, dynamic>));
      if (value) {
        _setOffers(res['offers'] as List? ?? const []);
        _startTracking();
        Notifier.instance.askPermission();
      } else {
        offers = [];
        _stopTracking();
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> accept(Ride offer) async {
    _answered.add(offer.id);
    _syncRinging();
    try {
      final res = await session.api.post('/rides/${offer.id}/accept');
      offers = [];
      rides.setRide(Ride.fromJson(res['ride'] as Map<String, dynamic>));
    } on ApiException {
      offers = offers.where((o) => o.id != offer.id).toList();
      rethrow;
    } finally {
      _notify();
    }
  }

  /// Mensagem a mostrar ao motorista (ex.: o passageiro recusou a proposta).
  String? notice;

  void clearNotice() {
    notice = null;
    _notify();
  }

  /// Propõe ao passageiro outro preço para esta corrida.
  Future<void> bid(Ride offer, int amount) async {
    _answered.add(offer.id);
    _syncRinging();
    final res = await session.api.post('/rides/${offer.id}/bids', {
      'amount': amount,
    });
    final updated = Ride.fromJson(res['ride'] as Map<String, dynamic>);
    offers = [for (final o in offers) o.id == updated.id ? updated : o];
    notice = null;
    _notify();
  }

  void _onBidDeclined(dynamic data) {
    if (data is! Map) return;
    notice = 'O passageiro recusou a sua proposta. Pode propor outro preço ou aceitar o dele.';
    HapticFeedback.mediumImpact();
    _fetchOffers();
    _notify();
  }

  Future<void> decline(Ride offer) async {
    offers = offers.where((o) => o.id != offer.id).toList();
    _notify();
    try {
      await session.api.post('/rides/${offer.id}/decline');
    } on ApiException {
      // Se falhar, a oferta volta a aparecer na próxima consulta.
    }
  }

  // ── Posição ───────────────────────────────────────────────────────────────
  void _startTracking() {
    _stopTracking();
    _positions =
        Geolocator.getPositionStream(locationSettings: _trackingSettings())
            .listen((p) {
              position = LatLng(p.latitude, p.longitude);
              _sendPosition(heading: p.heading);
              _notify();
            }, onError: (_) {});
    // Mantém a posição "fresca" no servidor mesmo parado e procura ofertas.
    _heartbeat = Timer.periodic(const Duration(seconds: 12), (_) {
      _sendPosition();
      if (rides.ride == null) {
        _fetchOffers();
        // Com uma proposta pendente, confirma se o passageiro já a aceitou.
        if (offers.any((o) => o.myBid != null)) rides.recheck();
      }
    });
    _sendPosition();
  }

  /// No Android, um serviço com notificação permanente mantém a posição a ser
  /// enviada com o Bazá em segundo plano (ex.: com o Google Maps aberto) ou com
  /// o ecrã bloqueado.
  LocationSettings _trackingSettings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Bazá · está online',
          notificationText:
              'A sua posição está a ser partilhada para receber corridas.',
          notificationChannelName: 'Motorista online',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    // No iPhone, o sistema mantém a posição em segundo plano (modo "location"
    // no Info.plist) e mostra o indicador azul enquanto o motorista está online.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );
  }

  void _stopTracking() {
    _positions?.cancel();
    _positions = null;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _sendPosition({double? heading}) {
    final p = position;
    if (p == null) return;
    final data = <String, dynamic>{'lat': p.latitude, 'lng': p.longitude};
    if (heading != null && heading.isFinite) data['heading'] = heading;
    if (session.socketConnected) {
      session.emit('driver:location', data);
    } else {
      session.api
          .post('/driver/location', data)
          .catchError((_) => <String, dynamic>{});
    }
  }

  // ── Ofertas ───────────────────────────────────────────────────────────────
  Future<void> _fetchOffers() async {
    try {
      final res = await session.api.get('/driver/offers');
      if (!online || rides.ride != null) return;
      _setOffers(res['offers'] as List? ?? const []);
      _notify();
    } on ApiException {
      // Tenta de novo no próximo ciclo.
    }
  }

  void _setOffers(List<dynamic> list) {
    offers = [
      for (final o in list) Ride.fromJson(Map<String, dynamic>.from(o as Map)),
    ];
  }

  // ── Aviso sonoro de nova corrida ──────────────────────────────────────────
  AudioPlayer? _player;
  Timer? _buzz;
  bool _ringing = false;

  /// Pedidos a que o motorista já respondeu (aceitou ou fez proposta): deixam
  /// de fazer tocar.
  final _answered = <String>{};

  /// O toque é contínuo enquanto houver um pedido à espera de resposta, e pára
  /// assim que o motorista aceita, recusa ou propõe um preço, ou o pedido é
  /// retirado. Chamado sempre que o estado muda.
  void _syncRinging() {
    _answered.retainAll({for (final o in offers) o.id});
    final waiting =
        !_disposed &&
        online &&
        rides.ride == null &&
        offers.any((o) => o.myBid == null && !_answered.contains(o.id));
    if (waiting == _ringing) return;
    _ringing = waiting;
    _buzz?.cancel();
    _buzz = null;
    if (!waiting) {
      _player?.stop().catchError((_) {});
      return;
    }
    HapticFeedback.heavyImpact();
    _buzz = Timer.periodic(
      const Duration(seconds: 2),
      (_) => HapticFeedback.heavyImpact(),
    );
    try {
      final player = _player ??= AudioPlayer();
      // Erros de reprodução (ex.: browser que ainda bloqueia som) não devem
      // impedir o pedido de aparecer.
      player
          .setReleaseMode(ReleaseMode.loop)
          .then((_) => player.play(AssetSource('sounds/offer.wav')))
          .catchError((_) {});
    } catch (_) {}
  }

  void _onOffer(dynamic data) {
    if (data is! Map || !online || rides.ride != null) return;
    final offer = Ride.fromJson(Map<String, dynamic>.from(data));
    if (offers.any((o) => o.id == offer.id)) return;
    offers = [...offers, offer];
    Notifier.instance.show(
      Notifier.offerId,
      'Nova corrida · ${kz(offer.fare)}',
      '${offer.pickup.address} → ${offer.dropoff.address}',
      urgent: true,
    );
    _notify();
  }

  void _onRevoked(dynamic data) {
    if (data is! Map) return;
    offers = offers.where((o) => o.id != data['rideId']).toList();
    _notify();
  }

  void _notify() {
    _syncRinging();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTracking();
    rides.removeListener(_syncRinging);
    _buzz?.cancel();
    _player?.dispose();
    session.off('ride:offer', _onOffer);
    session.off('ride:offer_revoked', _onRevoked);
    session.off('ride:bid_declined', _onBidDeclined);
    super.dispose();
  }
}
