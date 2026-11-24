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

  Future<void> _cancel(Ride ride) async {
    final confirmed = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar a corrida?'),
        content: ride.driver == null
            ? null
            : const Text(
                'Já há um motorista a caminho. Cancelar mais de 2 minutos depois de ele aceitar, ou com ele já no local, conta como cancelamento tardio: 3 em 24 horas suspendem a conta por algum tempo.',
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Não'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sim, cancelar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final rides = context.read<RideState>();
    final res = await context.read<Session>().api.post(
      '/rides/${ride.id}/cancel',
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
          fitKey: ride != null
              ? '${ride.id}:${ride.status}'
              : '${pickup?.lat},${pickup?.lng}:${dropoff?.lat},${dropoff?.lng}:${_stops.length}:${_estimate != null}',
        ),
        if (ride != null)
          _ridePanel(ride)
        else if (_dropoff == null)
          _wherePanel()
        else
          _estimatePanel(),
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
  Widget _estimatePanel() {
    final estimate = _estimate;
    return BottomPanel(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  _AddressTile(
                    icon: Icons.trip_origin,
                    color: BazaColors.green,
                    text: _pickup?.address ?? 'Escolher ponto de recolha',
                    dense: true,
                    onTap: () => _choose(pickup: true),
                  ),
                  // Paragens intermédias, entre a recolha e o destino.
                  for (final (i, stop) in _stops.indexed) ...[
                    const SizedBox(height: 6),
                    _AddressTile(
                      icon: Icons.stop_circle_outlined,
                      color: const Color(0xFFB45309),
                      text: stop.address,
                      dense: true,
                      onTap: () {},
                      trailing: IconButton(
                        tooltip: 'Remover a paragem ${i + 1}',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => _removeStop(i),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  _AddressTile(
                    icon: Icons.flag,
                    color: BazaColors.red,
                    text: _dropoff!.address,
                    dense: true,
                    onTap: () => _choose(pickup: false),
                  ),
                  if (_stops.length < (_estimate?.maxStops ?? 3))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _addStop,
                        icon: const Icon(
                          Icons.add_location_alt_outlined,
                          size: 18,
                        ),
                        label: Text(
                          _stops.isEmpty
                              ? 'Adicionar paragem'
                              : 'Adicionar outra paragem',
                        ),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Limpar destino',
              onPressed: () => setState(() {
                _dropoff = null;
                _stops.clear();
                _estimate = null;
                _preferred = null;
                _estimateError = null;
              }),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 14),
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
          Text(
            '${km(estimate.distanceM)} · cerca de ${minutes(estimate.durationS)}',
            style: const TextStyle(color: BazaColors.muted),
          ),
          const SizedBox(height: 10),
          if (estimate.options.any((o) => o.group == 'cargo' && !o.negotiated))
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: 'ride',
                  label: Text('Viagem'),
                  icon: Icon(Icons.hail),
                ),
                ButtonSegment(
                  value: 'cargo',
                  label: Text('Carga e entregas'),
                  icon: Icon(Icons.inventory_2_outlined),
                ),
              ],
              selected: {_group},
              onSelectionChanged: (s) {
                final first = estimate.options
                    .where((o) => o.group == s.first && !o.negotiated)
                    .firstOrNull;
                if (first != null)
                  _selectCategory(first.category, group: s.first);
              },
            ),
          const SizedBox(height: 10),
          // Os serviços de preço combinado pedem-se à parte (ver botão abaixo).
          for (final o in estimate.options.where(
            (o) => o.group == _group && !o.negotiated,
          ))
            _OptionTile(
              icon: categoryIcons[o.category] ?? Icons.directions_car,
              label: o.label,
              subtitle: o.details,
              trailing: kz(o.fare),
              selected: o.category == _category,
              onTap: () => _selectCategory(o.category),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _requestNegotiated,
              icon: const Icon(Icons.local_shipping_outlined, size: 18),
              label: const Text(
                'Triciclo, XL, carrinha ou camião: preço a combinar',
              ),
            ),
          ),
          if (_group == 'cargo') ...[
            const SizedBox(height: 4),
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
            if (_selected?.helpers ?? false)
              Padding(
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
                            style: const TextStyle(
                              color: BazaColors.muted,
                              fontSize: 13,
                            ),
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
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
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
              ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 6),
          _OptionTile(
            icon: paymentIcons[_payment] ?? Icons.payments_outlined,
            label: paymentLabels[_payment] ?? _payment,
            trailing: 'Alterar',
            compact: true,
            onTap: () => _pickPayment(estimate),
          ),
          _OptionTile(
            icon: _preferred == null ? Icons.favorite_border : Icons.favorite,
            label: _preferred == null
                ? 'Qualquer motorista'
                : _preferred!.driver.name,
            trailing: _preferred == null ? 'Preferidos' : 'Alterar',
            compact: true,
            onTap: _pickDriver,
          ),
          if (_selected != null) ...[
            const SizedBox(height: 6),
            // O passageiro pode propor outro preço; os motoristas aceitam ou respondem.
            PriceStepper(
              value: _price,
              min: estimate.minFare(_suggestedTotal),
              max: estimate.maxFare(_suggestedTotal),
              reference: _suggestedTotal,
              onChanged: (v) =>
                  setState(() => _offer = v == _suggestedTotal ? null : v),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Pode propor o seu preço. Os motoristas aceitam ou respondem com o deles.',
                style: TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 14),
          AsyncButton(
            label: _selected == null
                ? 'Pedir'
                : '${_preferred != null ? 'Chamar ${_preferred!.driver.name.split(' ').first}' : 'Pedir ${_selected!.label}'}'
                      ' · ${kz(_price)}',
            onPressed: _selected == null ? null : _request,
          ),
        ],
      ],
    );
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
        return BottomPanel(
          children: [
            PanelTitle(
              ride.exclusive
                  ? 'A chamar ${ride.preferredDriverName ?? 'o seu motorista'}…'
                  : 'À procura de motorista…',
              subtitle: ride.exclusive
                  ? 'Se não responder em 30 segundos, procuramos outros motoristas.'
                  : ride.preferredDriverName != null
                  ? '${ride.preferredDriverName} não respondeu. A procurar outros motoristas…'
                  : ride.negotiated
                  ? 'Os motoristas estão a ver o seu pedido e a enviar propostas.'
                  : 'Isto costuma demorar menos de um minuto.',
            ),
            const LinearProgressIndicator(
              color: BazaColors.yellow,
              backgroundColor: BazaColors.surface,
              minHeight: 5,
            ),
            const SizedBox(height: 16),
            summary,
            const SizedBox(height: 14),
            _Negotiation(key: ValueKey(ride.id), ride: ride),
            const SizedBox(height: 16),
            cancelButton(),
          ],
        );
      case 'accepted' || 'arrived':
        final arrived = ride.status == 'arrived';
        return BottomPanel(
          children: [
            PanelTitle(
              arrived ? 'O motorista chegou' : 'Motorista a caminho',
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
    this.subtitle,
    required this.onTap,
    this.selected = false,
    this.compact = false,
  });
  final IconData icon;
  final String label, trailing;
  final String? subtitle;
  final VoidCallback onTap;
  final bool selected;
  final bool compact;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: selected
          ? BazaColors.yellow.withValues(alpha: 0.18)
          : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? BazaColors.ink : const Color(0xFFE5E7EB),
          width: selected ? 1.8 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: compact || subtitle != null ? 10 : 14,
          ),
          child: Row(
            children: [
              Icon(icon, size: compact ? 22 : 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
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
