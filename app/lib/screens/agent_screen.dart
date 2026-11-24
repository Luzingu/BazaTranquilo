import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../services/notifier.dart';
import '../state/session.dart';
import '../widgets/baza_map.dart';
import '../widgets/common.dart';

/// Área do agente de um posto policial. Abre-se sozinha quando o número com
/// que se entra está registado, no painel, como sendo de um agente.
///
/// O agente só vê uma corrida quando o passageiro ou o motorista acciona o
/// alerta de perigo, e só enquanto o alerta estiver aberto.
class AgentHome extends StatefulWidget {
  const AgentHome({super.key});

  @override
  State<AgentHome> createState() => _AgentHomeState();
}

typedef _Json = Map<String, dynamic>;

String _time(String iso) {
  final d = DateTime.parse(iso).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final today = d.year == now.year && d.month == now.month && d.day == now.day;
  return '${today ? 'hoje' : '${two(d.day)}/${two(d.month)}'}, ${two(d.hour)}:${two(d.minute)}';
}

Future<void> _open(BuildContext context, Uri uri, String fallback) async {
  final ok = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  ).catchError((_) => false);
  if (!ok && context.mounted) showError(context, fallback);
}

class _AgentHomeState extends State<AgentHome> {
  late final Session _session = context.read<Session>();
  List<_Json> _alerts = const [];
  Timer? _timer;
  Object? _error;
  bool _loaded = false;
  int _open = 0;
  AudioPlayer? _siren;

  _Json get _agent => _session.agent!;
  bool get _onDuty => _agent['onDuty'] == true;

  @override
  void initState() {
    super.initState();
    Notifier.instance.askPermission();
    _load();
    // Com o app aberto, os alertas chegam por esta verificação; fechado, por notificação.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _siren?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await _session.api.get('/agent/alerts');
      if (!mounted) return;
      final open = (res['open'] as num).toInt();
      // Alerta novo: sirene e vibração, mesmo com o ecrã noutro sítio do app.
      if (_loaded && open > _open) _alarm();
      _session.setAgent(res['agent'] as _Json);
      setState(() {
        _alerts = (res['alerts'] as List).cast<_Json>();
        _open = open;
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _alarm() {
    HapticFeedback.heavyImpact();
    try {
      final player = _siren ??= AudioPlayer();
      player
          .stop()
          .then((_) => player.play(AssetSource('sounds/alerta_perigo.wav')))
          .catchError((_) {});
    } catch (_) {}
  }

  Future<void> _setDuty(bool on) async {
    try {
      final res = await _session.api.post('/agent/duty', {'on': on});
      _session.setAgent(res['agent'] as _Json);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _logout() async {
    final sure = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sair?'),
        content: const Text(
          'Deixa de estar de serviço e de receber alertas neste telemóvel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Ficar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sair'),
          ),
        ],
      ),
    );
    if (sure == true) await _session.logout();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<Session>();
    final station = _agent['station'] as _Json;
    final rank = (_agent['rank'] as String?) ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              station['name'] as String,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            Text(
              '${rank.isEmpty ? '' : '$rank '}${_agent['name']}',
              style: const TextStyle(fontSize: 13, color: BazaColors.muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sair',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // De serviço ou não: só de serviço se recebem os alertas.
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              decoration: BoxDecoration(
                color: _onDuty
                    ? BazaColors.green.withValues(alpha: 0.12)
                    : BazaColors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _onDuty,
                onChanged: _setDuty,
                title: Text(
                  _onDuty ? 'Estou de serviço' : 'Fora de serviço',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: Text(
                  _onDuty
                      ? 'Recebe os alertas de perigo da zona do seu posto, mesmo com o app fechado.'
                      : 'Não recebe alertas. Ligue quando começar o turno.',
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (_open > 0)
              Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: BazaColors.red,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _open == 1
                            ? 'Há 1 alerta de perigo aberto'
                            : 'Há $_open alertas de perigo abertos',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const Text(
              'Alertas de perigo',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            if (!_loaded && _error == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && !_loaded)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(errorText(_error!), textAlign: TextAlign.center),
              )
            else if (_alerts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40, horizontal: 12),
                child: Text(
                  'Sem alertas. Quando um passageiro ou um motorista pedir ajuda na zona do seu posto, aparece aqui e o telemóvel toca.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: BazaColors.muted, fontSize: 15),
                ),
              ),
            for (final a in _alerts) _AlertTile(alert: a, onChanged: _load),
          ],
        ),
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.alert, required this.onChanged});
  final _Json alert;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final open = alert['open'] == true;
    final distance = (alert['distanceM'] as num?)?.toInt();
    final assigned = alert['assignedName'] as String?;
    final who = alert['role'] == 'driver' ? 'Motorista' : 'Passageiro';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: open
            ? BazaColors.red.withValues(alpha: 0.08)
            : BazaColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AgentAlertScreen(id: alert['id'] as String),
              ),
            );
            onChanged();
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(
                  open
                      ? Icons.warning_amber_rounded
                      : Icons.check_circle_outline,
                  color: open ? BazaColors.red : BazaColors.muted,
                  size: 30,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$who ${alert['name']}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${_time(alert['createdAt'] as String)}${distance != null ? ' · a ${km(distance)} do posto' : ''}',
                        style: const TextStyle(color: BazaColors.muted),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        !open
                            ? (alert['cancelledByUser'] == true
                                  ? 'Cancelado por quem o accionou'
                                  : 'Fechado por ${alert['closedBy'] ?? '—'}')
                            : assigned != null
                            ? 'Assumido por $assigned'
                            : alert['escalated'] == true
                            ? 'Sem resposta há mais de 2 minutos'
                            : 'Ninguém assumiu ainda',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: open && assigned == null
                              ? BazaColors.red
                              : BazaColors.ink,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: BazaColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Um alerta: mapa com a viatura em movimento, quem vai nela, e as acções do
/// agente (assumir, navegar, ligar, fechar com relato).
class AgentAlertScreen extends StatefulWidget {
  const AgentAlertScreen({
    super.key,
    required this.id,
    this.base = '/agent/alerts',
    this.friend = false,
  });
  final String id;

  /// De onde vêm os dados: a área do agente ou a da pessoa de confiança.
  final String base;

  /// Aberto pela pessoa de confiança de quem pediu ajuda: acompanha e ouve,
  /// mas não assume nem fecha o alerta (isso é com a polícia).
  final bool friend;

  @override
  State<AgentAlertScreen> createState() => _AgentAlertScreenState();
}

class _AgentAlertScreenState extends State<AgentAlertScreen> {
  late final Session _session = context.read<Session>();
  _Json? _alert;
  Object? _error;
  Timer? _timer;

  // Som da viagem, partilhado por quem pediu ajuda: toca-se bloco a bloco, à
  // medida que chegam ao servidor.
  final _player = AudioPlayer();
  bool _listening = false;
  int _nextSeq = 1;

  int get _audioLast => ((_alert?['audioLast'] as num?) ?? 0).toInt();

  /// Começa a ouvir: em directo (os últimos segundos) ou desde o início.
  Future<void> _listen({required bool fromStart}) async {
    if (_listening) return;
    setState(() {
      _listening = true;
      _nextSeq = fromStart ? 1 : (_audioLast > 1 ? _audioLast - 1 : 1);
    });
    var failures = 0;
    while (mounted && _listening) {
      if (_nextSeq > _audioLast) {
        // À espera do bloco seguinte (o alerta é actualizado de poucos em poucos segundos).
        if (_alert?['open'] != true) break;
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      try {
        final bytes = await _session.api.getBytes(
          '${widget.base}/${widget.id}/audio/$_nextSeq',
        );
        if (!mounted || !_listening) break;
        final done = _player.onPlayerComplete.first;
        await _player.play(BytesSource(bytes, mimeType: 'audio/wav'));
        await done.timeout(const Duration(seconds: 15), onTimeout: () {});
        failures = 0;
        if (mounted) setState(() => _nextSeq++);
      } catch (_) {
        // Bloco em falta ou falha de rede: tenta de novo e, à terceira, passa ao seguinte.
        if (++failures >= 3) {
          failures = 0;
          _nextSeq++;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    if (mounted) setState(() => _listening = false);
  }

  void _stopListening() {
    setState(() => _listening = false);
    _player.stop().catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _listening = false;
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await _session.api.get('${widget.base}/${widget.id}');
      if (mounted) {
        setState(() {
          _alert = res;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _alert == null) setState(() => _error = e);
    }
  }

  LatLng? _point(_Json? m) => m == null || m['lat'] == null
      ? null
      : LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble());

  Future<void> _assume() async {
    await _session.api.post('${widget.base}/${widget.id}/assume');
    await _load();
  }

  Future<void> _close() async {
    final note = TextEditingController();
    final done = await showModalBottomSheet<bool>(
      isDismissible: false,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Fechar o alerta',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'Escreva o que foi feito. Depois de fechado, deixa de ver esta corrida.',
              style: TextStyle(color: BazaColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              autofocus: true,
              maxLength: 300,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Ex.: patrulha no local; passageira em segurança.',
              ),
            ),
            const SizedBox(height: 8),
            AsyncButton(
              label: 'Fechar alerta',
              onPressed: () async {
                if (note.text.trim().length < 5)
                  throw 'Escreva o que foi feito.';
                await _session.api.post('${widget.base}/${widget.id}/close', {
                  'note': note.text.trim(),
                });
                if (context.mounted) Navigator.pop(context, true);
              },
            ),
          ],
        ),
      ),
    );
    if (done == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final a = _alert;
    if (a == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Alerta')),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(errorText(_error!), textAlign: TextAlign.center),
                ),
        ),
      );
    }
    final open = a['open'] == true;
    final ride = a['ride'] as _Json?;
    final by = a['by'] as _Json?;
    final live = _point(ride?['live'] as _Json?);
    final where = _point(a);
    final target = live ?? where;
    final vehicle = ride?['vehicle'] as _Json?;
    final assigned = a['assignedName'] as String?;
    const section = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: BazaColors.muted,
      letterSpacing: 0.4,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.friend
              ? (open ? 'Pedido de ajuda' : 'Pedido de ajuda terminado')
              : (open ? 'Alerta de perigo' : 'Alerta fechado'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          if (ride != null)
            SizedBox(
              height: 300,
              child: BazaMap(
                pickup: _point(ride['from'] as _Json?),
                dropoff: _point(ride['to'] as _Json?),
                driver: live,
                // O ponto onde o alerta foi accionado.
                alert: where,
                labels: true,
                follow: live,
                fitKey: widget.id,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: open
                        ? BazaColors.red.withValues(alpha: 0.1)
                        : BazaColors.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${a['role'] == 'driver' ? 'Motorista' : 'Passageiro'} ${a['name']} pediu ajuda',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${_time(a['createdAt'] as String)}${a['distanceM'] != null ? ' · a ${km((a['distanceM'] as num).toInt())} do posto' : ''}',
                      ),
                      if (!open)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            a['cancelledByUser'] == true
                                ? 'Cancelado por quem o accionou, com a senha.'
                                : 'Fechado por ${a['closedBy'] ?? '—'}: ${a['closeNote'] ?? ''}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        )
                      else if (assigned != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            a['mine'] == true
                                ? 'Assumido por si.'
                                : 'Assumido por $assigned.',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                    ],
                  ),
                ),
                if (open) ...[
                  const SizedBox(height: 12),
                  if (widget.friend)
                    Text(
                      assigned != null
                          ? 'A polícia já está a acompanhar: $assigned.'
                          : 'Os postos policiais mais próximos foram avisados. Pode ligar-lhe, ou ligar para a polícia.',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    )
                  else if (assigned == null)
                    AsyncButton(
                      label: 'Assumo este alerta',
                      onPressed: _assume,
                    ),
                  if (target != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => _open(
                        context,
                        Uri.parse(
                          'https://www.google.com/maps/dir/?api=1&destination=${target.latitude},${target.longitude}&travelmode=driving',
                        ),
                        'Não foi possível abrir a navegação.',
                      ),
                      icon: const Icon(Icons.navigation_outlined),
                      label: Text(
                        live != null
                            ? 'Navegar até à viatura'
                            : 'Navegar até ao local do alerta',
                      ),
                    ),
                  ],
                ],
                if (open && _audioLast > 0) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                    decoration: BoxDecoration(
                      color: BazaColors.ink,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _listening ? Icons.graphic_eq : Icons.mic,
                          color: BazaColors.yellow,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Som da viagem',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                _listening
                                    ? 'A ouvir · ${minutes(_nextSeq * 8)} de gravação'
                                    : 'Partilhado por quem pediu ajuda · ${minutes(_audioLast * 8)}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_listening)
                          TextButton(
                            onPressed: _stopListening,
                            child: const Text(
                              'Parar',
                              style: TextStyle(color: Colors.white),
                            ),
                          )
                        else ...[
                          TextButton(
                            onPressed: () => _listen(fromStart: true),
                            child: const Text(
                              'Do início',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 40),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                            ),
                            onPressed: () => _listen(fromStart: false),
                            child: const Text('Ouvir'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (vehicle != null) ...[
                  const SizedBox(height: 18),
                  const Text('VIATURA', style: section),
                  const SizedBox(height: 4),
                  Text(
                    '${vehicle['plate']}',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                  Text('${vehicle['label']} · ${vehicle['color']}'),
                ],
                if (ride != null) ...[
                  const SizedBox(height: 18),
                  const Text('PERCURSO', style: section),
                  const SizedBox(height: 4),
                  Text(
                    '${(ride['from'] as _Json)['address']} → ${(ride['to'] as _Json?)?['address'] ?? 'destino a combinar'}',
                  ),
                  const SizedBox(height: 18),
                  const Text('QUEM VAI NA VIATURA', style: section),
                  _Person(label: 'Motorista', person: ride['driver'] as _Json?),
                  _Person(
                    label: 'Passageiro',
                    person: ride['passenger'] as _Json?,
                  ),
                ] else if (by != null && open)
                  _Person(label: 'Quem pediu ajuda', person: by)
                else if (!open)
                  const Padding(
                    padding: EdgeInsets.only(top: 18),
                    child: Text(
                      'O alerta está fechado: os dados da corrida já não estão disponíveis.',
                      style: TextStyle(color: BazaColors.muted),
                    ),
                  ),
                if (open && !widget.friend) ...[
                  const SizedBox(height: 22),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BazaColors.red,
                      side: const BorderSide(color: BazaColors.red),
                    ),
                    onPressed: _close,
                    child: const Text('Fechar o alerta'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Person extends StatelessWidget {
  const _Person({required this.label, required this.person});
  final String label;
  final _Json? person;

  @override
  Widget build(BuildContext context) {
    final p = person;
    if (p == null) return const SizedBox.shrink();
    final phone = p['phone'] as String?;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: BazaColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: BazaColors.muted, fontSize: 13),
                ),
                Text(
                  '${p['name']}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (phone != null) Text(phone),
              ],
            ),
          ),
          if (phone != null)
            IconButton.filled(
              tooltip: 'Ligar a ${p['name']}',
              style: IconButton.styleFrom(
                backgroundColor: BazaColors.green,
                foregroundColor: Colors.white,
              ),
              onPressed: () => _open(
                context,
                Uri(scheme: 'tel', path: phone),
                'Ligue para $phone.',
              ),
              icon: const Icon(Icons.call),
            ),
        ],
      ),
    );
  }
}
