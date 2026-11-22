import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/format.dart';
import '../core/location.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../services/alert_audio.dart';
import '../state/session.dart';
import 'common.dart';

/// Número de emergência (polícia, em Angola). O servidor confirma-o na resposta do SOS.
const emergencyNumber = '111';

/// Cria o link público para acompanhar a corrida em directo.
Future<String> _shareLink(BuildContext context, Ride ride) async {
  final res = await context.read<Session>().api.post('/rides/${ride.id}/share');
  return res['url'] as String;
}

String _shareText(String url) =>
    'Acompanhe a minha viagem no Bazá em tempo real: $url';

/// Abre a folha de partilha do telemóvel com o link da viagem. Onde não houver
/// partilha (alguns browsers), copia o link.
Future<void> shareRide(BuildContext context, Ride ride) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final url = await _shareLink(context, ride);
    try {
      await SharePlus.instance.share(
        ShareParams(text: _shareText(url), subject: 'A minha viagem no Bazá'),
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Link da viagem copiado. Cole-o numa mensagem.'),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Botões de segurança mostrados durante a corrida: partilhar a viagem e SOS.
class SafetyBar extends StatelessWidget {
  const SafetyBar({super.key, required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: () => shareRide(context, ride),
            icon: const Icon(Icons.ios_share, size: 20),
            label: const FittedBox(child: Text('Partilhar viagem')),
          ),
        ),
        const SizedBox(width: 10),
        Semantics(
          button: true,
          label: 'SOS, emergência',
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: BazaColors.red,
              foregroundColor: Colors.white,
              minimumSize: const Size(104, 46),
            ),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: Colors.white,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (_) => _SosSheet(ride: ride),
            ),
            icon: const Icon(Icons.sos, size: 22),
            label: const Text('SOS'),
          ),
        ),
      ],
    );
  }
}

class _SosSheet extends StatefulWidget {
  const _SosSheet({required this.ride});
  final Ride ride;

  @override
  State<_SosSheet> createState() => _SosSheetState();
}

class _SosSheetState extends State<_SosSheet> {
  bool _alertSent = false;
  bool _busy = false;

  /// As autoridades foram avisadas por este ecrã (mostra a confirmação).
  bool _authoritiesAlerted = false;

  /// O estado do alerta no servidor: postos avisados e quem o assumiu.
  Map<String, dynamic>? _status;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    // Se já havia um alerta aberto nesta corrida, mostra logo o estado dele.
    _refreshStatus();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      final res = await context.read<Session>().api.get(
        '/rides/${widget.ride.id}/sos',
      );
      if (!mounted) return;
      final alert = res['alert'] as Map<String, dynamic>?;
      setState(() {
        _status = alert;
        if (alert != null && alert['open'] == true) {
          _authoritiesAlerted = true;
          _alertSent = true;
        }
      });
      if (alert != null && alert['open'] == true) {
        _statusTimer ??= Timer.periodic(
          const Duration(seconds: 6),
          (_) => _refreshStatus(),
        );
      } else {
        _statusTimer?.cancel();
        _statusTimer = null;
        // Alerta fechado ou cancelado: deixa de se partilhar o som.
        AlertAudio.instance.stop();
      }
    } catch (_) {
      // Sem rede: fica o que já se sabe.
    }
  }

  /// Foi engano: cancela o alerta, com a senha, para ninguém o fazer por si.
  Future<void> _cancelAlert() async {
    final password = TextEditingController();
    final done = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar o alerta'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Só cancele se foi engano. Escreva a sua senha para confirmar.',
            ),
            const SizedBox(height: 12),
            PasswordField(controller: password, autofocus: true),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Manter o alerta'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancelar alerta'),
          ),
        ],
      ),
    );
    if (done != true || !mounted) return;
    try {
      await context.read<Session>().api.post(
        '/rides/${widget.ride.id}/sos/cancel',
        {'password': password.text},
      );
      if (!mounted) return;
      setState(() {
        _authoritiesAlerted = false;
        _alertSent = false;
      });
      await _refreshStatus();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Regista o alerta no servidor (com a posição, se houver). Não bloqueia a
  /// chamada: numa emergência o telefone abre mesmo sem rede.
  void _recordAlert() {
    if (_alertSent) return;
    _alertSent = true;
    final api = context.read<Session>().api;
    final rideId = widget.ride.id;
    () async {
      final here = await currentLatLng();
      await api.post('/rides/$rideId/sos', {
        if (here != null) 'lat': here.latitude,
        if (here != null) 'lng': here.longitude,
      });
      if (mounted) await _refreshStatus();
    }().catchError((_) {});
  }

  /// O que mostrar depois de avisar: a que postos foi e quem assumiu.
  String _statusText() {
    final s = _status;
    final assigned = s?['assignedName'] as String?;
    if (assigned != null)
      return '$assigned assumiu o seu alerta e está a acompanhar esta viagem.';
    final stations = ((s?['stations'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    if (stations.isEmpty) {
      return 'Alerta registado. A equipa do Bazá foi avisada. Se puder, ligue também para o $emergencyNumber.';
    }
    final names = stations
        .map(
          (p) => p['distanceM'] != null
              ? '${p['name']} (a ${km((p['distanceM'] as num).toInt())})'
              : '${p['name']}',
        )
        .join(', ');
    return 'Alerta enviado a: $names. Vêem esta viagem, a viatura e a sua posição até o alerta ser fechado.';
  }

  /// Perigo iminente: avisa as autoridades com um só toque, sem telefonar. A
  /// partir daí elas acompanham esta corrida até darem o alerta por tratado.
  void _alertAuthorities() {
    _recordAlert();
    HapticFeedback.heavyImpact();
    setState(() => _authoritiesAlerted = true);
  }

  Future<void> _call() async {
    _recordAlert();
    HapticFeedback.heavyImpact();
    final ok = await launchUrl(Uri(scheme: 'tel', path: emergencyNumber))
        .catchError((_) => false);
    if (!ok && mounted)
      showError(
        context,
        'Não foi possível abrir o telefone. Ligue para o $emergencyNumber.',
      );
  }

  Future<void> _messageContact(String phone) async {
    _recordAlert();
    setState(() => _busy = true);
    try {
      final url = await _shareLink(context, widget.ride);
      final text = 'Preciso de ajuda. ${_shareText(url)}';
      final ok = await launchUrl(
        Uri(scheme: 'sms', path: phone, queryParameters: {'body': text}),
      );
      if (!ok) throw 'Não foi possível abrir as mensagens.';
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<Session>().user;
    final contact = user?.emergencyPhone;
    final contactName = (user?.emergencyName ?? '').isEmpty
        ? 'contacto de emergência'
        : user!.emergencyName!;
    final driver = widget.ride.driver;
    final vehicle = driver?.vehicle;
    return SafeArea(
      // Em ecrãs baixos o conteúdo desliza em vez de ficar cortado.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Emergência',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'Se está em perigo, avise as autoridades ou ligue já para a polícia.',
              textAlign: TextAlign.center,
              style: TextStyle(color: BazaColors.muted),
            ),
            const SizedBox(height: 16),
            if (_authoritiesAlerted)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: BazaColors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.verified_user, color: BazaColors.red),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _statusText(),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    // Som da viagem: só se partilha se a pessoa o ligar aqui.
                    ListenableBuilder(
                      listenable: AlertAudio.instance,
                      builder: (context, _) {
                        final audio = AlertAudio.instance;
                        final on = audio.rideId == widget.ride.id;
                        return SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: on,
                          onChanged: (v) => v
                              ? audio.start(
                                  context.read<Session>().api,
                                  widget.ride.id,
                                )
                              : audio.stop(),
                          secondary: Icon(
                            on ? Icons.mic : Icons.mic_none,
                            color: on ? BazaColors.red : BazaColors.muted,
                          ),
                          title: const Text(
                            'Partilhar o som da viagem',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            audio.problem ??
                                (on
                                    ? (audio.background
                                          ? 'A polícia e o seu contacto de confiança ouvem o que se passa na viatura. Pode bloquear o telemóvel: continua a gravar.'
                                          : 'A polícia e o seu contacto de confiança ouvem o que se passa na viatura. Mantenha o Bazá aberto.')
                                    : 'A polícia e o seu contacto de confiança (se tiver o Bazá) ouvem o que se passa na viatura.'),
                          ),
                        );
                      },
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _cancelAlert,
                        child: const Text('Foi engano: cancelar o alerta'),
                      ),
                    ),
                  ],
                ),
              )
            else
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: BazaColors.red,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(60),
                ),
                onPressed: _alertAuthorities,
                icon: const Icon(Icons.local_police_outlined),
                label: const Text('Perigo: avisar as autoridades'),
              ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: BazaColors.red,
                side: const BorderSide(color: BazaColors.red),
              ),
              onPressed: _call,
              icon: const Icon(Icons.call),
              label: const Text('Ligar para o $emergencyNumber'),
            ),
            const SizedBox(height: 10),
            if (contact != null)
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _messageContact(contact),
                icon: const Icon(Icons.sms_outlined),
                label: FittedBox(
                  child: Text('Enviar a minha viagem a $contactName'),
                ),
              )
            else
              const Text(
                'Dica: em "Os meus dados" pode definir um contacto de emergência, para lhe enviar a viagem com um toque.',
                textAlign: TextAlign.center,
                style: TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => shareRide(context, widget.ride),
              icon: const Icon(Icons.ios_share, size: 20),
              label: const Text('Partilhar a viagem com outra pessoa'),
            ),
            // O que dizer ao telefone: os dados da viatura.
            if (vehicle != null) ...[
              const Divider(height: 24),
              Text(
                'Viatura: ${vehicle.description} · matrícula ${vehicle.plate}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
