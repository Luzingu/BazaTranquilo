import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/call_state.dart';
import '../state/ride_state.dart';
import '../state/session.dart';
import '../widgets/common.dart';

class _Message {
  _Message(Map<String, dynamic> j)
    : id = j['id'] as String,
      fromDriver = j['from'] == 'driver',
      text = j['text'] as String,
      at = DateTime.parse(j['createdAt'] as String).toLocal();
  final String id, text;
  final bool fromDriver;
  final DateTime at;
}

/// Conversa entre o passageiro e o motorista de uma corrida.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.ride,
    required this.other,
    required this.iAmDriver,
  });
  final Ride ride;
  final RideParty other;
  final bool iAmDriver;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <_Message>[];
  late final RideState _rides = context.read<RideState>();
  late final ApiClient _api = context.read<Session>().api;
  StreamSubscription<Map<String, dynamic>>? _incoming;
  Timer? _poll;
  bool _loading = true;
  bool _open = true; // a corrida ainda permite escrever
  bool _sending = false;
  String? _error;

  /// Respostas de um toque, para não ter de escrever a conduzir ou à pressa.
  List<String> get _quickReplies => widget.iAmDriver
      ? const [
          'Estou a caminho',
          'Cheguei, estou à espera',
          'Onde está exactamente?',
          'Há muito trânsito, chego em breve',
        ]
      : const [
          'Já estou no local',
          'Estou a sair, 2 minutos',
          'Onde está?',
          'Pode ligar-me, por favor',
        ];

  @override
  void initState() {
    super.initState();
    _rides.chatOpen = true;
    // Marcar como lidas avisa quem está a ouvir (o botão "Mensagem"), e isso
    // não pode acontecer a meio da construção do ecrã: fica para o fim do frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rides.markChatRead();
    });
    _incoming = _rides.chatMessages.listen((m) => _add([_Message(m)]));
    _load();
    // Rede de segurança caso o aviso em tempo real se perca.
    _poll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _rides.chatOpen = false;
    _incoming?.cancel();
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    // O temporizador pode disparar depois de o ecrã fechar.
    if (!mounted) return;
    try {
      final res = await _api.get('/rides/${widget.ride.id}/messages');
      if (!mounted) return;
      _open = res['open'] == true;
      _add([
        for (final m in res['messages'] as List)
          _Message(Map<String, dynamic>.from(m as Map)),
      ]);
      setState(() {
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// Junta mensagens novas (sem repetir) e desce até à última.
  void _add(List<_Message> incoming) {
    final known = {for (final m in _messages) m.id};
    final fresh = incoming.where((m) => !known.contains(m.id)).toList();
    if (fresh.isEmpty || !mounted) return;
    setState(() {
      _messages
        ..addAll(fresh)
        ..sort((a, b) => a.at.compareTo(b.at));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send([String? quick]) async {
    final text = (quick ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final res = await _api.post('/rides/${widget.ride.id}/messages', {
        'text': text,
      });
      if (quick == null) _input.clear();
      _add([_Message(res['message'] as Map<String, dynamic>)]);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final other = widget.other;
    final name = other.name.isEmpty
        ? (widget.iAmDriver ? 'Passageiro' : 'Motorista')
        : other.name;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Avatar(name: name, photoUrl: other.photoUrl, radius: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17),
                  ),
                  Text(
                    widget.iAmDriver
                        ? 'Passageiro'
                        : (other.vehicle == null
                              ? 'Motorista'
                              : 'Motorista · ${other.vehicle!.plate}'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: BazaColors.muted,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Ligar',
            icon: const Icon(Icons.call_outlined),
            onPressed: () => context.read<CallState>().call(widget.ride),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: BazaColors.ink),
                    )
                  : _error != null && _messages.isEmpty
                  ? Center(
                      child: Column(
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
                  : _messages.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Ainda não há mensagens. Escreva ou use uma das respostas rápidas.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: BazaColors.muted),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) => _bubble(_messages[i]),
                    ),
            ),
            if (!_open)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'A corrida terminou. Já não é possível enviar mensagens.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: BazaColors.muted),
                ),
              )
            else ...[
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final reply in _quickReplies)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          label: Text(reply),
                          backgroundColor: Colors.white,
                          onPressed: _sending ? null : () => _send(reply),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 500,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText: 'Escreva uma mensagem',
                          counterText: '',
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton.filled(
                      tooltip: 'Enviar',
                      style: IconButton.styleFrom(
                        backgroundColor: BazaColors.yellow,
                        foregroundColor: BazaColors.ink,
                      ),
                      onPressed: _sending ? null : _send,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bubble(_Message m) {
    final mine = m.fromDriver == widget.iAmDriver;
    final time =
        '${m.at.hour.toString().padLeft(2, '0')}:${m.at.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: mine ? BazaColors.yellow : BazaColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(m.text, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 2),
            Text(
              time,
              style: const TextStyle(fontSize: 11, color: Color(0xFF4B5563)),
            ),
          ],
        ),
      ),
    );
  }
}
