import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../services/notifier.dart';
import '../state/session.dart';
import 'agent_screen.dart';

/// Avisos enviados pela equipa do Bazá a esta conta.
class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key});

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  List<Map<String, dynamic>>? _notices;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await context.read<Session>().api.get('/notices');
      if (!mounted) return;
      setState(() {
        _notices = (res['notices'] as List).cast<Map<String, dynamic>>();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notices = _notices;
    return Scaffold(
      appBar: AppBar(title: const Text('Avisos do Bazá')),
      body: notices == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(errorText(_error!)),
                    ),
            )
          : notices.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'Não tem avisos. Quando a equipa do Bazá lhe enviar algum, aparece aqui.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: BazaColors.muted, fontSize: 15),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: notices.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final n = notices[i];
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: BazaColors.surface,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          n['title'] as String,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(n['message'] as String),
                        const SizedBox(height: 6),
                        Text(
                          dateTime(
                            DateTime.parse(n['createdAt'] as String).toLocal(),
                          ),
                          style: const TextStyle(
                            color: BazaColors.muted,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// Mostra os avisos por ler numa janela, por cima do que estiver aberto: ao
/// abrir o app e sempre que chega um aviso novo. Só saem com "Entendi".
class NoticeHost extends StatefulWidget {
  const NoticeHost({super.key, required this.child});
  final Widget child;

  @override
  State<NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<NoticeHost> {
  late final Session _session = context.read<Session>();
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _session.on('notice:new', _onNew);
    _session.on('guardian:alert', _onFriendAlert);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _check();
      _checkFriends();
    });
  }

  @override
  void dispose() {
    _session.off('notice:new', _onNew);
    _session.off('guardian:alert', _onFriendAlert);
    super.dispose();
  }

  // ── Pessoa de confiança ───────────────────────────────────────────────────
  // Um contacto que tem esta pessoa como contacto de emergência accionou o
  // alerta de perigo: abre-se o acompanhamento da viagem dele.
  final _shownAlerts = <String>{};

  void _onFriendAlert(dynamic data) {
    if (data is Map && data['title'] is String) {
      Notifier.instance.show(
        Notifier.rideId,
        data['title'] as String,
        '${data['body'] ?? ''}',
        urgent: true,
      );
    }
    _checkFriends();
  }

  Future<void> _checkFriends() async {
    try {
      final res = await _session.api.get('/guardian/alerts');
      for (final a in (res['alerts'] as List).cast<Map<String, dynamic>>()) {
        final id = a['id'] as String;
        if (!mounted || !_shownAlerts.add(id)) continue;
        await Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(
            builder: (_) => AgentAlertScreen(
              id: id,
              base: '/guardian/alerts',
              friend: true,
            ),
          ),
        );
      }
    } catch (_) {
      // Sem rede: volta a verificar ao abrir o app.
    }
  }

  void _onNew(dynamic data) {
    if (data is Map && data['title'] is String) {
      Notifier.instance.show(
        Notifier.rideId,
        data['title'] as String,
        '${data['message'] ?? ''}',
        urgent: true,
      );
    }
    _check();
  }

  Future<void> _check() async {
    if (_showing || !mounted) return;
    _showing = true;
    try {
      final res = await _session.api.get('/notices');
      final unread = (res['notices'] as List)
          .cast<Map<String, dynamic>>()
          .where((n) => n['read'] != true)
          .toList()
          .reversed; // do mais antigo para o mais recente
      for (final n in unread) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.campaign_outlined, size: 34),
            title: Text(n['title'] as String),
            content: SingleChildScrollView(child: Text(n['message'] as String)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Entendi'),
              ),
            ],
          ),
        );
        await _session.api.post('/notices/${n['id']}/read');
      }
    } catch (_) {
      // Sem rede: os avisos aparecem na próxima vez.
    } finally {
      _showing = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
