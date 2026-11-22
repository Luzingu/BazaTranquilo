import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/driver_state.dart';
import '../state/ride_state.dart';
import '../state/session.dart';
import '../widgets/baza_map.dart';
import '../widgets/common.dart';
import '../widgets/contact.dart';
import '../widgets/safety.dart';
import '../widgets/slide_action.dart';
import 'driver_account_screen.dart';
import 'garage_screen.dart';
import 'vehicle_screen.dart';

class DriverHome extends StatelessWidget {
  const DriverHome({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) =>
          DriverState(context.read<Session>(), context.read<RideState>())
            ..init(),
      child: const _DriverView(),
    );
  }
}

class _DriverView extends StatefulWidget {
  const _DriverView();

  @override
  State<_DriverView> createState() => _DriverViewState();
}

class _DriverViewState extends State<_DriverView> {
  int _stars = 0;

  Future<void> _advance(Ride ride, String status) async {
    final rides = context.read<RideState>();
    final res = await context.read<Session>().api.post(
      '/rides/${ride.id}/status',
      {'status': status},
    );
    rides.setRide(Ride.fromJson(res['ride'] as Map<String, dynamic>));
  }

  Future<void> _cancel(Ride ride) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar esta corrida?'),
        content: const Text(
          'O passageiro será avisado. Desistir de uma corrida já aceite conta como cancelamento tardio: 3 em 24 horas suspendem a conta por algum tempo.',
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
    await context.read<Session>().api.post('/rides/${ride.id}/cancel');
    rides.clear();
  }

  Future<void> _finish(Ride ride) async {
    final session = context.read<Session>();
    final rides = context.read<RideState>();
    final driver = context.read<DriverState>();
    if (ride.status == 'completed' && _stars > 0) {
      await session.api.post('/rides/${ride.id}/rate', {'stars': _stars});
    }
    rides.clear();
    if (mounted) setState(() => _stars = 0);
    driver.loadSummary();
    session.refreshUser().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final driver = context.watch<DriverState>();
    final rides = context.watch<RideState>();
    final ride = rides.isDriverRide ? rides.ride : null;
    final offer = ride == null && driver.offers.isNotEmpty
        ? driver.offers.first
        : null;
    final shown = ride ?? offer;
    final showTrip = shown != null && (offer != null || shown.isActive);

    // O motorista ainda não tem o passageiro a bordo.
    final toPickup =
        ride != null && (ride.status == 'accepted' || ride.status == 'arrived');

    return Stack(
      children: [
        BazaMap(
          me: driver.position,
          stops: showTrip ? [for (final s in shown.stops) s.latLng] : const [],
          pickup: showTrip ? shown.pickup.latLng : null,
          dropoff: showTrip && !shown.noDestination
              ? shown.dropoff.latLng
              : null,
          // A caminho da recolha: linha forte até ao passageiro e, mais clara, a
          // viagem que se segue. Em viagem: linha forte até ao destino.
          route: !showTrip
              ? const []
              : (ride != null && rides.liveRoute.isNotEmpty
                    ? rides.liveRoute
                    : (toPickup
                          ? const []
                          : decodePolyline(shown.routeGeometry))),
          tripRoute: showTrip && (toPickup || offer != null)
              ? decodePolyline(shown.routeGeometry)
              : const [],
          labels: true,
          meIsCar: ride != null && ride.isActive,
          // Durante a corrida o mapa acompanha a viatura e o próximo ponto.
          follow: ride != null && ride.isActive ? driver.position : null,
          followTarget: ride == null || !ride.isActive
              ? null
              : (toPickup || ride.noDestination
                    ? ride.pickup.latLng
                    : ride.dropoff.latLng),
          bottomPadding: 300,
          fitKey: shown == null ? 'idle' : '${shown.id}:${shown.status}',
        ),
        if (ride != null)
          _ridePanel(ride)
        else if (offer != null)
          _offerPanel(driver, offer)
        else
          _idlePanel(driver),
      ],
    );
  }

  Widget _idlePanel(DriverState driver) {
    final online = driver.online;
    final vehicle = context.watch<Session>().user?.vehicle;
    final verification =
        context.watch<Session>().user?.verification ?? 'approved';
    final blocked = context.watch<Session>().user?.blocked ?? false;
    return BottomPanel(
      children: [
        PanelTitle(
          online ? 'Está online' : 'Está offline',
          subtitle: online
              ? 'A aguardar pedidos de corrida perto de si…'
              : 'Fique online para receber corridas.',
        ),
        if (online)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: LinearProgressIndicator(
              color: BazaColors.green,
              backgroundColor: BazaColors.surface,
              minHeight: 4,
            ),
          ),
        if (vehicle != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(categoryIcons[vehicle.category], color: BazaColors.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${categoryLabels[vehicle.category] ?? ''} · ${vehicle.make} ${vehicle.carModel} · ${vehicle.plate}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!online)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const GarageScreen()),
                    ),
                    child: const Text('Trocar'),
                  ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _Stat(
                label: 'Ganhos de hoje',
                value: kz(driver.earningsToday),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Stat(
                label: 'Corridas de hoje',
                value: '${driver.ridesToday}',
              ),
            ),
          ],
        ),
        _AccountNote(driver: driver),
        const SizedBox(height: 16),
        if (blocked)
          const _VerificationNotice(status: 'blocked')
        else if (verification != 'approved')
          _VerificationNotice(status: verification)
        else
          // Deslizar para a direita põe o motorista online; para a esquerda, offline.
          SlideAction(
            key: ValueKey(online),
            label: online ? 'Ficar offline' : 'Ficar online',
            reversed: online,
            color: online ? BazaColors.surface : BazaColors.green,
            foreground: online ? BazaColors.ink : Colors.white,
            icon: online ? Icons.power_settings_new : null,
            onSubmit: () => driver.setOnline(!online),
          ),
      ],
    );
  }

  Widget _offerPanel(DriverState driver, Ride offer) {
    return BottomPanel(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: PanelTitle(
                offer.exclusive
                    ? 'Pedido directo'
                    : (offer.negotiated ? 'Novo serviço' : 'Nova corrida'),
                subtitle: offer.exclusive
                    ? '${offer.passenger?.name ?? 'Um passageiro'} escolheu-o como motorista preferido.'
                    : null,
              ),
            ),
            Text(
              offer.priceOpen ? 'A combinar' : kz(offer.fare),
              style: TextStyle(
                fontSize: offer.priceOpen ? 18 : 24,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        RouteSummary(
          pickup: offer.pickup.address,
          dropoff: offer.dropoff.address,
          stops: [for (final s in offer.stops) s.address],
        ),
        if (offer.cargoNote != null) CargoLine(ride: offer),
        const SizedBox(height: 12),
        Text(
          offer.noDestination
              ? 'Destino a combinar com o cliente · ${paymentLabels[offer.paymentMethod]}'
              : '${km(offer.distanceM)} · ${minutes(offer.durationS)} · ${paymentLabels[offer.paymentMethod]}',
          style: const TextStyle(color: BazaColors.muted),
        ),
        const SizedBox(height: 16),
        _CounterOffer(key: ValueKey(offer.id), offer: offer, driver: driver),
      ],
    );
  }

  /// "4 min · 1,2 km · " quando já há estimativa; vazio caso contrário.
  String _eta() {
    final rides = context.read<RideState>();
    final s = rides.etaSeconds, m = rides.etaMeters;
    return s == null || m == null ? '' : '${minutes(s)} · ${km(m)} · ';
  }

  /// A menos de 150 metros do ponto de recolha.
  bool get _nearPickup => (context.read<RideState>().etaMeters ?? 9999) < 150;

  Widget _ridePanel(Ride ride) {
    final passenger = ride.passenger;
    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (passenger != null) PartyCard(party: passenger, showVehicle: false),
        if (ride.cargoNote != null) CargoLine(ride: ride),
        if (ride.stops.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: RouteSummary(
              pickup: ride.pickup.address,
              dropoff: ride.dropoff.address,
              stops: [for (final s in ride.stops) s.address],
            ),
          ),
      ],
    );
    Widget cancelButton() => AsyncButton(
      label: 'Cancelar corrida',
      outlined: true,
      danger: true,
      onPressed: () => _cancel(ride),
    );

    switch (ride.status) {
      case 'accepted':
        return BottomPanel(
          children: [
            PanelTitle(
              'A caminho do passageiro',
              subtitle: _nearPickup
                  ? 'Está a chegar ao passageiro. Deslize "Cheguei" quando parar.'
                  : '${_eta()}${ride.pickup.address}',
            ),
            card,
            const SizedBox(height: 10),
            ContactBar(ride: ride),
            const SizedBox(height: 8),
            SafetyBar(ride: ride),
            const SizedBox(height: 16),
            // Abre a navegação passo a passo até ao passageiro.
            _NavigateButton(
              label: 'Navegar até ao passageiro',
              to: ride.pickup,
            ),
            const SizedBox(height: 8),
            SlideAction(
              key: const ValueKey('arrived'),
              label: 'Cheguei',
              onSubmit: () => _advance(ride, 'arrived'),
            ),
            const SizedBox(height: 8),
            cancelButton(),
          ],
        );
      case 'arrived':
        return BottomPanel(
          children: [
            PanelTitle(
              'À espera do passageiro',
              subtitle: 'Destino: ${ride.dropoff.address}',
            ),
            card,
            const SizedBox(height: 10),
            ContactBar(ride: ride),
            const SizedBox(height: 8),
            SafetyBar(ride: ride),
            const SizedBox(height: 16),
            SlideAction(
              key: const ValueKey('start'),
              label: 'Iniciar viagem',
              color: BazaColors.green,
              foreground: Colors.white,
              onSubmit: () => _advance(ride, 'in_progress'),
            ),
            const SizedBox(height: 8),
            cancelButton(),
          ],
        );
      case 'in_progress':
        return BottomPanel(
          children: [
            PanelTitle(
              ride.negotiated ? 'Serviço em curso' : 'Em viagem',
              subtitle: ride.noDestination
                  ? 'Destino combinado com o cliente.'
                  : '${_eta()}Destino: ${ride.dropoff.address}',
            ),
            card,
            const SizedBox(height: 10),
            ContactBar(ride: ride),
            const SizedBox(height: 8),
            SafetyBar(ride: ride),
            const SizedBox(height: 14),
            FareLine(ride: ride),
            const SizedBox(height: 16),
            if (!ride.noDestination)
              _NavigateButton(
                label: ride.stops.isEmpty
                    ? 'Navegar até ao destino'
                    : 'Navegar (com paragens)',
                to: ride.dropoff,
                via: ride.stops,
              ),
            const SizedBox(height: 8),
            SlideAction(
              key: const ValueKey('finish'),
              label: 'Terminar viagem',
              color: BazaColors.red,
              foreground: Colors.white,
              icon: Icons.flag,
              onSubmit: () => _advance(ride, 'completed'),
            ),
          ],
        );
      case 'completed':
        final cash = ride.paymentMethod == 'cash';
        return BottomPanel(
          children: [
            PanelTitle(
              'Viagem terminada',
              subtitle: cash
                  ? 'Receba ${kz(ride.fare)} em dinheiro do passageiro.'
                  : ride.paymentMethod == 'corporate'
                  ? 'Por conta de uma empresa: não cobre ao passageiro. O Bazá paga-lhe o valor, menos a comissão.'
                  : context.read<Session>().user?.walletEnabled ?? false
                  ? 'Pago pela app. O valor foi creditado na sua carteira.'
                  : 'Pago pela app.',
            ),
            FareLine(ride: ride),
            const SizedBox(height: 16),
            const Text(
              'Avalie o passageiro',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            StarPicker(
              value: _stars,
              onChanged: (v) => setState(() => _stars = v),
            ),
            const SizedBox(height: 8),
            AsyncButton(
              label: _stars > 0 ? 'Enviar avaliação' : 'Concluir',
              onPressed: () => _finish(ride),
            ),
          ],
        );
      default: // cancelled
        return BottomPanel(
          children: [
            const PanelTitle(
              'Corrida cancelada',
              subtitle: 'O passageiro cancelou a corrida.',
            ),
            AsyncButton(label: 'OK', onPressed: () => _finish(ride)),
          ],
        );
    }
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: BazaColors.surface,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: BazaColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}

/// Aviso no lugar do botão "Ficar online" enquanto os documentos não estão aprovados.
class _VerificationNotice extends StatelessWidget {
  const _VerificationNotice({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final rejected = status == 'rejected';
    final blocked = status == 'blocked';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: rejected || blocked
            ? const Color(0xFFFEE2E2)
            : const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                blocked
                    ? Icons.block
                    : (rejected ? Icons.error_outline : Icons.hourglass_top),
                color: BazaColors.ink,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  blocked
                      ? 'Conta suspensa'
                      : (rejected
                            ? 'Documento rejeitado'
                            : 'Documentos em análise'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            blocked
                ? 'A sua conta foi suspensa e não pode receber corridas. Contacte o suporte do Bazá.'
                : rejected
                ? 'Um dos seus documentos não foi aceite. Veja o motivo e envie uma nova foto.'
                : 'Estamos a confirmar a sua carta de condução e o livrete. Avisamos assim que puder ficar online.',
          ),
          if (rejected)
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const VehicleScreen()),
                  ),
                  child: const Text('Carta de condução'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GarageScreen()),
                  ),
                  child: const Text('Viaturas'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Resposta do motorista a um pedido: aceitar o preço do passageiro, recusar,
/// ou propor outro preço (para cima ou para baixo) e esperar pela resposta.
class _CounterOffer extends StatefulWidget {
  const _CounterOffer({super.key, required this.offer, required this.driver});
  final Ride offer;
  final DriverState driver;

  @override
  State<_CounterOffer> createState() => _CounterOfferState();
}

class _CounterOfferState extends State<_CounterOffer> {
  late int _value = widget.offer.myBid ?? widget.offer.fare;

  @override
  void didUpdateWidget(_CounterOffer old) {
    super.didUpdateWidget(old);
    // O passageiro mudou o preço dele: recomeça-se a partir do novo valor.
    if (old.offer.fare != widget.offer.fare)
      _value = widget.offer.myBid ?? widget.offer.fare;
  }

  /// Serviço de preço combinado: o motorista diz o seu preço (ou aceita o do cliente).
  Widget _negotiated(Ride offer, DriverState driver) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        offer.priceOpen
            ? 'O cliente quer saber o seu preço para este serviço.'
            : 'O cliente propõe ${kz(offer.fare)}. Pode aceitar ou responder com o seu preço.',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      if (driver.notice != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            driver.notice!,
            style: const TextStyle(color: BazaColors.red),
          ),
        ),
      if (offer.myBid != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Propôs ${kz(offer.myBid!)}. A aguardar a resposta do cliente…',
            style: const TextStyle(color: BazaColors.muted),
          ),
        ),
      const SizedBox(height: 10),
      PriceInput(
        key: ValueKey('proposta-${offer.myBid}'),
        label: 'O seu preço para este serviço',
        initial: offer.myBid,
        action: (v) => 'Enviar proposta de ${kz(v)}',
        onSubmit: (v) => driver.bid(offer, v),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: AsyncButton(
              label: 'Recusar',
              outlined: true,
              onPressed: () => driver.decline(offer),
            ),
          ),
          if (!offer.priceOpen) ...[
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: AsyncButton(
                label: 'Aceitar · ${kz(offer.fare)}',
                onPressed: () => driver.accept(offer),
              ),
            ),
          ],
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer, driver = widget.driver;
    if (offer.negotiated) return _negotiated(offer, driver);
    final atPassengerPrice = _value == offer.fare;
    final alreadySent = offer.myBid != null && _value == offer.myBid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (driver.notice != null)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    driver.notice!,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Fechar',
                  onPressed: driver.clearNotice,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
        PriceStepper(
          value: _value,
          min: offer.fareMin ?? offer.fare,
          max: offer.fareMax ?? offer.fare,
          reference: offer.fare,
          referenceLabel: 'Preço do passageiro',
          onChanged: (v) => setState(() => _value = v),
        ),
        if (offer.myBid != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: BazaColors.muted,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Propôs ${kz(offer.myBid!)}. A aguardar a resposta do passageiro…',
                    style: const TextStyle(color: BazaColors.muted),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: AsyncButton(
                label: 'Recusar',
                outlined: true,
                onPressed: () => driver.decline(offer),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: atPassengerPrice
                  ? AsyncButton(
                      label: 'Aceitar · ${kz(offer.fare)}',
                      onPressed: () => driver.accept(offer),
                    )
                  : AsyncButton(
                      label: alreadySent
                          ? 'Proposta enviada'
                          : 'Propor ${kz(_value)}',
                      onPressed: alreadySent
                          ? null
                          : () => driver.bid(offer, _value),
                    ),
            ),
          ],
        ),
        if (!atPassengerPrice)
          TextButton(
            onPressed: () => setState(() => _value = offer.fare),
            child: Text('Voltar ao preço do passageiro (${kz(offer.fare)})'),
          ),
      ],
    );
  }
}

/// Abre a aplicação de mapas do telemóvel com a navegação até um ponto, para o
/// motorista ter indicações de condução por voz enquanto o Bazá fica em fundo.
class _NavigateButton extends StatelessWidget {
  const _NavigateButton({
    required this.label,
    required this.to,
    this.via = const [],
  });
  final String label;
  final Place to;
  final List<Place> via;

  Future<void> _open(BuildContext context) async {
    final uri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '${to.lat},${to.lng}',
      if (via.isNotEmpty)
        'waypoints': via.map((p) => '${p.lat},${p.lng}').join('|'),
      'travelmode': 'driving',
      'dir_action': 'navigate',
    });
    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (!ok && context.mounted)
      showError(context, 'Não foi possível abrir a navegação neste telemóvel.');
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
    onPressed: () => _open(context),
    icon: const Icon(Icons.navigation_outlined, size: 20),
    label: FittedBox(child: Text(label)),
  );
}

/// O que o motorista deve ao Bazá: a mensalidade da viatura (serviços de preço
/// combinado) ou as comissões das corridas em dinheiro. Tocar mostra o detalhe.
class _AccountNote extends StatelessWidget {
  const _AccountNote({required this.driver});
  final DriverState driver;

  @override
  Widget build(BuildContext context) {
    final user = context.watch<Session>().user;
    final vehicle = user?.vehicles.where((v) => v.active).firstOrNull;
    String? text, detail;
    var alert = false;
    switch (vehicle?.subscription) {
      case 'expired':
        alert = true;
        text = 'Mensalidade em atraso · ${kz(vehicle!.monthlyFee)} por mês';
        detail =
            'A mensalidade desta viatura terminou a ${date(vehicle.paidUntil!)}. Enquanto não for paga, não pode ficar online com ela.';
      case 'active':
        final days = vehicle!.paidUntil!.difference(DateTime.now()).inDays;
        alert = days < 5;
        text = days < 5
            ? 'Mensalidade termina a ${date(vehicle.paidUntil!)}'
            : 'Mensalidade em dia até ${date(vehicle.paidUntil!)}';
        detail =
            'Esta viatura combina o preço directamente com o cliente e não paga comissão por serviço. Paga uma mensalidade de ${kz(vehicle.monthlyFee)}.';
      case 'trial':
        text =
            'Mensalidade de ${kz(vehicle!.monthlyFee)} · período grátis ao ficar online';
        detail =
            'Esta viatura combina o preço directamente com o cliente e não paga comissão por serviço. A mensalidade é de ${kz(vehicle.monthlyFee)}; o período grátis começa quando ficar online pela primeira vez.';
      default:
        if (driver.commissionDue > 0) {
          alert =
              driver.commissionEnforced &&
              driver.commissionDue > driver.commissionLimit;
          text = 'Comissões por pagar: ${kz(driver.commissionDue)}';
          detail =
              'O Bazá fica com ${(driver.commissionRate * 100).toStringAsFixed(driver.commissionRate * 100 % 1 == 0 ? 0 : 1).replaceAll('.', ',')} % de cada corrida. Nas corridas pagas em dinheiro recebe o valor todo e a comissão fica por pagar.'
              '${driver.commissionEnforced ? ' Acima de ${kz(driver.commissionLimit)} em dívida, deixa de poder ficar online.' : ''}';
        }
    }
    if (text == null) return const SizedBox(height: 0);
    final color = alert ? BazaColors.red : BazaColors.muted;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // Abre o ecrã onde se vê o detalhe e se comunica o pagamento.
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const DriverAccountScreen())),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(
                alert
                    ? Icons.error_outline
                    : Icons.account_balance_wallet_outlined,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color: color,
                    fontWeight: alert ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
