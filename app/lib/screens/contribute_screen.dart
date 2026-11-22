import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/location.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/baza_map.dart';
import '../widgets/common.dart';

/// Utilizadores estrela: registar no mapa o local onde estão (um mercado, uma
/// paragem, um bairro…), para que apareça na pesquisa de toda a gente.
class ContributeScreen extends StatefulWidget {
  const ContributeScreen({super.key});

  @override
  State<ContributeScreen> createState() => _ContributeScreenState();
}

class _ContributeScreenState extends State<ContributeScreen> {
  final _name = TextEditingController();
  final _zone = TextEditingController();
  final _submitKey = GlobalKey<AsyncButtonState>();
  late final _api = context.read<Session>().api;

  LatLng? _here;
  bool _locating = true;
  String? _problem;
  List<Map<String, dynamic>> _mine = const [];
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _locate();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _zone.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    setState(() => _locating = true);
    final here = await currentLatLng();
    if (!mounted) return;
    setState(() {
      _here = here;
      _locating = false;
      _problem = here == null
          ? (locationProblem ?? 'Não foi possível obter a sua posição.')
          : null;
    });
  }

  Future<void> _load() async {
    try {
      final res = await _api.get('/places/contributions');
      if (!mounted) return;
      setState(() {
        _mine = [
          for (final p in res['places'] as List)
            Map<String, dynamic>.from(p as Map),
        ];
        _total = (res['total'] as num).round();
      });
    } on ApiException {
      // A lista é só informativa.
    }
  }

  Future<void> _save() async {
    final here = _here;
    final name = _name.text.trim();
    if (here == null)
      throw 'Ainda não temos a sua posição. Toque em "Actualizar posição".';
    if (name.length < 2) throw 'Escreva o nome por que este local é conhecido.';
    await _api.post('/places/contributions', {
      'name': name,
      if (_zone.text.trim().isNotEmpty) 'zone': _zone.text.trim(),
      'lat': here.latitude,
      'lng': here.longitude,
    });
    if (!mounted) return;
    _name.clear();
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('"$name" foi registado. Obrigado!')));
    await _load();
  }

  Future<void> _remove(Map<String, dynamic> place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover este local?'),
        content: Text('"${place['name']}" deixa de aparecer na pesquisa.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Manter'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: BazaColors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.delete('/places/contributions/${place['id']}');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final here = _here;
    return Scaffold(
      appBar: AppBar(title: const Text('Registar locais')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          const Text(
            'Está num sítio que o mapa não conhece? Registe-o com o nome por que é conhecido. '
            'Fica gravado no ponto exacto onde está agora e passa a aparecer na pesquisa de todos.',
            style: TextStyle(color: BazaColors.muted),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 200,
              child: here == null
                  ? ColoredBox(
                      color: BazaColors.surface,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: _locating
                              ? const CircularProgressIndicator(
                                  color: BazaColors.ink,
                                )
                              : Text(
                                  _problem ?? '',
                                  textAlign: TextAlign.center,
                                ),
                        ),
                      ),
                    )
                  : IgnorePointer(
                      child: BazaMap(
                        me: here,
                        bottomPadding: 0,
                        fitKey: '${here.latitude},${here.longitude}',
                      ),
                    ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _locating ? null : _locate,
              icon: const Icon(Icons.my_location, size: 18),
              label: Text(
                _locating ? 'A obter a posição…' : 'Actualizar posição',
              ),
            ),
          ),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: 'Nome do local',
              hintText: 'Ex.: Mercado do Kikolo',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _zone,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submitKey.currentState?.trigger(),
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Bairro ou município (opcional)',
              helperText: 'Se deixar vazio, usamos o que o mapa indicar para este ponto.',
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          AsyncButton(
            key: _submitKey,
            label: 'Registar este local',
            onPressed: _save,
          ),
          const SizedBox(height: 28),
          Text(
            'Locais que registou ($_total)',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          if (_mine.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Ainda não registou nenhum local.',
                style: TextStyle(color: BazaColors.muted),
              ),
            ),
          for (final p in _mine)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_outlined),
              title: Text('${p['name']}'),
              subtitle: Text(
                [
                  p['zone'],
                  p['province'],
                ].where((v) => v != null && '$v'.isNotEmpty).join(', '),
              ),
              trailing: IconButton(
                tooltip: 'Remover',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _remove(p),
              ),
            ),
        ],
      ),
    );
  }
}
