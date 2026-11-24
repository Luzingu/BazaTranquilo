import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/location.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import 'place_search.dart';

/// Um local guardado pelo passageiro (Casa, Trabalho ou outro com nome).
class SavedPlace {
  const SavedPlace({
    required this.id,
    required this.kind,
    required this.label,
    required this.place,
  });
  final String id;

  /// 'home', 'work' ou 'other'.
  final String kind;
  final String label;
  final Place place;

  IconData get icon => switch (kind) {
    'home' => Icons.home_outlined,
    'work' => Icons.work_outline,
    _ => Icons.bookmark_outline,
  };

  factory SavedPlace.fromJson(Map<String, dynamic> j) => SavedPlace(
    id: j['id'] as String,
    kind: j['kind'] as String? ?? 'other',
    label: j['label'] as String,
    place: Place.fromJson(j),
  );
}

List<SavedPlace> _parse(Map<String, dynamic> res) => [
  for (final p in res['places'] as List)
    SavedPlace.fromJson(Map<String, dynamic>.from(p as Map)),
];

Future<List<SavedPlace>> loadSavedPlaces(ApiClient api) async =>
    _parse(await api.get('/places/saved'));

/// Guarda um local. Por omissão é o ponto onde o utilizador está agora, com o
/// nome que ele lhe der; em alternativa pode procurar outro endereço. Devolve a
/// lista actualizada, ou null se o utilizador desistiu.
Future<List<SavedPlace>?> addSavedPlace(
  BuildContext context, {
  required String kind,
  LatLng? near,
}) async {
  final api = context.read<Session>().api;
  final result = await showModalBottomSheet<Object>(
    isDismissible: false,
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _SaveHereSheet(kind: kind),
  );
  if (result is List<SavedPlace>)
    return result; // guardado com a localização actual
  if (result != 'search' || !context.mounted) return null;

  // Alternativa: procurar um endereço diferente do sítio onde se está.
  final place = await Navigator.of(context).push<Place>(
    MaterialPageRoute(
      builder: (_) => PlaceSearchScreen(
        title: 'Endereço do local',
        near: near,
        showSaved: false,
      ),
    ),
  );
  if (place == null || !context.mounted) return null;
  var label = _defaultLabel(kind);
  if (kind == 'other') {
    final name = await _askLabel(
      context,
      initial: place.address.split(',').first,
    );
    if (name == null) return null;
    label = name;
  }
  return _parse(
    await api.post('/places/saved', {
      'kind': kind,
      'label': label,
      ...place.toJson(),
    }),
  );
}

String _defaultLabel(String kind) => switch (kind) {
  'home' => 'Casa',
  'work' => 'Trabalho',
  _ => '',
};

/// Guardar o sítio onde o utilizador está agora, com um nome.
class _SaveHereSheet extends StatefulWidget {
  const _SaveHereSheet({required this.kind});
  final String kind;

  @override
  State<_SaveHereSheet> createState() => _SaveHereSheetState();
}

class _SaveHereSheetState extends State<_SaveHereSheet> {
  final _submitKey = GlobalKey<AsyncButtonState>();
  late final _name = TextEditingController(text: _defaultLabel(widget.kind));
  Place? _here;
  bool _locating = true;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    setState(() => _locating = true);
    final api = context.read<Session>().api;
    final position = await currentLatLng();
    Place? here;
    if (position != null) {
      try {
        final res = await api.get('/places/reverse', {
          'lat': '${position.latitude}',
          'lng': '${position.longitude}',
        });
        here = Place.fromJson(res['place'] as Map<String, dynamic>);
      } on ApiException {
        // Sem o nome da rua guarda-se o ponto na mesma.
        here = Place(
          address: 'Local no mapa',
          lat: position.latitude,
          lng: position.longitude,
        );
      }
    }
    if (mounted) {
      setState(() {
        _here = here;
        _locating = false;
      });
    }
  }

  Future<void> _save() async {
    final here = _here;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Dê um nome a este local');
      return;
    }
    if (here == null) return;
    final navigator = Navigator.of(context);
    final res = await context.read<Session>().api.post('/places/saved', {
      'kind': widget.kind,
      'label': name,
      ...here.toJson(),
    });
    navigator.pop(_parse(res));
  }

  @override
  Widget build(BuildContext context) {
    final here = _here;
    final title = switch (widget.kind) {
      'home' => 'Guardar a minha casa',
      'work' => 'Guardar o meu trabalho',
      _ => 'Guardar este local',
    };
    return Padding(
      // Sobe com o teclado.
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            // O ponto que vai ser guardado: onde o utilizador está agora.
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: BazaColors.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    here == null && !_locating
                        ? Icons.location_off_outlined
                        : Icons.my_location,
                    color: here == null ? BazaColors.muted : BazaColors.green,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _locating
                        ? const Text('A obter a sua localização…')
                        : here == null
                        ? const Text(
                            'Não foi possível obter a sua localização. Active-a e tente de novo, ou procure o endereço.',
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Onde está agora',
                                style: TextStyle(
                                  color: BazaColors.muted,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                here.address,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                  ),
                  if (_locating)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: BazaColors.ink,
                      ),
                    )
                  else
                    IconButton(
                      tooltip: 'Actualizar localização',
                      onPressed: _locate,
                      icon: const Icon(Icons.refresh),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              autofocus: widget.kind == 'other',
              maxLength: 40,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              onSubmitted: (_) => _submitKey.currentState?.trigger(),
              decoration: InputDecoration(
                labelText: 'Nome do local',
                hintText: 'Ex.: Casa da mãe, Ginásio',
                counterText: '',
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 16),
            AsyncButton(
              key: _submitKey,
              label: 'Guardar este local',
              onPressed: here == null ? null : _save,
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('search'),
              child: const Text('Procurar outro endereço'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> _askLabel(BuildContext context, {String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    barrierDismissible: false,
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Nome do local'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'Ex.: Casa da mãe, Ginásio',
          counterText: '',
        ),
        onSubmitted: (v) =>
            Navigator.pop(context, v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: () {
            final v = controller.text.trim();
            if (v.isNotEmpty) Navigator.pop(context, v);
          },
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
}

/// "Locais guardados": gerir Casa, Trabalho e outros locais habituais.
class SavedPlacesScreen extends StatefulWidget {
  const SavedPlacesScreen({super.key});

  @override
  State<SavedPlacesScreen> createState() => _SavedPlacesScreenState();
}

class _SavedPlacesScreenState extends State<SavedPlacesScreen> {
  List<SavedPlace>? _places;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final places = await loadSavedPlaces(context.read<Session>().api);
      if (mounted) {
        setState(() {
          _places = places;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _add(String kind) async {
    try {
      final places = await addSavedPlace(context, kind: kind);
      if (places != null && mounted) setState(() => _places = places);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _remove(SavedPlace p) async {
    final api = context.read<Session>().api;
    final confirmed = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remover "${p.label}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Não'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final places = _parse(await api.delete('/places/saved/${p.id}'));
      if (mounted) setState(() => _places = places);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final places = _places;
    return Scaffold(
      appBar: AppBar(title: const Text('Locais guardados')),
      floatingActionButton: places == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _add('other'),
              backgroundColor: BazaColors.yellow,
              foregroundColor: BazaColors.ink,
              icon: const Icon(Icons.add),
              label: const Text('Adicionar local'),
            ),
      body: places == null
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
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    'Guarde os locais onde costuma ser recolhido ou para onde costuma ir. Aparecem logo ao escolher a recolha e o destino.',
                    style: TextStyle(color: BazaColors.muted),
                  ),
                ),
                // Casa e Trabalho aparecem sempre, mesmo por definir.
                for (final (kind, label, icon) in const [
                  ('home', 'Casa', Icons.home_outlined),
                  ('work', 'Trabalho', Icons.work_outline),
                ])
                  if (places.where((p) => p.kind == kind).firstOrNull
                      case final saved?)
                    _tile(saved)
                  else
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: BazaColors.surface,
                        foregroundColor: BazaColors.muted,
                        child: Icon(icon),
                      ),
                      title: Text('Adicionar $label'),
                      subtitle: const Text('Ainda não definido'),
                      trailing: const Icon(Icons.add),
                      onTap: () => _add(kind),
                    ),
                for (final p in places.where((p) => p.kind == 'other'))
                  _tile(p),
              ],
            ),
    );
  }

  Widget _tile(SavedPlace p) => ListTile(
    leading: CircleAvatar(
      backgroundColor: BazaColors.yellow.withValues(alpha: 0.25),
      foregroundColor: BazaColors.ink,
      child: Icon(p.icon),
    ),
    title: Text(p.label),
    subtitle: Text(
      p.place.address,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: PopupMenuButton<String>(
      tooltip: 'Opções',
      onSelected: (action) => action == 'remove' ? _remove(p) : _add(p.kind),
      itemBuilder: (_) => [
        // Casa e Trabalho mudam-se escolhendo outro endereço.
        if (p.kind != 'other')
          const PopupMenuItem(value: 'change', child: Text('Alterar local')),
        const PopupMenuItem(value: 'remove', child: Text('Remover')),
      ],
    ),
  );
}
