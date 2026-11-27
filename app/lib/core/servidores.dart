import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Um servidor da API do Bazá. [semSaldo]: o endereço está no acordo com as operadoras (navega-se sem saldo de dados).
@immutable
class Servidor {
  const Servidor({required this.id, required this.base, this.semSaldo = false});
  final String id, base;
  final bool semSaldo;

  @override
  String toString() => id;
}

/// Que servidor a pessoa quer: [automatico] (o principal e, sem ligação a ele, o sem saldo), [principal] (só o
/// principal) ou [semSaldo] (sempre o que não gasta saldo de dados).
enum ModoServidor { automatico, principal, semSaldo }

/// ESCOLHA DO SERVIDOR (2026-11-27) — copiada e adaptada da app AngoSchool (os produtos não partilham código).
///
/// `https://bazatranquilo.com` (Serve1, principal) e `https://angoschool.org/baza` (réplica da API no Serve2, no acordo
/// das operadoras: funciona SEM saldo de dados). Os dois falam com a mesma base de dados e o tempo real está ligado
/// entre eles, por isso a pessoa pode estar num e o motorista no outro.
///
///  • **Arranque sem pressa**: sonda o principal; a reserva só conta se o principal FALHAR.
///  • **Sonda assinada**: `GET /health?n=<aleatório>` tem de devolver o marcador e o mesmo `n` (a página de «sem saldo»
///    da operadora responde 200 com HTML e não conta).
///  • **Disjuntor**: o servidor que falhou fica de fora 60 s → 10 min; de 60 em 60 s experimenta-se o preferido e regressa-se.
///  • **Pergunta** antes de passar ao sem saldo ([aoPedirAutorizacao]), no modo automático e sem «Mudar sem perguntar».
///
/// ⛔ Só existe na compilação de produção (`API_URL=https://bazatranquilo.com`); noutras (desenvolvimento) há um servidor só.
class Servidores {
  Servidores._();

  static const principalProducao = 'https://bazatranquilo.com';
  static const marcadorSaude = 'baza-saude-v1';

  static const lista = <Servidor>[
    Servidor(id: 'com', base: principalProducao),
    Servidor(id: 'org', base: 'https://angoschool.org/baza', semSaldo: true),
  ];

  /// Ligada só quando a app foi compilada contra a produção (e nunca dentro do `flutter test`).
  static bool activa = false;

  static const _cofre = FlutterSecureStorage();
  static const _chaveModo = 'servidores_modo';
  static const _chaveAutorizado = 'servidores_sem_saldo_autorizado';

  /// Cliente das sondas (trocável nos testes).
  static http.Client cliente = http.Client();
  static http.Client get _cli => cliente;
  static Duration esperaAntesDaReserva = const Duration(milliseconds: 1500);
  static Duration esperaSonda = const Duration(seconds: 5);
  static Duration intervaloRegresso = const Duration(seconds: 60);
  static final _aleatorio = Random();

  static ModoServidor _modo = ModoServidor.automatico;
  static final _falhas = <String, int>{};
  static final _foraAte = <String, DateTime>{};
  static Future<void>? _pronto;
  static Timer? _regresso;

  /// O servidor em uso (a faixa «Modo sem saldo», o tempo real e as chamadas ouvem-no).
  static final activo = ValueNotifier<Servidor>(lista.first);
  static ModoServidor get modo => _modo;
  static String get baseActiva => activo.value.base;

  /// PERGUNTA antes de passar ao servidor sem saldo (a app instala aqui o diálogo). `true` = mudar.
  static Future<bool> Function(Servidor de, Servidor para)? aoPedirAutorizacao;
  static bool _autorizado = false;
  static Future<bool>? _aPerguntar;
  static bool get autorizadoSemPerguntar => _autorizado;

  static Future<void> definirAutorizacao(bool sempre) async {
    _autorizado = sempre;
    try {
      await _cofre.write(key: _chaveAutorizado, value: sempre ? '1' : '0');
    } catch (_) {}
  }

  static bool _precisaDeAutorizacao(Servidor de, Servidor para) =>
      para.semSaldo && !de.semSaldo && _modo == ModoServidor.automatico && !_autorizado && aoPedirAutorizacao != null;

  static Future<bool> _autorizar(Servidor de, Servidor para) => _aPerguntar ??= () async {
    try {
      return await aoPedirAutorizacao!(de, para);
    } catch (_) {
      return false;
    } finally {
      _aPerguntar = null;
    }
  }();

  /// Arranque preguiçoso: o 1.º pedido da API espera por isto (só uma vez).
  static Future<void> garantir() => _pronto ??= (activa ? _iniciar() : Future.value());

  static Future<void> _iniciar() async {
    try {
      final m = await _cofre.read(key: _chaveModo);
      _modo = ModoServidor.values.firstWhere((x) => x.name == m, orElse: () => ModoServidor.automatico);
      _autorizado = await _cofre.read(key: _chaveAutorizado) == '1';
    } catch (_) {}
    await escolher();
    _regresso?.cancel();
    _regresso = Timer.periodic(intervaloRegresso, (_) => _verificarRegresso());
  }

  static Future<void> definirModo(ModoServidor m) async {
    _modo = m;
    try {
      await _cofre.write(key: _chaveModo, value: m.name);
    } catch (_) {}
    await escolher();
  }

  static List<Servidor> get _candidatos => switch (_modo) {
    ModoServidor.principal => [lista.first],
    ModoServidor.semSaldo => [...lista.where((s) => s.semSaldo), ...lista.where((s) => !s.semSaldo)],
    ModoServidor.automatico => lista,
  };

  /// Sonda o preferido; a reserva começa cedo mas SÓ CONTA se o preferido falhar (um principal lento mas vivo fica).
  static Future<Servidor> escolher() async {
    final c = _candidatos;
    final preferido = c.first;
    if (c.length == 1) return _usar(preferido);
    final reserva = c[1];
    Future<bool>? okReserva;
    final arrancar = Timer(esperaAntesDaReserva, () => okReserva ??= sondar(reserva));
    final ok = await sondar(preferido);
    arrancar.cancel();
    if (ok) return _usar(preferido);
    _marcarFalha(preferido);
    if (!await (okReserva ??= sondar(reserva))) return _usar(preferido);
    if (_precisaDeAutorizacao(preferido, reserva) && !await _autorizar(preferido, reserva)) return _usar(preferido);
    return _usar(reserva);
  }

  static final _aConfirmar = <String, Future<bool>>{};
  // ⛔ o `whenComplete` não pode devolver o que o `remove` devolve (a própria tarefa: ficava à espera de si mesma)
  static Future<bool> _confirmarVivo(Servidor s) => _aConfirmar[s.id] ??= sondar(s).whenComplete(() {
    _aConfirmar.remove(s.id);
  });

  /// `GET <base>/health?n=<aleatório>` — vivo só com 200, JSON, o marcador e o MESMO `n`.
  static Future<bool> sondar(Servidor s) async {
    final n = List.generate(12, (_) => _aleatorio.nextInt(36).toRadixString(36)).join();
    try {
      final r = await _cli.get(Uri.parse('${s.base}/health?n=$n')).timeout(esperaSonda);
      if (r.statusCode != 200) return false;
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      final ok = d is Map && d['marcador'] == marcadorSaude && d['n'] == n;
      if (ok) registarSucesso(s);
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// O pedido a [falhou] não teve ligação: para onde repetir. Antes de mudar volta a sondar (um soluço não muda nada)
  /// e, se for para o sem saldo, PERGUNTA. `null` = não repetir.
  static Future<Servidor?> pedirAlternativa(Servidor falhou) async {
    if (activo.value.id != falhou.id) return activo.value; // outro pedido já mudou (e já perguntou)
    final alt = _alternativa(falhou);
    if (alt == null) return null;
    if (await _confirmarVivo(falhou)) return null;
    _marcarFalha(falhou);
    if (_precisaDeAutorizacao(falhou, alt) && !await _autorizar(falhou, alt)) return null;
    return _usar(alt);
  }

  static Servidor _usar(Servidor s) {
    if (activo.value.id != s.id) activo.value = s;
    return s;
  }

  static void _marcarFalha(Servidor s) {
    final n = (_falhas[s.id] ?? 0) + 1;
    _falhas[s.id] = n;
    final base = intervaloRegresso.inSeconds * pow(2, min(n - 1, 4)).toInt();
    final segundos = min(base, 600) + _aleatorio.nextInt(max(1, base ~/ 5));
    _foraAte[s.id] = DateTime.now().add(Duration(seconds: segundos));
  }

  static void registarSucesso(Servidor s) {
    _falhas.remove(s.id);
    _foraAte.remove(s.id);
  }

  static bool _estaDeFora(Servidor s) {
    final ate = _foraAte[s.id];
    return ate != null && DateTime.now().isBefore(ate);
  }

  static Servidor? _alternativa(Servidor falhou) {
    for (final s in _candidatos) {
      if (s.id != falhou.id && !_estaDeFora(s)) return s;
    }
    return null;
  }

  static Future<void> _verificarRegresso() async {
    final preferido = _candidatos.first;
    if (activo.value.id == preferido.id) return;
    if (await sondar(preferido)) _usar(preferido);
  }
}
