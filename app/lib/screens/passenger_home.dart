import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/location.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/ride_state.dart';
import '../state/session.dart';
import '../widgets/baza_map.dart';
import '../widgets/common.dart';
import '../widgets/contact.dart';
import '../widgets/safety.dart';
import '../widgets/vehicle_picker.dart';
import 'favorites_screen.dart';
import 'intercity_screen.dart';
import 'negotiated_request_screen.dart';
import 'place_search.dart';

class PassengerHome extends StatefulWidget {
  const PassengerHome({super.key});

  @override
  State<PassengerHome> createState() => _PassengerHomeState();
}

class _PassengerHomeState extends State<PassengerHome> {
  LatLng? _me;
  bool _locating = true;
  Place? _pickup;
  Place? _dropoff;
  Estimate? _estimate;
  bool _estimating = false;
  String? _estimateError;
  String _category = 'economy';
  String _group = 'ride'; // 'ride' (viagem) ou 'cargo' (carga e entregas)
  int _helpers = 0;
  final List<Place> _stops = []; // paragens intermédias
  int? _offer; // preço proposto pelo passageiro (null = preço da tarifa)
  final _cargoNote = TextEditingController();
  String _payment = 'cash';
  int _stars = 0;
  String? _ratedRideId;
  FavoriteDriver? _preferred; // motorista preferido a chamar primeiro

  @override
  void initState() {
    super.initState();
    _locate();
  }

  @override
  void dispose() {
    _cargoNote.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    final here = await currentLatLng();
    if (!mounted) return;
    setState(() {
      _me = here;
      _locating = false;
    });
    if (here == null || _pickup != null) return;
    try {
      final res = await context.read<Session>().api.get('/places/reverse', {
        'lat': '${here.latitude}',
        'lng': '${here.longitude}',
      });
      if (!mounted || _pickup != null) return;
      setState(
        () => _pickup = Place.fromJson(res['place'] as Map<String, dynamic>),
      );
    } on ApiException {
      if (!mounted || _pickup != null) return;
      setState(
        () => _pickup = Place(
          address: 'A minha localização',
          lat: here.latitude,
          lng: here.longitude,
        ),
      );
    }
  }

  Future<void> _choose({required bool pickup}) async {
    final place = await Navigator.of(context).push<Place>(
      MaterialPageRoute(
        builder: (_) => PlaceSearchScreen(
          title: pickup ? 'Ponto de recolha' : 'Para onde?',
          near: _me,
          offerCurrentLocation: pickup,
        ),
      ),
    );
    if (place == null || !mounted) return;
    setState(() {
      if (pickup) {
        _pickup = place;
      } else {
        _dropoff = place;
      }
    });
    if (_pickup == null) {
      // Sem localização: o passageiro tem de indicar onde está.
      return _choose(pickup: true);
    }
    if (_dropoff != null) await _loadEstimate();
  }

  Future<void> _addStop() async {
    final place = await Navigator.of(context).push<Place>(
      MaterialPageRoute(
        builder: (_) =>
            PlaceSearchScreen(title: 'Adicionar paragem', near: _me),
      ),
    );
    if (place == null || !mounted) return;
    setState(() {
      _stops.add(place);
      _offer = null; // o preço muda com o percurso
    });
    await _loadEstimate();
  }

  Future<void> _removeStop(int index) async {
    setState(() {
      _stops.removeAt(index);
      _offer = null;
    });
    await _loadEstimate();
  }

  Future<void> _loadEstimate() async {
    final pickup = _pickup, dropoff = _dropoff;
    if (pickup == null || dropoff == null) return;
    setState(() {
      _estimating = true;
      _estimateError = null;
      _estimate = null;
    });
    try {
      final res = await context.read<Session>().api.post('/rides/estimate', {
        'pickup': {'lat': pickup.lat, 'lng': pickup.lng},
        'dropoff': {'lat': dropoff.lat, 'lng': dropoff.lng},
        if (_stops.isNotEmpty)
          'stops': [
            for (final s in _stops) {'lat': s.lat, 'lng': s.lng},
          ],
      });
      if (!mounted || _pickup != pickup || _dropoff != dropoff) return;
      final estimate = Estimate.fromJson(res);
      setState(() {
        _estimate = estimate;
        if (!estimate.paymentMethods.contains(_payment)) _payment = 'cash';
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _estimateError = e.message);
    } finally {
      if (mounted) setState(() => _estimating = false);
    }
  }

  /// O serviço escolhido, com o preço para este percurso.
  FareOption? get _selected =>
      _estimate?.options.where((o) => o.category == _category).firstOrNull;

  /// Ajudantes só contam em serviços de carga que os permitem.
  int get _activeHelpers => (_selected?.helpers ?? false) ? _helpers : 0;

  /// Preço da tarifa para o serviço escolhido, com ajudantes.
  int get _suggestedTotal =>
      (_selected?.fare ?? 0) + _activeHelpers * (_estimate?.helperFee ?? 0);

  /// Preço que vai ser pedido: o proposto pelo passageiro ou o da tarifa.
  int get _price {
    final estimate = _estimate;
    final offer = _offer;
    if (estimate == null || offer == null) return _suggestedTotal;
    return offer.clamp(
      estimate.minFare(_suggestedTotal),
      estimate.maxFare(_suggestedTotal),
    );
  }

  void _selectCategory(String category, {String? group}) => setState(() {
    _category = category;
    _offer = null; // outro serviço, outro preço
    if (group != null) _group = group;
    // Outra categoria deixa de corresponder à viatura do preferido.
    if (_preferred?.driver.vehicle?.category != category) _preferred = null;
  });

  Future<void> _request() async {
    if (_selected?.negotiated ?? false) {
      throw 'Este tipo de viatura tem preço a combinar: use a opção "preço a combinar", mais abaixo.';
    }
    final isCargo = _selected?.group == 'cargo';
    final note = _cargoNote.text.trim();
    if (isCargo && note.length < 3) throw 'Descreva o que vai transportar.';
    final res = await context.read<Session>().api.post('/rides', {
      'pickup': _pickup!.toJson(),
      'dropoff': _dropoff!.toJson(),
      if (_stops.isNotEmpty) 'stops': [for (final s in _stops) s.toJson()],
      'category': _category,
      'paymentMethod': _payment,
      if (_preferred != null) 'preferredDriverId': _preferred!.driver.id,
      if (isCargo) 'cargoNote': note,
      if (isCargo) 'helpers': _activeHelpers,
      if (_offer != null) 'offeredFare': _price,
    });
    if (!mounted) return;
    context.read<RideState>().setRide(
      Ride.fromJson(res['ride'] as Map<String, dynamic>),
    );
  }

  /// Cancelar: primeiro «Tem a certeza?» (Cancelar / Aguardar) e depois
  /// «O que aconteceu?», com os motivos; o motivo é opcional.
  Future<void> _cancel(Ride ride) async {
    final sure = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (context) => _ConfirmCancelSheet(
        text: ride.driver == null
            ? 'Já estamos à procura de carro, não demoramos muito. Se cancelar agora, pode demorar mais a encontrar outro.'
            : 'Já há um motorista a caminho. Cancelar mais de 2 minutos depois de ele aceitar, ou com ele já no local, conta como cancelamento tardio: 3 em 24 horas suspendem a conta por algum tempo.',
      ),
    );
    if (sure != true || !mounted) return;
    final why = await showModalBottomSheet<({String? reason, String comment})>(
      context: context,
      isDismissible: false,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (context) => _CancelReasonSheet(withDriver: ride.driver != null),
    );
    if (why == null || !mounted) return;
    final rides = context.read<RideState>();
    final res = await context.read<Session>().api.post(
      '/rides/${ride.id}/cancel',
      {
        if (why.reason != null) 'reason': why.reason,
        if (why.comment.trim().isNotEmpty) 'comment': why.comment.trim(),
      },
    );
    rides.setRide(Ride.fromJson(res['ride'] as Map<String, dynamic>));
  }

  /// Fecha a corrida terminada (enviando a avaliação, se houver).
  Future<void> _finish(Ride ride, {bool keepDestination = false}) async {
    final session = context.read<Session>();
    final rides = context.read<RideState>();
    if (ride.status == 'completed' && _stars > 0 && _ratedRideId != ride.id) {
      await session.api.post('/rides/${ride.id}/rate', {'stars': _stars});
      _ratedRideId = ride.id;
    }
    rides.clear();
    if (!mounted) return;
    setState(() {
      _stars = 0;
      if (!keepDestination) {
        _dropoff = null;
        _stops.clear();
        _estimate = null;
        _preferred = null;
        _helpers = 0;
        _offer = null;
        _cargoNote.clear();
      }
    });
    session.refreshUser().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final rides = context.watch<RideState>();
    final ride = rides.isPassengerRide ? rides.ride : null;

    final pickup = ride?.pickup ?? _pickup;
    final dropoff = ride?.dropoff ?? _dropoff;
    final geometry = ride?.routeGeometry ?? _estimate?.geometry;
    final showRoute = ride == null || ride.isActive;

    final waitingDriver =
        rides.isPassengerRide &&
        (ride?.status == 'accepted' || ride?.status == 'arrived') &&
        rides.liveRoute.isNotEmpty;

    return Stack(
      children: [
        BazaMap(
          me: _me,
          labels: true,
          pickup: dropoff == null && ride == null ? null : pickup?.latLng,
          dropoff: (ride?.noDestination ?? false) ? null : dropoff?.latLng,
          stops: [for (final s in ride?.stops ?? _stops) s.latLng],
          driver: rides.isPassengerRide ? rides.driverLocation : null,
          driverVehicle: ride?.driver?.vehicle,
          // Durante a corrida mostra o percurso que falta, a partir do carro.
          route: !showRoute
              ? const []
              : (rides.isPassengerRide && rides.liveRoute.isNotEmpty
                    ? rides.liveRoute
                    : decodePolyline(geometry)),
          // Enquanto o motorista vem a caminho, a viagem aparece mais clara.
          tripRoute: waitingDriver ? decodePolyline(geometry) : const [],
          followTarget: !rides.isPassengerRide || !(ride?.isActive ?? false)
              ? null
              : (waitingDriver || ride!.noDestination
                    ? ride!.pickup.latLng
                    : ride.dropoff.latLng),
          follow: rides.isPassengerRide && (ride?.isActive ?? false)
              ? rides.driverLocation
              : null,
          bottomPadding: 300,
          pickupLabel: ride == null && _selected?.etaS != null
              ? '${(_selected!.etaS! / 60).ceil()} min'
              : null,
          dropoffLabel: ride == null && _estimate != null
              ? 'chegada às ${arrivalClock(_estimate!.durationS, waitS: _selected?.etaS)}'
              : null,
          fitKey: ride != null
              ? '${ride.id}:${ride.status}'
              : '${pickup?.lat},${pickup?.lng}:${dropoff?.lat},${dropoff?.lng}:${_stops.length}:${_estimate != null}',
        ),
        if (ride != null)
          _ridePanel(ride)
        else if (_dropoff == null)
          _wherePanel()
        else
          // Seta para voltar por cima do painel, sobre o mapa.
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 14, bottom: 12),
                  child: _RoundMapButton(
                    icon: Icons.arrow_back,
                    tooltip: 'Voltar',
                    onTap: _clearDestination,
                  ),
                ),
                _estimatePanel(),
              ],
            ),
          ),
      ],
    );
  }

  // ── Sem corrida: escolher destino ─────────────────────────────────────────
  /// Serviços de preço combinado (triciclo, XL, carrinha, camião): pedido próprio.
  Future<void> _requestNegotiated() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => NegotiatedRequestScreen(
        near: _me,
        pickup: _pickup,
        dropoff: _dropoff,
      ),
    ),
  );

  Widget _wherePanel() {
    final name = context.read<Session>().user!.name.split(' ').first;
    return BottomPanel(
      children: [
        PanelTitle('Olá, $name', subtitle: 'Para onde vamos hoje?'),
        _AddressTile(
          icon: Icons.trip_origin,
          color: BazaColors.green,
          text:
              _pickup?.address ??
              (_locating
                  ? 'A obter a sua localização…'
                  : 'Escolher ponto de recolha'),
          onTap: () => _choose(pickup: true),
        ),
        const SizedBox(height: 10),
        _AddressTile(
          icon: Icons.search,
          color: BazaColors.ink,
          text: 'Para onde?',
          emphasised: true,
          onTap: () => _choose(pickup: false),
        ),
        const SizedBox(height: 10),
        _AddressTile(
          icon: Icons.local_shipping_outlined,
          color: BazaColors.ink,
          text: 'Triciclo, XL, carrinha ou camião',
          subtitle: 'Preço a combinar com o motorista',
          dense: true,
          trailing: const Icon(Icons.chevron_right, color: BazaColors.muted),
          onTap: _requestNegotiated,
        ),
        const SizedBox(height: 10),
        _AddressTile(
          icon: Icons.airport_shuttle_outlined,
          color: BazaColors.ink,
          text: 'Viagens entre municípios',
          subtitle: 'Reserve o seu lugar, com preço por passageiro',
          dense: true,
          trailing: const Icon(Icons.chevron_right, color: BazaColors.muted),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const IntercityScreen())),
        ),
        if (!_locating && _me == null)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Não foi possível obter a localização. Active-a nas definições ou escolha o ponto de recolha.',
              style: TextStyle(color: BazaColors.muted, fontSize: 13),
            ),
          ),
      ],
    );
  }

  // ── Destino escolhido: preço e pedido ─────────────────────────────────────
  void _clearDestination() => setState(() {
    _dropoff = null;
    _stops.clear();
    _estimate = null;
    _preferred = null;
    _offer = null;
    _estimateError = null;
  });

  Widget _estimatePanel() {
    final estimate = _estimate;
    final ready = estimate != null && !_estimating;
    final options = ready
        ? estimate.options
              .where((o) => o.group == _group && !o.negotiated)
              .toList()
        : const <FareOption>[];
    final hasCargo =
        ready && estimate.options.any((o) => o.group == 'cargo' && !o.negotiated);
    return BottomPanel(
      footer: ready && _selected != null ? _requestBar(estimate) : null,
      children: [
        _RouteBox(
          pickup: _pickup?.address ?? 'Escolher ponto de recolha',
          dropoff: _dropoff!.address,
          durationS: ready ? estimate.durationS : null,
          stops: [for (final s in _stops) s.address],
          canAddStop: _stops.length < (_estimate?.maxStops ?? 3),
          onPickup: () => _choose(pickup: true),
          onDropoff: () => _choose(pickup: false),
          onAddStop: _addStop,
          onRemoveStop: _removeStop,
        ),
        const SizedBox(height: 12),
        if (_estimating)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: CircularProgressIndicator(color: BazaColors.ink),
            ),
          )
        else if (estimate == null) ...[
          Text(
            _estimateError ?? 'Não foi possível calcular o preço.',
            style: const TextStyle(color: BazaColors.red),
          ),
          const SizedBox(height: 12),
          AsyncButton(
            label: 'Tentar novamente',
            outlined: true,
            onPressed: _loadEstimate,
          ),
        ] else ...[
          if (estimate.hasSurge) ...[
            _SurgeNotice(
              label: estimate.surgeLabel ?? 'Procura alta',
              multiplier: estimate.surgeMultiplier,
            ),
            const SizedBox(height: 10),
          ],
          if (hasCargo) ...[
            _GroupTabs(
              value: _group,
              onChanged: (g) {
                final first = estimate.options
                    .where((o) => o.group == g && !o.negotiated)
                    .firstOrNull;
                if (first != null) _selectCategory(first.category, group: g);
              },
            ),
            const SizedBox(height: 8),
          ],
          VehicleCarousel(
            options: options,
            selected: _category,
            onSelect: _selectCategory,
            // Os serviços de preço combinado pedem-se à parte.
            onNegotiated: _requestNegotiated,
          ),
          if (_selected != null && _selected!.details.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                _selected!.details,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
            ),
          if (_group == 'cargo') ...[
            const SizedBox(height: 10),
            TextField(
              controller: _cargoNote,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'O que vai transportar?',
                hintText: 'Ex.: um sofá e 10 caixas',
                counterText: '',
              ),
            ),
            if (_selected?.helpers ?? false) _helpersRow(estimate),
          ],
          // O que mudou nas «Mais opções», à vista e fácil de desfazer.
          if (_offer != null || _preferred != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_offer != null)
                  InputChip(
                    avatar: const Icon(Icons.sell_outlined, size: 18),
                    label: Text('O seu preço: ${kz(_price)}'),
                    onPressed: () => _openOptions(estimate),
                    onDeleted: () => setState(() => _offer = null),
                    deleteButtonTooltipMessage: 'Voltar ao preço da tarifa',
                  ),
                if (_preferred != null)
                  InputChip(
                    avatar: const Icon(Icons.favorite, size: 18, color: BazaColors.red),
                    label: Text('Chamar ${_preferred!.driver.name.split(' ').first}'),
                    onPressed: _pickDriver,
                    onDeleted: () => setState(() => _preferred = null),
                    deleteButtonTooltipMessage: 'Qualquer motorista',
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  /// Barra fixa: forma de pagamento · Pedir · mais opções.
  Widget _requestBar(Estimate estimate) {
    final busyOptions = _offer != null || _preferred != null;
    return Row(
      children: [
        _SquareButton(
          tooltip: 'Forma de pagamento: ${paymentLabels[_payment] ?? _payment}',
          onTap: () => _pickPayment(estimate),
          child: Icon(
            paymentIcons[_payment] ?? Icons.payments_outlined,
            color: _payment == 'cash' ? BazaColors.green : BazaColors.ink,
            size: 28,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AsyncButton(
            label: [
              _preferred != null
                  ? 'Chamar ${_preferred!.driver.name.split(' ').first}'
                  : 'Pedir',
              if (_offer != null) kz(_price),
            ].join(' · '),
            onPressed: _request,
          ),
        ),
        const SizedBox(width: 10),
        _SquareButton(
          tooltip: 'Mais opções: propor preço, motorista preferido',
          onTap: () => _openOptions(estimate),
          dot: busyOptions,
          child: const Icon(Icons.tune, size: 26),
        ),
      ],
    );
  }

  Widget _helpersRow(Estimate estimate) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ajudantes para carregar',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '${kz(estimate.helperFee)} cada',
                style: const TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Menos um ajudante',
          onPressed: _helpers > 0
              ? () => setState(() {
                  _helpers--;
                  _offer = null;
                })
              : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text(
          '$_helpers',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        IconButton(
          tooltip: 'Mais um ajudante',
          onPressed: _helpers < estimate.maxHelpers
              ? () => setState(() {
                  _helpers++;
                  _offer = null;
                })
              : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    ),
  );

  /// «Mais opções»: motorista preferido e propor outro preço.
  Future<void> _openOptions(Estimate estimate) async {
    final pickDriver = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          void update(VoidCallback f) {
            setState(f);
            setSheet(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Mais opções',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 14),
                  _OptionTile(
                    icon: _preferred == null ? Icons.favorite_border : Icons.favorite,
                    label: _preferred == null
                        ? 'Qualquer motorista'
                        : _preferred!.driver.name,
                    trailing: _preferred == null ? 'Preferidos' : 'Alterar',
                    compact: true,
                    onTap: () => Navigator.pop(context, true),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Propor o meu preço',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  PriceStepper(
                    value: _price,
                    min: estimate.minFare(_suggestedTotal),
                    max: estimate.maxFare(_suggestedTotal),
                    reference: _suggestedTotal,
                    onChanged: (v) =>
                        update(() => _offer = v == _suggestedTotal ? null : v),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Os motoristas aceitam o seu preço ou respondem com o deles.',
                      style: TextStyle(color: BazaColors.muted, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Feito'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (pickDriver == true && mounted) await _pickDriver();
  }

  Future<void> _pickPayment(Estimate estimate) async {
    final balance = context.read<Session>().user!.walletBalance;
    final chosen = await showModalBottomSheet<String>(
      isDismissible: false,
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Forma de pagamento',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            for (final m in estimate.paymentMethods)
              ListTile(
                leading: Icon(paymentIcons[m]),
                title: Text(paymentLabels[m] ?? m),
                subtitle: m == 'wallet' ? Text('Saldo: ${kz(balance)}') : null,
                trailing: m == _payment
                    ? const Icon(Icons.check, color: BazaColors.green)
                    : null,
                onTap: () => Navigator.pop(context, m),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) setState(() => _payment = chosen);
  }

  /// Escolher um motorista preferido para chamar primeiro (ou voltar a "qualquer").
  Future<void> _pickDriver() async {
    final favorites = loadFavorites(
      context.read<Session>().api,
      near: _pickup?.latLng ?? _me,
    );
    final chosen = await showModalBottomSheet<Object>(
      isDismissible: false,
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _DriverPicker(
        favorites: favorites,
        selectedId: _preferred?.driver.id,
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      if (chosen is FavoriteDriver) {
        _preferred = chosen;
        // A corrida é feita na viatura desse motorista.
        _category = chosen.driver.vehicle?.category ?? _category;
        _group = cargoCategories.contains(_category) ? 'cargo' : 'ride';
      } else {
        _preferred = null;
      }
    });
  }

  /// "Chega em 4 min · 1,2 km. " quando já há estimativa; vazio caso contrário.
  String _eta(String prefix) {
    final rides = context.read<RideState>();
    final s = rides.etaSeconds, m = rides.etaMeters;
    if (s == null || m == null) return '';
    return '$prefix ${minutes(s)} · ${km(m)}. ';
  }

  // ── Corrida pedida ────────────────────────────────────────────────────────
  Widget _ridePanel(Ride ride) {
    final driver = ride.driver;
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RouteSummary(
          pickup: ride.pickup.address,
          dropoff: ride.dropoff.address,
          stops: [for (final s in ride.stops) s.address],
        ),
        if (ride.isCargo) CargoLine(ride: ride),
      ],
    );
    Widget cancelButton() => AsyncButton(
      label: 'Cancelar corrida',
      outlined: true,
      danger: true,
      onPressed: () => _cancel(ride),
    );

    switch (ride.status) {
      case 'searching':
        final near = _estimate?.nearbyDrivers ?? 0;
        return BottomPanel(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: PanelTitle(
                    ride.exclusive
                        ? 'A chamar ${ride.preferredDriverName ?? 'o seu motorista'}…'
                        : near > 5
                        ? 'Mais de 5 motoristas perto'
                        : near > 1
                        ? '$near motoristas perto'
                        : 'À procura de motorista…',
                    subtitle: ride.exclusive
                        ? 'Se não responder em 30 segundos, procuramos outros motoristas.'
                        : ride.preferredDriverName != null
                        ? '${ride.preferredDriverName} não respondeu. A procurar outros motoristas…'
                        : ride.negotiated
                        ? 'Os motoristas estão a ver o seu pedido e a enviar propostas.'
                        : near > 1
                        ? 'A escolher um para a sua viagem.'
                        : 'Isto costuma demorar menos de um minuto.',
                  ),
                ),
                const SizedBox(width: 10),
                _Elapsed(since: ride.createdAt),
              ],
            ),
            const LinearProgressIndicator(
              color: BazaColors.yellow,
              backgroundColor: BazaColors.surface,
              minHeight: 5,
            ),
            const SizedBox(height: 14),
            _TripCard(ride: ride),
            if (ride.isCargo) CargoLine(ride: ride),
            const SizedBox(height: 14),
            _Negotiation(key: ValueKey(ride.id), ride: ride),
            const SizedBox(height: 10),
            _CancelRow(onTap: () => _cancel(ride)),
          ],
        );
      case 'accepted' || 'arrived':
        final arrived = ride.status == 'arrived';
        return BottomPanel(
          children: [
            PanelTitle(
              driver == null
                  ? (arrived ? 'O motorista chegou' : 'Motorista a caminho')
                  : arrived
                  ? '${driver.name.split(' ').first} chegou'
                  : '${driver.name.split(' ').first} está a caminho',
              subtitle: arrived
                  ? 'Encontre-o em ${ride.pickup.address}.'
                  : '${_eta('Chega em')}Confirme a matrícula antes de entrar.',
            ),
            if (driver != null) PartyCard(party: driver),
            const SizedBox(height: 10),
            ContactBar(ride: ride),
            const SizedBox(height: 8),
            SafetyBar(ride: ride),
            const SizedBox(height: 14),
            summary,
            const SizedBox(height: 14),
            FareLine(ride: ride),
            const SizedBox(height: 16),
            cancelButton(),
          ],
        );
      case 'in_progress':
        return BottomPanel(
          children: [
            PanelTitle(
              'Em viagem',
              subtitle: ride.noDestination
                  ? 'Serviço em curso.'
                  : '${_eta('Chegada em')}Destino: ${ride.dropoff.address}',
            ),
            if (driver != null) PartyCard(party: driver),
            const SizedBox(height: 10),
            ContactBar(ride: ride),
            const SizedBox(height: 8),
            SafetyBar(ride: ride),
            const SizedBox(height: 14),
            FareLine(ride: ride),
          ],
        );
      case 'completed':
        return BottomPanel(
          children: [
            PanelTitle(
              'Chegou ao destino',
              subtitle: ride.paymentMethod == 'cash'
                  ? 'Pague ao motorista em dinheiro.'
                  : ride.paymentMethod == 'corporate'
                  ? 'Por conta da empresa: não tem nada a pagar ao motorista.'
                  : 'Pagamento efectuado.',
            ),
            FareLine(ride: ride),
            const SizedBox(height: 16),
            Text(
              'Como foi a viagem com ${driver?.name.split(' ').first ?? 'o motorista'}?',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            StarPicker(
              value: _stars,
              onChanged: (v) => setState(() => _stars = v),
            ),
            if (driver != null)
              _FavoriteToggle(key: ValueKey(ride.id), driver: driver),
            const SizedBox(height: 8),
            AsyncButton(
              label: _stars > 0 ? 'Enviar avaliação' : 'Concluir',
              onPressed: () => _finish(ride),
            ),
          ],
        );
      case 'no_drivers':
        return BottomPanel(
          children: [
            const PanelTitle(
              'Sem motoristas disponíveis',
              subtitle: 'Não encontrámos nenhum motorista por perto. Tente de novo daqui a pouco.',
            ),
            AsyncButton(
              label: 'Tentar novamente',
              onPressed: () => _finish(ride, keepDestination: true),
            ),
          ],
        );
      default: // cancelled
        return BottomPanel(
          children: [
            PanelTitle(
              'Corrida cancelada',
              subtitle: ride.cancelledBy == 'driver'
                  ? 'O motorista cancelou a corrida.'
                  : 'Não foi cobrado nenhum valor.',
            ),
            AsyncButton(
              label: ride.cancelledBy == 'driver' ? 'Pedir outra' : 'OK',
              onPressed: () =>
                  _finish(ride, keepDestination: ride.cancelledBy == 'driver'),
            ),
          ],
        );
    }
  }
}

class _AddressTile extends StatelessWidget {
  const _AddressTile({
    required this.icon,
    required this.color,
    required this.text,
    required this.onTap,
    this.emphasised = false,
    this.dense = false,
    this.trailing,
    this.subtitle,
  });
  final IconData icon;
  final Color color;
  final String text;
  final String? subtitle;
  final VoidCallback onTap;
  final bool emphasised;
  final bool dense;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Material(
    color: BazaColors.surface,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: dense ? 12 : 16,
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: emphasised ? 18 : 15,
                      fontWeight: emphasised
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        color: BazaColors.muted,
                        fontSize: 12.5,
                      ),
                    ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    ),
  );
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.label,
    required this.trailing,
    required this.onTap,
    this.compact = false,
  });
  final IconData icon;
  final String label, trailing;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: compact ? 10 : 14),
          child: Row(
            children: [
              Icon(icon, size: compact ? 22 : 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                trailing,
                style: TextStyle(
                  fontSize: compact ? 14 : 17,
                  fontWeight: compact ? FontWeight.w500 : FontWeight.w800,
                  color: compact ? BazaColors.muted : BazaColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Lista dos motoristas preferidos para escolher quem chamar.
class _DriverPicker extends StatelessWidget {
  const _DriverPicker({required this.favorites, this.selectedId});
  final Future<List<FavoriteDriver>> favorites;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: FutureBuilder<List<FavoriteDriver>>(
          future: favorites,
          builder: (context, snap) {
            final list = snap.data;
            return ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Quem quer chamar?',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                ListTile(
                  leading: const CircleAvatar(
                    radius: 22,
                    backgroundColor: BazaColors.surface,
                    foregroundColor: BazaColors.ink,
                    child: Icon(Icons.groups_outlined),
                  ),
                  title: const Text('Qualquer motorista'),
                  subtitle: const Text('O mais próximo que aceitar'),
                  trailing: selectedId == null
                      ? const Icon(Icons.check, color: BazaColors.green)
                      : null,
                  onTap: () => Navigator.pop(context, 'any'),
                ),
                if (snap.hasError)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '${snap.error}',
                      style: const TextStyle(color: BazaColors.red),
                    ),
                  )
                else if (list == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: CircularProgressIndicator(color: BazaColors.ink),
                    ),
                  )
                else if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Text(
                      'Ainda não tem motoristas preferidos. No fim de uma corrida pode adicionar o motorista aos preferidos e chamá-lo aqui.',
                      style: TextStyle(color: BazaColors.muted),
                    ),
                  )
                else
                  for (final f in list)
                    FavoriteTile(
                      favorite: f,
                      // Só se pode chamar quem está online e sem corrida.
                      onTap: f.available
                          ? () => Navigator.pop(context, f)
                          : null,
                      trailing: f.driver.id == selectedId
                          ? const Icon(Icons.check, color: BazaColors.green)
                          : null,
                    ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Botão para adicionar (ou tirar) o motorista da corrida dos preferidos.
class _FavoriteToggle extends StatefulWidget {
  const _FavoriteToggle({super.key, required this.driver});
  final RideParty driver;

  @override
  State<_FavoriteToggle> createState() => _FavoriteToggleState();
}

class _FavoriteToggleState extends State<_FavoriteToggle> {
  bool? _isFavorite; // null enquanto não se sabe
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await loadFavorites(context.read<Session>().api);
      if (mounted)
        setState(
          () => _isFavorite = list.any((f) => f.driver.id == widget.driver.id),
        );
    } on ApiException {
      if (mounted) setState(() => _isFavorite = false);
    }
  }

  Future<void> _toggle() async {
    final api = context.read<Session>().api;
    final add = !(_isFavorite ?? false);
    setState(() => _busy = true);
    try {
      final path = '/favorites/${widget.driver.id}';
      await (add ? api.put(path) : api.delete(path));
      if (mounted) setState(() => _isFavorite = add);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fav = _isFavorite ?? false;
    return TextButton.icon(
      onPressed: _isFavorite == null || _busy ? null : _toggle,
      icon: Icon(
        fav ? Icons.favorite : Icons.favorite_border,
        color: fav ? BazaColors.red : null,
      ),
      label: Text(fav ? 'Nos seus preferidos' : 'Adicionar aos preferidos'),
    );
  }
}

/// Negociação enquanto se procura motorista: o passageiro pode mudar o preço
/// que oferece e responder às propostas dos motoristas.
class _Negotiation extends StatefulWidget {
  const _Negotiation({super.key, required this.ride});
  final Ride ride;

  @override
  State<_Negotiation> createState() => _NegotiationState();
}

class _NegotiationState extends State<_Negotiation> {
  late int _price = widget.ride.fare;

  @override
  void didUpdateWidget(_Negotiation old) {
    super.didUpdateWidget(old);
    if (old.ride.fare != widget.ride.fare) _price = widget.ride.fare;
  }

  Future<void> _post(String path, [Map<String, dynamic>? body]) async {
    final rides = context.read<RideState>();
    final res = await context.read<Session>().api.post(path, body);
    rides.setRide(Ride.fromJson(res['ride'] as Map<String, dynamic>));
  }

  @override
  Widget build(BuildContext context) {
    final ride = widget.ride;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              'O seu preço',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            Icon(
              paymentIcons[ride.paymentMethod],
              size: 18,
              color: BazaColors.muted,
            ),
            const SizedBox(width: 6),
            // O nome do pagamento encolhe com reticências em ecrãs estreitos.
            Flexible(
              child: Text(
                paymentLabels[ride.paymentMethod] ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BazaColors.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (ride.negotiated) ...[
          Text(
            ride.priceOpen
                ? 'Preço a combinar: aguarde as propostas dos motoristas e escolha a que preferir.'
                : 'Propôs ${kz(ride.fare)}. Um motorista pode aceitar ou responder com outro valor.',
            style: const TextStyle(color: BazaColors.muted),
          ),
          const SizedBox(height: 10),
          PriceInput(
            key: ValueKey('preco-${ride.fare}'),
            label: ride.priceOpen
                ? 'Propor um preço (opcional)'
                : 'Mudar o meu preço',
            initial: ride.priceOpen ? null : ride.fare,
            action: (v) => 'Propor ${kz(v)}',
            onSubmit: (v) => _post('/rides/${ride.id}/price', {'amount': v}),
          ),
        ] else ...[
          PriceStepper(
            value: _price,
            min: ride.fareMin ?? ride.fare,
            max: ride.fareMax ?? ride.fare,
            reference: ride.suggestedFare,
            onChanged: (v) => setState(() => _price = v),
          ),
          if (_price != ride.fare) ...[
            const SizedBox(height: 8),
            AsyncButton(
              label:
                  '${_price > ride.fare ? 'Subir' : 'Baixar'} para ${kz(_price)}',
              outlined: true,
              onPressed: () =>
                  _post('/rides/${ride.id}/price', {'amount': _price}),
            ),
          ] else if (ride.bids.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Sem motorista? Experimente subir o preço.',
                style: TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
            ),
        ],
        if (ride.bids.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            ride.bids.length == 1
                ? 'Proposta de um motorista'
                : 'Propostas de ${ride.bids.length} motoristas',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 8),
          for (final bid in ride.bids)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: BazaColors.ink, width: 1.5),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Avatar(
                        name: bid.driver.name,
                        photoUrl: bid.driver.photoUrl,
                        radius: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              bid.driver.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              [
                                if (bid.driver.rating != null)
                                  '★ ${bid.driver.rating!.toStringAsFixed(1).replaceAll('.', ',')}',
                                if (bid.driver.vehicle != null)
                                  bid.driver.vehicle!.description,
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: BazaColors.muted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        kz(bid.amount),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: AsyncButton(
                          label: 'Recusar',
                          outlined: true,
                          onPressed: () => _post(
                            '/rides/${ride.id}/bids/${bid.driver.id}/decline',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: AsyncButton(
                          label: 'Aceitar ${kz(bid.amount)}',
                          onPressed: () => _post(
                            '/rides/${ride.id}/bids/${bid.driver.id}/accept',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// Aviso de taxa por procura, por cima dos preços: o motivo e o multiplicador,
/// em letra grande e com ícone (há quem tenha pouca prática com o telemóvel).
class _SurgeNotice extends StatelessWidget {
  const _SurgeNotice({required this.label, required this.multiplier});
  final String label;
  final double multiplier;

  @override
  Widget build(BuildContext context) {
    final x = (multiplier * 100).round() / 100;
    final times = '×${x.toString().replaceAll('.', ',')}';
    return Semantics(
      label: '$label. Preço multiplicado por $times.',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3C4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFC400)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFFFFC400),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.trending_up, color: BazaColors.ink),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$label · $times',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const Text(
                    'Os preços abaixo já incluem este aumento. O preço que vê é o que paga.',
                    style: TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Botão redondo e branco sobre o mapa (a seta para voltar).
class _RoundMapButton extends StatelessWidget {
  const _RoundMapButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: Colors.black38,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 52,
          child: Icon(icon, color: BazaColors.ink, size: 26),
        ),
      ),
    ),
  );
}

/// Botão quadrado ao lado do «Pedir» (pagamento, mais opções); [dot] marca
/// que há uma opção escolhida.
class _SquareButton extends StatelessWidget {
  const _SquareButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.dot = false,
  });
  final String tooltip;
  final VoidCallback onTap;
  final Widget child;
  final bool dot;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: BazaColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 54,
          child: Stack(
            alignment: Alignment.center,
            children: [
              child,
              if (dot)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: BazaColors.red,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Recolha, paragens e destino em linhas finas, como uma lista: o destino
/// leva a duração da viagem e o botão «Paragens».
class _RouteBox extends StatelessWidget {
  const _RouteBox({
    required this.pickup,
    required this.dropoff,
    required this.stops,
    required this.canAddStop,
    required this.onPickup,
    required this.onDropoff,
    required this.onAddStop,
    required this.onRemoveStop,
    this.durationS,
  });
  final String pickup, dropoff;
  final List<String> stops;
  final bool canAddStop;
  final int? durationS;
  final VoidCallback onPickup, onDropoff, onAddStop;
  final ValueChanged<int> onRemoveStop;

  @override
  Widget build(BuildContext context) {
    Widget row({
      required IconData icon,
      required Color color,
      required Widget text,
      required VoidCallback onTap,
      Widget? trailing,
      bool divider = true,
    }) => InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        child: Row(
          children: [
            SizedBox(width: 34, child: Icon(icon, color: color, size: 24)),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 54),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  border: divider
                      ? const Border(
                          bottom: BorderSide(color: Color(0xFFE8E9EC)),
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    Expanded(child: text),
                    ?trailing,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      children: [
        row(
          icon: Icons.hail,
          color: BazaColors.green,
          text: Text(
            pickup,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
          ),
          onTap: onPickup,
        ),
        for (final (i, stop) in stops.indexed)
          row(
            icon: Icons.stop_circle_outlined,
            color: const Color(0xFFB45309),
            text: Text(
              stop,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
            ),
            onTap: () {},
            trailing: IconButton(
              tooltip: 'Remover a paragem ${i + 1}',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => onRemoveStop(i),
            ),
          ),
        row(
          icon: Icons.sports_score,
          color: BazaColors.ink,
          divider: false,
          onTap: onDropoff,
          text: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: dropoff),
                if (durationS != null)
                  TextSpan(
                    text: ' · ${minutes(durationS!)}',
                    style: const TextStyle(color: BazaColors.muted),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
          ),
          trailing: canAddStop
              ? Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ActionChip(
                    label: const Text('Paragens'),
                    avatar: const Icon(Icons.add, size: 18),
                    tooltip: 'Adicionar paragem',
                    backgroundColor: BazaColors.surface,
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    onPressed: onAddStop,
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

/// Separadores «Viagens» / «Entregas e carga» (pílula cinzenta no escolhido).
class _GroupTabs extends StatelessWidget {
  const _GroupTabs({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget tab(String key, String label, IconData icon) {
      final on = key == value;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: on ? BazaColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onChanged(key),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: on ? BazaColors.ink : BazaColors.muted),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      color: on ? BazaColors.ink : BazaColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab('ride', 'Viagens', Icons.hail),
        tab('cargo', 'Entregas e carga', Icons.inventory_2_outlined),
      ],
    );
  }
}

/// Tempo desde o pedido, «00:14», a contar ao segundo.
class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.since});
  final DateTime since;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  late final Timer _timer = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _timer; // arranca o relógio
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(widget.since);
    final s = d.isNegative ? 0 : d.inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '${two(s ~/ 60)}:${two(s % 60)}',
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Recolha, paragens e destino da corrida pedida, num cartão cinzento.
class _TripCard extends StatelessWidget {
  const _TripCard({required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    Widget line(Widget lead, String title, String value, {bool last = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              SizedBox(width: 44, child: Center(child: lead)),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    border: last
                        ? null
                        : const Border(
                            bottom: BorderSide(color: Color(0xFFE2E4E8)),
                          ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: BazaColors.muted,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16.5),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
    final noDest = ride.noDestination;
    return Container(
      decoration: BoxDecoration(
        color: BazaColors.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          line(
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: BazaColors.green,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.hail, color: Colors.white),
            ),
            'Recolha',
            ride.pickup.address,
            last: noDest && ride.stops.isEmpty,
          ),
          for (final (i, s) in ride.stops.indexed)
            line(
              const Icon(Icons.stop_circle_outlined, color: Color(0xFFB45309)),
              'Paragem ${i + 1}',
              s.address,
              last: noDest && i == ride.stops.length - 1,
            ),
          if (!noDest)
            line(
              const Icon(Icons.sports_score, size: 26),
              'Destino',
              ride.dropoff.address,
              last: true,
            ),
        ],
      ),
    );
  }
}

/// «Cancelar viagem», em vermelho, numa linha.
class _CancelRow extends StatelessWidget {
  const _CancelRow({required this.onTap});
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: () async {
      try {
        await onTap();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    },
    child: const Padding(
      padding: EdgeInsets.symmetric(vertical: 14, horizontal: 4),
      child: Row(
        children: [
          Icon(Icons.cancel_outlined, color: BazaColors.red, size: 26),
          SizedBox(width: 14),
          Expanded(
            child: Text(
              'Cancelar viagem',
              style: TextStyle(
                color: BazaColors.red,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Icon(Icons.chevron_right, color: BazaColors.red),
        ],
      ),
    ),
  );
}

/// «Tem a certeza de que quer cancelar?» — Cancelar / Aguardar.
class _ConfirmCancelSheet extends StatelessWidget {
  const _ConfirmCancelSheet({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Tem a certeza de que quer cancelar?',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, height: 1.15),
          ),
          const SizedBox(height: 10),
          Text(text, style: const TextStyle(fontSize: 16, height: 1.35)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BazaColors.surface,
                    foregroundColor: BazaColors.ink,
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Cancelar'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Aguardar'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// «O que aconteceu?»: o motivo do cancelamento (opcional) e um comentário.
class _CancelReasonSheet extends StatefulWidget {
  const _CancelReasonSheet({required this.withDriver});

  /// Já havia motorista: mostra também os motivos sobre ele.
  final bool withDriver;

  @override
  State<_CancelReasonSheet> createState() => _CancelReasonSheetState();
}

class _CancelReasonSheetState extends State<_CancelReasonSheet> {
  String? _reason;
  final _comment = TextEditingController();

  static const _mine = [
    ('other_ride', 'Encontrei outra viagem', Icons.directions_car_outlined),
    ('changed_plans', 'Mudança de planos', Icons.directions_walk),
    ('wrong_address', 'Morada errada', Icons.wrong_location_outlined),
  ];
  static const _driver = [
    ('driver_asked', 'Pediu para cancelar', Icons.person_off_outlined),
    ('driver_rude', 'Comportamento rude', Icons.sentiment_very_dissatisfied_outlined),
    ('driver_not_coming', 'Não veio até mim', Icons.wrong_location),
    ('driver_more_money', 'Pediu mais dinheiro', Icons.payments_outlined),
    ('driver_refused', 'Recusou-se a conduzir', Icons.front_hand_outlined),
    ('driver_unreachable', 'Não respondia', Icons.phone_disabled_outlined),
    ('other_passenger', 'Outro passageiro no carro', Icons.airline_seat_recline_normal),
  ];
  static const _service = [
    ('pickup_slow', 'A recolha demorou demasiado', Icons.schedule),
    ('driver_rating', 'Avaliação do motorista', Icons.star_outline),
    ('price', 'Preço da viagem', Icons.sell_outlined),
  ];

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  void _done() =>
      Navigator.pop(context, (reason: _reason, comment: _comment.text));

  Widget _group(String title, List<(String, String, IconData)> items) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(color: BazaColors.muted, fontSize: 14.5),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (key, label, icon) in items)
                  ChoiceChip(
                    avatar: Icon(
                      icon,
                      size: 20,
                      color: _reason == key ? Colors.white : BazaColors.ink,
                    ),
                    label: Text(label),
                    labelStyle: TextStyle(
                      fontSize: 15,
                      color: _reason == key ? Colors.white : BazaColors.ink,
                    ),
                    showCheckmark: false,
                    selected: _reason == key,
                    selectedColor: BazaColors.ink,
                    backgroundColor: BazaColors.surface,
                    side: BorderSide.none,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onSelected: (on) => setState(() => _reason = on ? key : null),
                  ),
              ],
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'O que aconteceu?',
                            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Não cancelar',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _group('Iniciativa minha', _mine),
                    if (widget.withDriver) _group('Acções do motorista', _driver),
                    _group(
                      'Problemas do serviço',
                      widget.withDriver
                          ? _service
                          : _service.where((r) => r.$1 != 'driver_rating').toList(),
                    ),
                    TextField(
                      controller: _comment,
                      maxLength: 300,
                      maxLines: 2,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: (_) => _done(),
                      decoration: const InputDecoration(
                        hintText: 'Os seus comentários (opcional)',
                        counterText: '',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BazaColors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: _done,
                child: const Text('Cancelar a viagem'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
