import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/ride_state.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import 'place_search.dart';

/// Pedido de um serviço de preço combinado: triciclo, XL, carrinha ou camião.
/// Não há tarifa calculada — o cliente descreve o que precisa, os motoristas
/// propõem o preço e o destino é opcional.
class NegotiatedRequestScreen extends StatefulWidget {
  const NegotiatedRequestScreen({
    super.key,
    this.near,
    this.pickup,
    this.dropoff,
  });
  final LatLng? near;
  final Place? pickup, dropoff;

  @override
  State<NegotiatedRequestScreen> createState() =>
      _NegotiatedRequestScreenState();
}

class _NegotiatedRequestScreenState extends State<NegotiatedRequestScreen> {
  final _note = TextEditingController();
  final _price = TextEditingController();
  final _submitKey = GlobalKey<AsyncButtonState>();
  late Place? _pickup = widget.pickup;
  late Place? _dropoff = widget.dropoff;

  List<FareOption>? _services;
  String? _error;
  String? _category;
  int _helpers = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final res = await context.read<Session>().api.get('/catalog');
      final all = [
        for (final s in res['services'] as List)
          if ((s as Map)['negotiated'] == true)
            FareOption.fromJson(Map<String, dynamic>.from(s)),
      ];
      if (!mounted) return;
      setState(() {
        _services = all;
        _category ??= all.firstOrNull?.category;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  FareOption? get _selected =>
      _services?.where((s) => s.category == _category).firstOrNull;

  Future<void> _choose({required bool pickup}) async {
    final place = await Navigator.of(context).push<Place>(
      MaterialPageRoute(
        builder: (_) => PlaceSearchScreen(
          title: pickup ? 'Onde é o serviço?' : 'Destino (opcional)',
          near: widget.near,
          offerCurrentLocation: pickup,
        ),
      ),
    );
    if (place == null || !mounted) return;
    setState(() => pickup ? _pickup = place : _dropoff = place);
  }

  Future<void> _send() async {
    final pickup = _pickup, service = _selected;
    if (service == null) throw 'Escolha o tipo de viatura.';
    if (pickup == null) throw 'Indique onde é o serviço.';
    final note = _note.text.trim();
    if (note.length < 3) throw 'Descreva o serviço que precisa.';
    final offered = int.tryParse(_price.text.replaceAll(RegExp(r'\D'), ''));
    if (offered != null && offered % 50 != 0)
      throw 'O preço tem de ser múltiplo de 50 Kz.';
    final rides = context.read<RideState>();
    final navigator = Navigator.of(context);
    final res = await context.read<Session>().api.post('/rides', {
      'pickup': pickup.toJson(),
      if (_dropoff != null) 'dropoff': _dropoff!.toJson(),
      'category': service.category,
      'paymentMethod': 'cash',
      'cargoNote': note,
      if (service.helpers) 'helpers': _helpers,
      if (offered != null && offered > 0) 'offeredFare': offered,
    });
    rides.setRide(Ride.fromJson(res['ride'] as Map<String, dynamic>));
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    const section = TextStyle(fontWeight: FontWeight.w700, fontSize: 16);
    final services = _services;
    final selected = _selected;
    return Scaffold(
      appBar: AppBar(title: const Text('Serviço por combinar')),
      body: services == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: BazaColors.ink)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Tentar novamente'),
                        ),
                      ],
                    ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                const Text(
                  'Diga o que precisa e receba propostas de preço dos motoristas. Escolhe a que preferir.',
                  style: TextStyle(color: BazaColors.muted),
                ),
                const SizedBox(height: 16),
                const Text('Tipo de viatura', style: section),
                const SizedBox(height: 8),
                for (final s in services)
                  _ServiceTile(
                    service: s,
                    selected: s.category == _category,
                    onTap: () => setState(() {
                      _category = s.category;
                      if (!s.helpers) _helpers = 0;
                    }),
                  ),
                const SizedBox(height: 14),
                const Text('O que precisa?', style: section),
                const SizedBox(height: 8),
                TextField(
                  controller: _note,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 200,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: selected?.group == 'cargo'
                        ? 'Ex.: mudança de um T2; levar 20 sacos de cimento; frete por meio dia'
                        : 'Ex.: levar 5 pessoas ao aeroporto com bagagem; aluguer por 2 horas',
                    counterText: '',
                  ),
                ),
                if (selected?.helpers ?? false) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Ajudantes para carregar',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Menos um ajudante',
                        onPressed: _helpers > 0
                            ? () => setState(() => _helpers--)
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '$_helpers',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Mais um ajudante',
                        onPressed: _helpers < 3
                            ? () => setState(() => _helpers++)
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                const Text('Onde', style: section),
                const SizedBox(height: 8),
                _PlaceRow(
                  icon: Icons.trip_origin,
                  color: BazaColors.green,
                  text:
                      _pickup?.address ??
                      'Onde é o serviço? (ponto de recolha)',
                  onTap: () => _choose(pickup: true),
                ),
                const SizedBox(height: 8),
                _PlaceRow(
                  icon: Icons.flag_outlined,
                  color: BazaColors.red,
                  text:
                      _dropoff?.address ??
                      'Destino (opcional) — pode combinar com o motorista',
                  onTap: () => _choose(pickup: false),
                  onClear: _dropoff == null
                      ? null
                      : () => setState(() => _dropoff = null),
                ),
                const SizedBox(height: 18),
                const Text('Preço', style: section),
                const SizedBox(height: 8),
                TextField(
                  controller: _price,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(7),
                  ],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submitKey.currentState?.trigger(),
                  decoration: const InputDecoration(
                    labelText: 'Quanto propõe pagar? (opcional)',
                    suffixText: 'Kz',
                    helperText: 'Deixe vazio para os motoristas dizerem o preço. Paga-se em dinheiro ao motorista.',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 20),
                AsyncButton(
                  key: _submitKey,
                  label: 'Pedir propostas',
                  onPressed: _send,
                ),
              ],
            ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.service,
    required this.selected,
    required this.onTap,
  });
  final FareOption service;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: selected ? const Color(0xFFFFF4CC) : BazaColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? BazaColors.ink : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                categoryIcons[service.category] ??
                    Icons.local_shipping_outlined,
                size: 28,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      service.details,
                      style: const TextStyle(
                        color: BazaColors.muted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle, color: BazaColors.ink),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.icon,
    required this.color,
    required this.text,
    required this.onTap,
    this.onClear,
  });
  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => Material(
    color: BazaColors.surface,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ),
            if (onClear != null)
              IconButton(
                tooltip: 'Sem destino',
                onPressed: onClear,
                icon: const Icon(Icons.close, size: 20),
              )
            else
              const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.chevron_right, color: BazaColors.muted),
              ),
          ],
        ),
      ),
    ),
  );
}
