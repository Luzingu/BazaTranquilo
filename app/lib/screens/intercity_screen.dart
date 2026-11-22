import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../services/notifier.dart';
import '../state/session.dart';
import '../widgets/common.dart';

/// Táxi intermunicipal. As rotas e os preços vêm do painel. O motorista
/// publica uma viagem (dia, hora, lugares, preço por passageiro, nota sobre a
/// carga) e os passageiros reservam lugares; cada reserva que o motorista
/// confirma reduz os lugares livres.
class IntercityScreen extends StatefulWidget {
  const IntercityScreen({super.key});

  @override
  State<IntercityScreen> createState() => _IntercityScreenState();
}

typedef _Json = Map<String, dynamic>;

String _seats(int n) => n == 1 ? '1 lugar' : '$n lugares';

/// "amanhã, 07:30", "hoje, 15:00" ou "25/11, 06:00".
String _when(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final days = DateTime(
    d.year,
    d.month,
    d.day,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
  final time = '${two(d.hour)}:${two(d.minute)}';
  return switch (days) {
    0 => 'hoje, $time',
    1 => 'amanhã, $time',
    _ => '${two(d.day)}/${two(d.month)}, $time',
  };
}

DateTime _depart(_Json trip) =>
    DateTime.parse(trip['departAt'] as String).toLocal();

Future<void> _call(BuildContext context, String phone) async {
  final ok = await launchUrl(Uri(scheme: 'tel', path: phone));
  if (!ok && context.mounted) showError(context, 'Ligue para $phone.');
}

class _IntercityScreenState extends State<IntercityScreen> {
  List<_Json> _routes = const [];
  List<String> _places = const [];
  List<_Json> _trips = const [];
  List<_Json> _mine = const [];
  double _commissionRate = 0;
  String? _from, _to;
  bool _loading = true;
  Object? _error;

  late final Session _session = context.read<Session>();
  bool get _isDriver => _session.user?.isDriver ?? false;

  @override
  void initState() {
    super.initState();
    _session.on('intercity:update', _onUpdate);
    _load();
  }

  @override
  void dispose() {
    _session.off('intercity:update', _onUpdate);
    super.dispose();
  }

  void _onUpdate(dynamic data) {
    if (!mounted) return;
    if (data is Map && data['title'] is String) {
      final text = '${data['title']}. ${data['body'] ?? ''}';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
        );
      Notifier.instance.show(
        Notifier.rideId,
        data['title'] as String,
        '${data['body'] ?? ''}',
      );
    }
    _load(quiet: true);
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final api = _session.api;
      final results = await Future.wait([
        api.get('/intercity/routes'),
        api.get('/intercity/trips', {'from': ?_from, 'to': ?_to}),
        api.get('/intercity/trips/mine'),
      ]);
      if (!mounted) return;
      List<_Json> list(_Json m, String key) =>
          (m[key] as List).cast<_Json>().toList();
      setState(() {
        _routes = list(results[0], 'routes');
        _places = (results[0]['places'] as List).cast<String>();
        _commissionRate = (results[0]['commissionRate'] as num).toDouble();
        _trips = list(results[1], 'trips');
        _mine = list(results[2], 'trips');
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  /// Corre uma acção sobre uma viagem e actualiza as listas.
  Future<void> _act(Future<_Json> Function() action) async {
    clearError(context);
    try {
      await action();
      await _load(quiet: true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _publish() async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _PublishSheet(routes: _routes, commissionRate: _commissionRate),
    );
    if (done == true) _load(quiet: true);
  }

  Future<void> _book(_Json trip) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BookSheet(trip: trip),
    );
    if (done == true) _load(quiet: true);
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Voltar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _setStatus(_Json trip, String status) async {
    final (title, text, action) = switch (status) {
      'departed' => (
        'Partir agora?',
        'As reservas por confirmar deixam de contar e a viagem sai da lista.',
        'Partir',
      ),
      'completed' => (
        'Concluir a viagem?',
        'Confirme que chegou a ${trip['to']} com os passageiros.',
        'Concluir',
      ),
      _ => (
        'Cancelar a viagem?',
        'Os passageiros com reserva são avisados.',
        'Cancelar viagem',
      ),
    };
    if (!await _confirm(title, text, action)) return;
    await _act(
      () => _session.api.post('/intercity/trips/${trip['id']}/status', {
        'status': status,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _mine.fold<int>(
      0,
      (n, t) => n + ((t['pending'] as num?)?.toInt() ?? 0),
    );
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Viagens entre municípios'),
          bottom: TabBar(
            labelColor: BazaColors.ink,
            indicatorColor: BazaColors.ink,
            tabs: [
              Tab(
                text: _isDriver
                    ? 'As minhas viagens${pending > 0 ? ' ($pending)' : ''}'
                    : 'Procurar viagem',
              ),
              Tab(text: _isDriver ? 'Todas' : 'As minhas reservas'),
            ],
          ),
        ),
        floatingActionButton: _isDriver && _routes.isNotEmpty
            ? FloatingActionButton.extended(
                onPressed: _publish,
                backgroundColor: BazaColors.yellow,
                foregroundColor: BazaColors.ink,
                icon: const Icon(Icons.add_road),
                label: const Text('Publicar viagem'),
              )
            : null,
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _Empty(
                icon: Icons.cloud_off,
                text: errorText(_error!),
                action: 'Tentar de novo',
                onAction: _load,
              )
            : TabBarView(
                children: _isDriver
                    ? [_list(_mine, mine: true), _list(_trips, search: true)]
                    : [_list(_trips, search: true), _list(_mine, mine: true)],
              ),
      ),
    );
  }

  Widget _list(List<_Json> trips, {bool mine = false, bool search = false}) {
    final empty = _routes.isEmpty
        ? 'Ainda não há rotas entre municípios. A equipa do Bazá está a prepará-las.'
        : mine
        ? (_isDriver
              ? 'Ainda não publicou nenhuma viagem. Toque em "Publicar viagem" para indicar a rota, o dia e os lugares.'
              : 'Ainda não reservou nenhuma viagem.')
        : 'Não há viagens publicadas para esta procura. Volte mais tarde ou experimente outra rota.';
    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          if (search && _places.isNotEmpty) _filters(),
          if (trips.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 60),
              child: _Empty(icon: Icons.airport_shuttle_outlined, text: empty),
            ),
          for (final t in trips)
            _TripCard(
              trip: t,
              onBook: () => _book(t),
              onCancelBooking: () async {
                if (!await _confirm(
                  'Desistir da reserva?',
                  'O lugar volta a ficar livre para outros passageiros.',
                  'Desistir',
                )) {
                  return;
                }
                await _act(
                  () => _session.api.post(
                    '/intercity/trips/${t['id']}/bookings/mine/cancel',
                  ),
                );
              },
              onBooking: (booking, action) => _act(
                () => _session.api.post(
                  '/intercity/trips/${t['id']}/bookings/${booking['id']}',
                  {'action': action},
                ),
              ),
              onSeats: (seats) => _act(
                () => _session.api.patch('/intercity/trips/${t['id']}', {
                  'seats': seats,
                }),
              ),
              onStatus: (status) => _setStatus(t, status),
            ),
        ],
      ),
    );
  }

  Widget _filters() {
    DropdownMenuItem<String?> item(String? v) =>
        DropdownMenuItem(value: v, child: Text(v ?? 'Qualquer'));
    Widget pick(String label, String? value, ValueChanged<String?> set) =>
        Expanded(
          child: DropdownButtonFormField<String?>(
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: label),
            items: [item(null), for (final p in _places) item(p)],
            onChanged: (v) {
              set(v);
              _load(quiet: true);
            },
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Row(
        children: [
          pick('De', _from, (v) => _from = v),
          const SizedBox(width: 10),
          pick('Para', _to, (v) => _to = v),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: BazaColors.muted),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: BazaColors.muted, fontSize: 15),
          ),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    ),
  );
}

/// Botão pequeno para usar dentro de linhas (o tema dá largura total aos botões).
final _small = FilledButton.styleFrom(
  minimumSize: const Size(0, 40),
  padding: const EdgeInsets.symmetric(horizontal: 16),
  textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
);
final _smallOutlined = OutlinedButton.styleFrom(
  minimumSize: const Size(0, 40),
  padding: const EdgeInsets.symmetric(horizontal: 14),
  textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
);

class _TripCard extends StatelessWidget {
  const _TripCard({
    required this.trip,
    required this.onBook,
    required this.onCancelBooking,
    required this.onBooking,
    required this.onSeats,
    required this.onStatus,
  });
  final _Json trip;
  final VoidCallback onBook, onCancelBooking;
  final void Function(_Json booking, String action) onBooking;
  final ValueChanged<int> onSeats;
  final ValueChanged<String> onStatus;

  @override
  Widget build(BuildContext context) {
    final isDriver = context.read<Session>().user?.isDriver ?? false;
    final mine = trip['mine'] == true;
    final status = trip['status'] as String;
    final left = (trip['seatsLeft'] as num).toInt();
    final seats = (trip['seats'] as num).toInt();
    final price = (trip['price'] as num).round();
    final vehicle = trip['vehicle'] as _Json?;
    final driver = trip['driver'] as _Json;
    final my = trip['myBooking'] as _Json?;
    final note = (trip['note'] as String?) ?? '';
    final meeting = (trip['meetingPoint'] as String?) ?? '';
    final bookings = ((trip['bookings'] as List?) ?? const []).cast<_Json>();
    const muted = TextStyle(color: BazaColors.muted, fontSize: 13.5);

    final (String state, Color stateColor) = switch (status) {
      'departed' => ('Em viagem', BazaColors.green),
      'completed' => ('Concluída', BazaColors.muted),
      'cancelled' => ('Cancelada', BazaColors.red),
      _ =>
        left == 0
            ? ('Cheia', BazaColors.red)
            : (
                '${_seats(left)} livres'.replaceFirst(
                  'lugar livres',
                  'lugar livre',
                ),
                BazaColors.green,
              ),
    };

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BazaColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${trip['from']} → ${trip['to']}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                kz(price),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Partida ${_when(_depart(trip))}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const Text('por passageiro', style: muted),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  state,
                  style: TextStyle(
                    color: stateColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  mine
                      ? '${seats - left} de $seats confirmados'
                      : '${driver['name']}${vehicle?['label'] != null ? ' · ${vehicle!['label']}' : ''}',
                  style: muted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (!mine && vehicle?['plate'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${vehicle!['color'] ?? ''} · ${vehicle['plate']}',
                style: muted,
              ),
            ),
          if (meeting.isNotEmpty)
            _line(Icons.place_outlined, 'Encontro: $meeting'),
          if (note.isNotEmpty) _line(Icons.luggage_outlined, note),

          // ── Passageiro ───────────────────────────────────────────────────
          if (!isDriver && my != null) ...[
            const Divider(height: 22),
            _myBooking(context, my, price, driver['phone'] as String?, status),
          ] else if (!isDriver && status == 'open') ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                style: _small,
                onPressed: left > 0 ? onBook : null,
                child: Text(left > 0 ? 'Reservar lugar' : 'Sem lugares'),
              ),
            ),
          ],

          // ── Motorista, na sua viagem ─────────────────────────────────────
          if (mine) ...[
            if (bookings.isNotEmpty) const Divider(height: 22),
            for (final b in bookings) _booking(context, b, price, status),
            if (status == 'open') ...[
              const Divider(height: 22),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Lugares pelo app',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Menos um lugar (ex.: vendido fora do app)',
                    onPressed: seats > 1 && left > 0
                        ? () => onSeats(seats - 1)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text(
                    '$seats',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Mais um lugar',
                    onPressed: () => onSeats(seats + 1),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              Row(
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: BazaColors.red,
                    ),
                    onPressed: () => onStatus('cancelled'),
                    child: const Text('Cancelar viagem'),
                  ),
                  const Spacer(),
                  FilledButton(
                    style: _small,
                    onPressed: () => onStatus('departed'),
                    child: const Text('Partir'),
                  ),
                ],
              ),
            ] else if (status == 'departed') ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  style: _small,
                  onPressed: () => onStatus('completed'),
                  child: const Text('Concluir viagem'),
                ),
              ),
            ] else if (status == 'completed' &&
                ((trip['commission'] as num?) ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Comissão do Bazá: ${kz((trip['commission'] as num).round())}',
                  style: muted,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: BazaColors.muted),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );

  /// A reserva do passageiro nesta viagem.
  Widget _myBooking(
    BuildContext context,
    _Json my,
    int price,
    String? driverPhone,
    String tripStatus,
  ) {
    final seats = (my['seats'] as num).toInt();
    final (String text, Color color) = switch (my['status']) {
      'confirmed' => ('Reserva confirmada', BazaColors.green),
      'rejected' => ('Reserva não aceite pelo motorista', BazaColors.red),
      _ => ('À espera da confirmação do motorista', const Color(0xFFB45309)),
    };
    final active = my['status'] == 'pending' || my['status'] == 'confirmed';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          '${_seats(seats)} · ${kz(seats * price)} a pagar ao motorista, em dinheiro',
        ),
        if (active)
          Row(
            children: [
              if (tripStatus == 'open')
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: BazaColors.red),
                  onPressed: onCancelBooking,
                  child: const Text('Desistir'),
                ),
              const Spacer(),
              if (driverPhone != null)
                OutlinedButton.icon(
                  style: _smallOutlined,
                  onPressed: () => _call(context, driverPhone),
                  icon: const Icon(Icons.call, size: 18),
                  label: const Text('Ligar ao motorista'),
                ),
            ],
          ),
      ],
    );
  }

  /// Uma reserva, vista pelo motorista.
  Widget _booking(BuildContext context, _Json b, int price, String tripStatus) {
    final seats = (b['seats'] as num).toInt();
    final status = b['status'] as String;
    final phone = b['phone'] as String?;
    final note = (b['note'] as String?) ?? '';
    final (String label, Color color) = switch (status) {
      'confirmed' => ('Confirmada', BazaColors.green),
      'rejected' => ('Recusada', BazaColors.muted),
      _ => ('Por confirmar', const Color(0xFFB45309)),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${b['name']} · ${_seats(seats)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          Text(
            '${kz(seats * price)}${note.isEmpty ? '' : ' · $note'}',
            style: const TextStyle(color: BazaColors.muted, fontSize: 13.5),
          ),
          if (tripStatus == 'open' || phone != null)
            Row(
              children: [
                if (phone != null)
                  IconButton(
                    tooltip: 'Ligar a ${b['name']}',
                    onPressed: () => _call(context, phone),
                    icon: const Icon(Icons.call),
                  ),
                const Spacer(),
                if (tripStatus == 'open' && status != 'rejected')
                  TextButton(
                    onPressed: () => onBooking(b, 'reject'),
                    child: Text(status == 'confirmed' ? 'Retirar' : 'Recusar'),
                  ),
                if (tripStatus == 'open' && status != 'confirmed') ...[
                  const SizedBox(width: 6),
                  FilledButton(
                    style: _small,
                    onPressed: () => onBooking(b, 'confirm'),
                    child: const Text('Confirmar'),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

Widget _sheet(BuildContext context, String title, List<Widget> children) =>
    Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              ...children,
            ],
          ),
        ),
      ),
    );

Widget _counter(
  String label,
  int value,
  int min,
  int max,
  ValueChanged<int> set,
) => Row(
  children: [
    Expanded(
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    ),
    IconButton(
      onPressed: value > min ? () => set(value - 1) : null,
      icon: const Icon(Icons.remove_circle_outline),
    ),
    SizedBox(
      width: 34,
      child: Text(
        '$value',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
    ),
    IconButton(
      onPressed: value < max ? () => set(value + 1) : null,
      icon: const Icon(Icons.add_circle_outline),
    ),
  ],
);

/// Passageiro: reservar lugares numa viagem.
class _BookSheet extends StatefulWidget {
  const _BookSheet({required this.trip});
  final _Json trip;

  @override
  State<_BookSheet> createState() => _BookSheetState();
}

class _BookSheetState extends State<_BookSheet> {
  int _count = 1;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trip;
    final left = (t['seatsLeft'] as num).toInt();
    final price = (t['price'] as num).round();
    final tripNote = (t['note'] as String?) ?? '';
    return _sheet(context, '${t['from']} → ${t['to']}', [
      Text('Partida ${_when(_depart(t))} · ${kz(price)} por passageiro'),
      if (tripNote.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            tripNote,
            style: const TextStyle(color: BazaColors.muted),
          ),
        ),
      const SizedBox(height: 10),
      _counter('Quantos lugares?', _count, 1, left, (v) {
        setState(() => _count = v);
      }),
      const SizedBox(height: 6),
      TextField(
        controller: _note,
        maxLength: 200,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Bagagem ou recado (opcional)',
          hintText: 'Ex.: levo duas malas grandes',
          counterText: '',
        ),
      ),
      const SizedBox(height: 14),
      Text(
        'Total: ${kz(_count * price)}',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
      const Text(
        'Paga ao motorista, em dinheiro. A carga extra combina-se com ele. O lugar fica garantido quando o motorista confirmar.',
        style: TextStyle(color: BazaColors.muted, fontSize: 13),
      ),
      const SizedBox(height: 14),
      AsyncButton(
        label: 'Pedir reserva',
        onPressed: () async {
          await context.read<Session>().api.post(
            '/intercity/trips/${t['id']}/bookings',
            {'seats': _count, 'note': _note.text.trim()},
          );
          if (context.mounted) Navigator.pop(context, true);
        },
      ),
    ]);
  }
}

/// Motorista: publicar uma viagem numa das rotas definidas no painel.
class _PublishSheet extends StatefulWidget {
  const _PublishSheet({required this.routes, required this.commissionRate});
  final List<_Json> routes;
  final double commissionRate;

  @override
  State<_PublishSheet> createState() => _PublishSheetState();
}

class _PublishSheetState extends State<_PublishSheet> {
  /// Cada rota aparece nos dois sentidos.
  late final _options = [
    for (final r in widget.routes) ...[
      (route: r, reverse: false, label: '${r['from']} → ${r['to']}'),
      (route: r, reverse: true, label: '${r['to']} → ${r['from']}'),
    ],
  ];
  int _option = 0;
  late DateTime _day = DateTime.now().add(const Duration(days: 1));
  TimeOfDay _time = const TimeOfDay(hour: 6, minute: 0);
  int _seats = 4;
  late int _price = _routePrice;
  final _meeting = TextEditingController();
  final _note = TextEditingController();

  _Json get _route => _options[_option].route;
  int get _routePrice => (_route['price'] as num).round();
  int get _min => (_route['min'] as num).round();
  int get _max => (_route['max'] as num).round();

  @override
  void dispose() {
    _meeting.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
      helpText: 'Dia da viagem',
    );
    if (picked != null) setState(() => _day = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
      helpText: 'Hora da partida',
    );
    if (picked != null) setState(() => _time = picked);
  }

  @override
  Widget build(BuildContext context) {
    final depart = DateTime(
      _day.year,
      _day.month,
      _day.day,
      _time.hour,
      _time.minute,
    );
    final fixed = _min == _max;
    final fee = (_seats * _price * widget.commissionRate).round();
    return _sheet(context, 'Publicar viagem', [
      DropdownButtonFormField<int>(
        initialValue: _option,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Rota'),
        items: [
          for (final (i, o) in _options.indexed)
            DropdownMenuItem(value: i, child: Text(o.label)),
        ],
        onChanged: (v) => setState(() {
          _option = v ?? 0;
          _price = _routePrice;
        }),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _pickDay,
              icon: const Icon(Icons.event),
              label: Text(dateOnly(_day)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _pickTime,
              icon: const Icon(Icons.schedule),
              label: Text(
                '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        'Partida ${_when(depart)}',
        style: const TextStyle(color: BazaColors.muted),
      ),
      const SizedBox(height: 8),
      _counter('Lugares a preencher pelo app', _seats, 1, 60, (v) {
        setState(() => _seats = v);
      }),
      const SizedBox(height: 8),
      if (fixed)
        Text(
          'Preço por passageiro: ${kz(_price)} (definido pelo Bazá para esta rota)',
          style: const TextStyle(fontWeight: FontWeight.w600),
        )
      else ...[
        const Text(
          'Preço por passageiro',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        PriceStepper(
          value: _price,
          min: _min,
          max: _max,
          reference: _routePrice,
          referenceLabel: 'Preço da rota',
          onChanged: (v) => setState(() => _price = v),
        ),
      ],
      const SizedBox(height: 12),
      TextField(
        controller: _meeting,
        maxLength: 120,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Ponto de encontro',
          hintText: 'Ex.: paragem junto ao mercado municipal',
          counterText: '',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _note,
        maxLength: 300,
        maxLines: 2,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Carga e outras condições (opcional)',
          hintText: 'Ex.: mala grande 1 000 Kz; saco de 50 kg 2 000 Kz',
          counterText: '',
        ),
      ),
      if (widget.commissionRate > 0)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            'Com os $_seats lugares confirmados recebe ${kz(_seats * _price)}; a comissão do Bazá seria ${kz(fee)}. Só contam os lugares confirmados no app.',
            style: const TextStyle(color: BazaColors.muted, fontSize: 13),
          ),
        ),
      const SizedBox(height: 14),
      AsyncButton(
        label: 'Publicar',
        onPressed: () async {
          if (_meeting.text.trim().length < 3) {
            throw 'Indique o ponto de encontro com os passageiros.';
          }
          await context.read<Session>().api.post('/intercity/trips', {
            'routeId': _route['id'],
            'reverse': _options[_option].reverse,
            'departAt': depart.toUtc().toIso8601String(),
            'seats': _seats,
            'price': _price,
            'meetingPoint': _meeting.text.trim(),
            'note': _note.text.trim(),
          });
          if (context.mounted) Navigator.pop(context, true);
        },
      ),
    ]);
  }
}
