// Escolha de servidor (2026-11-27): bazatranquilo.com e, sem saldo de dados, angoschool.org/baza.
import 'dart:convert';

import 'package:baza/core/servidores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Servidor simulado: [vivos] respondem à sonda como a API; os outros dão a página da operadora (200 + HTML) ou falham.
http.Client simulado(Set<String> vivos, {bool paginaDaOperadora = false}) => MockClient((r) async {
  final host = r.url.host;
  if (vivos.contains(host)) {
    return http.Response(jsonEncode({'ok': true, 'marcador': 'baza-saude-v1', 'n': r.url.queryParameters['n']}), 200);
  }
  if (paginaDaOperadora) return http.Response('<html>Sem saldo</html>', 200);
  throw http.ClientException('sem rede');
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // o cofre (flutter_secure_storage) não existe nos testes: responde vazio
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (_) async => null,
  );

  setUp(() {
    Servidores.activo.value = Servidores.lista.first;
    Servidores.aoPedirAutorizacao = null;
    Servidores.esperaAntesDaReserva = const Duration(milliseconds: 10);
  });

  test('principal vivo: fica no principal, sem pergunta', () async {
    Servidores.cliente = simulado({'bazatranquilo.com', 'angoschool.org'});
    var perguntou = false;
    Servidores.aoPedirAutorizacao = (_, _) async => perguntou = true;
    expect((await Servidores.escolher()).id, 'com');
    expect(perguntou, isFalse);
  });

  test('principal sem rede: pergunta e, com «sim», passa ao sem saldo', () async {
    Servidores.cliente = simulado({'angoschool.org'});
    Servidores.aoPedirAutorizacao = (_, para) async => para.semSaldo;
    expect((await Servidores.escolher()).id, 'org');
    expect(Servidores.baseActiva, 'https://angoschool.org/baza');
  });

  test('com «não» fica no principal', () async {
    Servidores.cliente = simulado({'angoschool.org'});
    Servidores.aoPedirAutorizacao = (_, _) async => false;
    expect((await Servidores.escolher()).id, 'com');
  });

  test('a página «sem saldo» da operadora (200 + HTML) não conta como servidor vivo', () async {
    Servidores.cliente = simulado({}, paginaDaOperadora: true);
    expect(await Servidores.sondar(Servidores.lista.first), isFalse);
    expect(await Servidores.sondar(Servidores.lista.last), isFalse);
  });

  test('a meio do uso: o principal ainda responde à sonda → não muda (foi um soluço)', () async {
    Servidores.cliente = simulado({'bazatranquilo.com', 'angoschool.org'});
    expect(await Servidores.pedirAlternativa(Servidores.lista.first), isNull);
    expect(Servidores.activo.value.id, 'com');
  });
}
