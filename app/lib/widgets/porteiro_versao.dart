import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../core/config.dart';
import '../core/theme.dart';

/// Versão deste app (comparada com `app-versao.json`). Vem da compilação: `--dart-define=APP_VERSAO=X.Y.Z`
/// (o `tools/compilar_loja.sh` tira-a do `version:` do pubspec.yaml); sem ela, este valor — acompanhar o pubspec.
const versaoDoApp = String.fromEnvironment('APP_VERSAO', defaultValue: '1.0.0');

/// Actualização obrigatória / aviso de versão nova (2026-11-26, o mesmo desenho das apps AngoSchool).
///
/// Lê `https://bazatranquilo.com/app-versao.json` (ficheiro estático do `site/`):
///  • versão instalada abaixo da `minima` → ecrã a BLOQUEAR, com «Actualizar agora» (abre a loja);
///  • abaixo da `actual` → aviso discreto em baixo, que se fecha.
/// Pergunta ao abrir e de novo quando o app volta ao ecrã (no máximo de 30 em 30 min; já bloqueado, sempre).
/// ⛔ Falha de rede ou resposta estranha NUNCA bloqueia. ⛔ Na web nunca bloqueia (o navegador já tem a última versão).
/// As correcções pequenas chegam sem loja nem aviso, pelo Shorebird (ver PRODUCAO.md › Actualizações do app).
class PorteiroVersao extends StatefulWidget {
  final Widget child;
  const PorteiroVersao({super.key, required this.child});

  @override
  State<PorteiroVersao> createState() => _PorteiroVersaoState();
}

enum _Estado { emDia, haNova, obrigatoria }

class _PorteiroVersaoState extends State<PorteiroVersao> with WidgetsBindingObserver {
  _Estado _estado = _Estado.emDia;
  String _mensagem = '', _loja = '';
  bool _avisoFechado = false;
  DateTime? _ultima;

  static bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _verificar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    if (estado != AppLifecycleState.resumed) return;
    final u = _ultima;
    if (_estado == _Estado.obrigatoria || u == null || DateTime.now().difference(u) >= const Duration(minutes: 30)) _verificar();
  }

  /// Negativo se [a] < [b] («X.Y.Z», ignora o `+número`).
  static int _comparar(String a, String b) {
    List<int> p(String v) => v.split('+').first.split('.').map((x) => int.tryParse(x.trim()) ?? 0).toList();
    final x = p(a), y = p(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  Future<void> _verificar() async {
    if (kIsWeb) return;
    _ultima = DateTime.now();
    try {
      final r = await http.get(Uri.parse('$apiBaseUrl/app-versao.json')).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      String daPlataforma(dynamic v) => v is Map ? '${v[_ios ? 'ios' : 'android'] ?? '0.0.0'}' : '${v ?? '0.0.0'}';
      final lojas = d['loja'] is Map ? d['loja'] as Map : const {};
      final estado = _comparar(versaoDoApp, daPlataforma(d['minima'])) < 0
          ? _Estado.obrigatoria
          : _comparar(versaoDoApp, daPlataforma(d['actual'])) < 0
          ? _Estado.haNova
          : _Estado.emDia;
      if (!mounted) return;
      setState(() {
        _estado = estado;
        _mensagem = '${d['mensagem'] ?? ''}';
        _loja = '${lojas[_ios ? 'ios' : 'android'] ?? ''}';
      });
    } catch (_) {
      // sem rede ou resposta estranha: nunca bloqueia
    }
  }

  Future<void> _abrirLoja() async {
    final u = Uri.tryParse(_loja);
    if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      if (_estado == _Estado.haNova && !_avisoFechado)
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: SafeArea(
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(14),
              color: BazaColors.ink,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                child: Row(children: [
                  const Icon(Icons.new_releases_outlined, color: BazaColors.yellow),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_mensagem.isEmpty ? 'Há uma versão nova do Bazá.' : _mensagem, style: const TextStyle(color: Colors.white))),
                  if (_loja.isNotEmpty) TextButton(onPressed: _abrirLoja, child: const Text('Actualizar', style: TextStyle(color: BazaColors.yellow))),
                  IconButton(tooltip: 'Fechar', onPressed: () => setState(() => _avisoFechado = true), icon: const Icon(Icons.close, color: Colors.white70)),
                ]),
              ),
            ),
          ),
        ),
      if (_estado == _Estado.obrigatoria)
        Positioned.fill(
          child: Material(
            color: Colors.white,
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: const BoxDecoration(color: BazaColors.yellow, shape: BoxShape.circle),
                        child: const Icon(Icons.system_update, size: 46, color: BazaColors.ink),
                      ),
                      const SizedBox(height: 20),
                      const Text('Actualização necessária', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: BazaColors.ink)),
                      const SizedBox(height: 10),
                      Text(
                        _mensagem.isEmpty ? 'Esta versão do Bazá já não funciona. Actualize-a na loja para continuar.' : _mensagem,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: BazaColors.muted, height: 1.4),
                      ),
                      const SizedBox(height: 6),
                      Text('Versão instalada: $versaoDoApp', style: const TextStyle(fontSize: 12, color: BazaColors.muted)),
                      const SizedBox(height: 22),
                      if (_loja.isNotEmpty)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(onPressed: _abrirLoja, icon: const Icon(Icons.system_update), label: const Text('Actualizar agora')),
                        )
                      else
                        Text('Procure «Bazá» na ${_ios ? 'App Store' : 'Play Store'} e toque em «Actualizar».', textAlign: TextAlign.center),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}
