import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import '../widgets/document_photo.dart';
import '../widgets/vehicle_fields.dart';

/// "As minhas viaturas": o motorista pode ter várias, de categorias
/// diferentes, e conduz uma de cada vez — a activa decide os pedidos que recebe.
class GarageScreen extends StatelessWidget {
  const GarageScreen({super.key});

  Future<void> _run(
    BuildContext context,
    Future<Map<String, dynamic>> Function() request,
  ) async {
    final session = context.read<Session>();
    try {
      final res = await request();
      session.setUser(User.fromJson(res['user'] as Map<String, dynamic>));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _remove(BuildContext context, Vehicle v) async {
    final api = context.read<Session>().api;
    final confirmed = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remover ${v.make} ${v.carModel} (${v.plate})?'),
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
    if (confirmed == true && context.mounted)
      await _run(context, () => api.delete('/vehicles/${v.id}'));
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final user = session.user;
    if (user == null) return const SizedBox.shrink(); // sessão terminada
    final api = session.api;

    void openForm([Vehicle? v]) => Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => VehicleFormScreen(vehicle: v)));

    return Scaffold(
      appBar: AppBar(title: const Text('As minhas viaturas')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: openForm,
        backgroundColor: BazaColors.yellow,
        foregroundColor: BazaColors.ink,
        icon: const Icon(Icons.add),
        label: const Text('Adicionar viatura'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(
            user.isOnline
                ? 'Está online. Fique offline para trocar de viatura.'
                : 'Recebe os pedidos do tipo da viatura activa. Toque em "Usar esta" para trocar.',
            style: const TextStyle(color: BazaColors.muted),
          ),
          const SizedBox(height: 12),
          for (final v in user.vehicles)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
              decoration: BoxDecoration(
                color: v.active
                    ? BazaColors.yellow.withValues(alpha: 0.18)
                    : BazaColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: v.active ? BazaColors.ink : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      VehicleBadge(vehicle: v, size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${v.make} ${v.carModel}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${categoryLabels[v.category] ?? v.category} · ${v.color} · ${v.plate}',
                              style: const TextStyle(color: BazaColors.muted),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Opções',
                        onSelected: (action) => action == 'edit'
                            ? openForm(v)
                            : _remove(context, v),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('Editar'),
                          ),
                          if (!v.active)
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('Remover'),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (v.active)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 18,
                            color: BazaColors.green,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Viatura activa',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    )
                  else if (!v.docsComplete)
                    TextButton.icon(
                      onPressed: () => openForm(v),
                      icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                      label: const Text('Completar documentos'),
                    )
                  else if (v.status != 'approved')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ReviewChip(status: v.status),
                          if (v.status == 'rejected' && v.reviewNote != null)
                            Text(
                              'Motivo: ${v.reviewNote}',
                              style: const TextStyle(color: BazaColors.red),
                            ),
                        ],
                      ),
                    )
                  else
                    TextButton(
                      onPressed: user.isOnline
                          ? null
                          : () => _run(
                              context,
                              () => api.post('/vehicles/${v.id}/activate'),
                            ),
                      child: const Text('Usar esta'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Adicionar ou editar uma viatura da garagem.
class VehicleFormScreen extends StatefulWidget {
  const VehicleFormScreen({super.key, this.vehicle});
  final Vehicle? vehicle;

  @override
  State<VehicleFormScreen> createState() => _VehicleFormScreenState();
}

class _VehicleFormScreenState extends State<VehicleFormScreen> {
  late final _fields = VehicleFieldsController(widget.vehicle);
  // Documentos (livrete, título, seguro) escolhidos e por enviar.
  final _docs = <String, PickedPhoto>{};
  bool _showDocErrors = false;

  Set<String> get _uploaded => {
    if (widget.vehicle?.hasRegistration ?? false) 'registration',
    if (widget.vehicle?.hasOwnership ?? false) 'ownership',
    if (widget.vehicle?.hasInsurance ?? false) 'insurance',
  };

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final session = context.read<Session>();
    final navigator = Navigator.of(context);
    final vehicle = _fields.read();
    final missing = VehicleDocsSection.missing(_docs, _uploaded);
    if (missing.isNotEmpty) {
      setState(() => _showDocErrors = true);
      throw 'Faltam documentos da viatura: ${missing.join(', ')}.';
    }
    var id = widget.vehicle?.id;
    final res = id == null
        ? await session.api.post('/vehicles', vehicle.toJson())
        : await session.api.putJson('/vehicles/$id', vehicle.toJson());
    final user = User.fromJson(res['user'] as Map<String, dynamic>);
    session.setUser(user);
    // Numa viatura nova, o id vem na resposta: procura-se pela matrícula.
    id ??= user.vehicles.where((v) => v.plate == vehicle.plate).firstOrNull?.id;
    if (id != null) {
      for (final (key, _) in vehicleDocuments) {
        final photo = _docs[key];
        if (photo == null) continue;
        await session.uploadDocument(
          '/documents/vehicles/$id/$key',
          photo.bytes,
          photo.contentType,
        );
        _docs.remove(key);
      }
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.vehicle == null ? 'Nova viatura' : 'Editar viatura'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            VehicleFields(controller: _fields),
            const SizedBox(height: 20),
            VehicleDocsSection(
              picked: _docs,
              uploaded: _uploaded,
              loadUploaded: widget.vehicle?.id == null
                  ? null
                  : (doc) => context.read<Session>().api.getBytes(
                      '/documents/vehicles/${widget.vehicle!.id}/$doc',
                    ),
              showErrors: _showDocErrors,
              onPicked: (doc, photo) => setState(() => _docs[doc] = photo),
            ),
            const SizedBox(height: 24),
            AsyncButton(label: 'Guardar', onPressed: _save),
          ],
        ),
      ),
    );
  }
}
