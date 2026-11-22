import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import '../widgets/profile_photo.dart';
import '../widgets/document_photo.dart';
import '../widgets/vehicle_fields.dart';

/// Carta de condução do motorista, com as fotos da frente e do verso.
///
/// Com [onboarding], é o fim da criação da conta, em dois passos curtos —
/// primeiro a carta, depois a primeira viatura e o seu livrete — para que cada
/// passo caiba no ecrã mesmo com o teclado aberto. As restantes viaturas
/// gerem-se em "As minhas viaturas".
class VehicleScreen extends StatefulWidget {
  const VehicleScreen({super.key, this.onboarding = false});
  final bool onboarding;

  @override
  State<VehicleScreen> createState() => _VehicleScreenState();
}

class _VehicleScreenState extends State<VehicleScreen> {
  late final TextEditingController _licenseNumber, _licenseCategory;
  late final VehicleFieldsController _vehicle;
  final _numberFocus = FocusNode();
  DateTime? _licenseExpiry;
  int _step = 0; // 0 = carta, 1 = viatura (só no registo)

  // Fotos escolhidas neste ecrã e ainda por enviar.
  PickedPhoto? _front, _back;

  // Documentos da viatura (livrete, título, seguro) escolhidos e por enviar.
  final _vehicleDocs = <String, PickedPhoto>{};
  bool _showDocErrors = false;
  String? _photoError; // falta a foto de perfil

  // Erros mostrados junto do próprio campo.
  String? _numberError, _categoryError, _expiryError, _frontError, _backError;

  /// O que está a ser enviado, para mostrar o progresso no botão.
  String? _progress;

  @override
  void initState() {
    super.initState();
    final user = context.read<Session>().user!;
    final l = user.license;
    _licenseNumber = TextEditingController(text: l?.number);
    _licenseCategory = TextEditingController(text: l?.category ?? 'B');
    _licenseExpiry = l?.expiresAt;
    _vehicle = VehicleFieldsController(user.vehicle);
    // Quem interrompeu o registo com a carta já completa retoma na viatura.
    if (widget.onboarding && l != null && l.hasFront && l.hasBack) _step = 1;
  }

  @override
  void dispose() {
    _licenseNumber.dispose();
    _licenseCategory.dispose();
    _numberFocus.dispose();
    _vehicle.dispose();
    super.dispose();
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      helpText: 'Validade da carta de condução',
      initialDate: _licenseExpiry != null && _licenseExpiry!.isAfter(now)
          ? _licenseExpiry!
          : now,
      firstDate: now,
      lastDate: DateTime(now.year + 30),
    );
    if (picked != null && mounted) {
      setState(() {
        _licenseExpiry = picked;
        _expiryError = null;
      });
    }
  }

  /// Valida a carta e marca o que falta. Devolve null se algo falta.
  License? _readLicense() {
    final current = context.read<Session>().user?.license;
    final number = _licenseNumber.text.trim(),
        category = _licenseCategory.text.trim();
    final expiry = _licenseExpiry;
    setState(() {
      _numberError = number.length < 4
          ? 'Escreva o número da sua carta (mínimo 4 caracteres)'
          : null;
      _categoryError = category.isEmpty ? 'Obrigatório' : null;
      _expiryError = expiry == null ? 'Toque para escolher a data' : null;
      _photoError =
          widget.onboarding && context.read<Session>().user?.photoUrl == null
          ? 'A foto de perfil é obrigatória'
          : null;
      _frontError = _front == null && !(current?.hasFront ?? false)
          ? 'Falta a foto da frente'
          : null;
      _backError = _back == null && !(current?.hasBack ?? false)
          ? 'Falta a foto do verso'
          : null;
    });
    if (_numberError != null) _numberFocus.requestFocus();
    final errors = [
      _numberError,
      _categoryError,
      _expiryError,
      _frontError,
      _backError,
      _photoError,
    ];
    if (expiry == null || errors.any((e) => e != null)) return null;
    return License(
      number: number.toUpperCase(),
      category: category.toUpperCase(),
      // Válida até ao fim do dia indicado.
      expiresAt: DateTime(expiry.year, expiry.month, expiry.day, 23, 59),
    );
  }

  Future<void> _next() async {
    if (_readLicense() == null) return;
    FocusScope.of(context).unfocus();
    setState(() => _step = 1);
  }

  Future<void> _save() async {
    final session = context.read<Session>();
    final navigator = Navigator.of(context);
    final license = _readLicense();
    if (license == null) {
      if (_step != 0) setState(() => _step = 0);
      return;
    }
    Vehicle? vehicle;
    if (widget.onboarding) {
      vehicle = _vehicle.read();
      final active = session.user?.vehicles.where((v) => v.active).firstOrNull;
      if (VehicleDocsSection.missing(
        _vehicleDocs,
        _uploadedDocs(active),
      ).isNotEmpty) {
        setState(() => _showDocErrors = true);
        throw 'Faltam documentos da viatura: ${VehicleDocsSection.missing(_vehicleDocs, _uploadedDocs(active)).join(', ')}.';
      }
    }

    void progress(String? text) {
      if (mounted) setState(() => _progress = text);
    }

    try {
      // Cada envio fica guardado no servidor: se a rede falhar a meio, ao
      // tentar de novo só se envia o que falta.
      progress('A guardar os dados…');
      await session.updateProfile(license: license, vehicle: vehicle);
      if (_front != null) {
        progress('A enviar a frente da carta…');
        await session.uploadDocument(
          '/documents/license/front',
          _front!.bytes,
          _front!.contentType,
        );
        _front = null;
      }
      if (_back != null) {
        progress('A enviar o verso da carta…');
        await session.uploadDocument(
          '/documents/license/back',
          _back!.bytes,
          _back!.contentType,
        );
        _back = null;
      }
      final vehicleId = session.user?.vehicle?.id;
      if (vehicleId != null) {
        // Envia um documento de cada vez; os que já seguiram não se repetem.
        for (final (key, label) in vehicleDocuments) {
          final photo = _vehicleDocs[key];
          if (photo == null) continue;
          progress('A enviar: $label…');
          await session.uploadDocument(
            '/documents/vehicles/$vehicleId/$key',
            photo.bytes,
            photo.contentType,
          );
          _vehicleDocs.remove(key);
        }
      }
    } finally {
      progress(null);
    }
    // No registo, o ecrã principal abre sozinho quando a conta fica completa.
    if (!widget.onboarding) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    final onVehicleStep = widget.onboarding && _step == 1;
    return PopScope(
      // No passo da viatura, "voltar" regressa ao passo da carta.
      canPop: !onVehicleStep,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && onVehicleStep) setState(() => _step = 0);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: onVehicleStep
              ? IconButton(
                  tooltip: 'Voltar à carta de condução',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _step = 0),
                )
              : null,
          title: Text(
            widget.onboarding ? 'Registo de motorista' : 'Carta de condução',
          ),
          actions: [
            if (widget.onboarding)
              TextButton(onPressed: session.logout, child: const Text('Sair')),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (widget.onboarding) ...[
                _StepHeader(
                  step: _step + 1,
                  title: onVehicleStep ? 'A sua viatura' : 'Você e a sua carta',
                  subtitle: onVehicleStep
                      ? 'A viatura com que vai conduzir e os documentos dela. Depois pode acrescentar outras.'
                      : 'A sua foto, os dados da carta tal como lá estão, e a fotografia dos dois lados.',
                ),
                const SizedBox(height: 16),
              ] else
                _licenseStatus(session.user?.license),
              if (onVehicleStep) ...[
                VehicleFields(controller: _vehicle),
                const SizedBox(height: 20),
                _vehicleDocsSection(session),
                const SizedBox(height: 24),
                AsyncButton(
                  label: _progress ?? 'Concluir registo',
                  onPressed: _progress == null ? _save : null,
                ),
              ] else ...[
                if (widget.onboarding) _profilePhoto(session),
                ..._licenseFields(session),
                const SizedBox(height: 24),
                AsyncButton(
                  label:
                      _progress ??
                      (widget.onboarding ? 'Continuar' : 'Guardar'),
                  onPressed: _progress != null
                      ? null
                      : (widget.onboarding ? _next : _save),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Estado da revisão da carta, no ecrã de edição.
  Widget _licenseStatus(License? license) {
    if (license == null || !license.hasFront || !license.hasBack)
      return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReviewChip(status: license.status),
          if (license.status == 'rejected' && license.reviewNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Motivo: ${license.reviewNote}',
                style: const TextStyle(color: BazaColors.red),
              ),
            ),
          const SizedBox(height: 4),
          const Text(
            'Se alterar o número ou as fotos, a carta volta a ser analisada.',
            style: TextStyle(color: BazaColors.muted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// Documentos da viatura activa que já estão no servidor.
  Set<String> _uploadedDocs(Vehicle? v) => {
    if (v?.hasRegistration ?? false) 'registration',
    if (v?.hasOwnership ?? false) 'ownership',
    if (v?.hasInsurance ?? false) 'insurance',
  };

  Widget _vehicleDocsSection(Session session) {
    final active = session.user?.vehicles.where((v) => v.active).firstOrNull;
    return VehicleDocsSection(
      picked: _vehicleDocs,
      uploaded: _uploadedDocs(active),
      loadUploaded: active?.id == null
          ? null
          : (doc) =>
                session.api.getBytes('/documents/vehicles/${active!.id}/$doc'),
      showErrors: _showDocErrors,
      onPicked: (doc, photo) => setState(() => _vehicleDocs[doc] = photo),
    );
  }

  /// Foto de perfil do motorista: obrigatória, para o passageiro o reconhecer.
  Widget _profilePhoto(Session session) {
    final user = context.watch<Session>().user;
    final hasPhoto = user?.photoUrl != null;
    return Column(
      children: [
        Semantics(
          button: true,
          label: hasPhoto
              ? 'Foto de perfil adicionada, toque para trocar'
              : 'Adicionar foto de perfil',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () async {
              await changeProfilePhoto(context);
              if (mounted && session.user?.photoUrl != null)
                setState(() => _photoError = null);
            },
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _photoError != null
                          ? BazaColors.red
                          : (hasPhoto
                                ? BazaColors.green
                                : const Color(0xFFD1D5DB)),
                      width: 3,
                    ),
                  ),
                  child: hasPhoto
                      ? Avatar(
                          name: user!.name,
                          photoUrl: user.photoUrl,
                          radius: 48,
                        )
                      : const CircleAvatar(
                          radius: 48,
                          backgroundColor: BazaColors.surface,
                          foregroundColor: BazaColors.ink,
                          child: Icon(Icons.add_a_photo_outlined, size: 32),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _photoError ??
              (hasPhoto
                  ? 'Foto de perfil · toque para trocar'
                  : 'Adicionar foto de perfil'),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: _photoError != null ? BazaColors.red : BazaColors.ink,
          ),
        ),
        const Text(
          'O rosto bem visível, sem óculos escuros. Os passageiros vêem esta foto.',
          textAlign: TextAlign.center,
          style: TextStyle(color: BazaColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  List<Widget> _licenseFields(Session session) {
    final expiry = _licenseExpiry;
    final license = session.user?.license;
    return [
      TextField(
        controller: _licenseNumber,
        focusNode: _numberFocus,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        onChanged: (_) {
          if (_numberError != null) setState(() => _numberError = null);
        },
        decoration: InputDecoration(
          labelText: 'Número da carta de condução',
          hintText: 'Ex.: LD-123456',
          prefixIcon: const Icon(Icons.badge_outlined),
          errorText: _numberError,
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _licenseCategory,
        textCapitalization: TextCapitalization.characters,
        onChanged: (_) {
          if (_categoryError != null) setState(() => _categoryError = null);
        },
        decoration: InputDecoration(
          labelText: 'Categoria',
          hintText: 'Ex.: B',
          prefixIcon: const Icon(Icons.category_outlined),
          errorText: _categoryError,
        ),
      ),
      const SizedBox(height: 12),
      Semantics(
        button: true,
        label: 'Validade da carta de condução',
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _pickExpiry,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Validade',
              prefixIcon: const Icon(Icons.event_outlined),
              suffixIcon: const Icon(Icons.expand_more),
              errorText: _expiryError,
            ),
            child: Text(
              expiry == null ? 'Escolher data' : dateOnly(expiry),
              style: TextStyle(
                fontSize: 16,
                color: expiry == null ? BazaColors.muted : BazaColors.ink,
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 20),
      const Text(
        'Fotos da carta',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: DocumentPhotoTile(
              label: 'Frente da carta',
              picked: _front,
              uploaded: license?.hasFront ?? false,
              loadUploaded: () =>
                  session.api.getBytes('/documents/license/front'),
              errorText: _frontError,
              onPicked: (p) => setState(() {
                _front = p;
                _frontError = null;
              }),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DocumentPhotoTile(
              label: 'Verso da carta',
              picked: _back,
              uploaded: license?.hasBack ?? false,
              loadUploaded: () =>
                  session.api.getBytes('/documents/license/back'),
              errorText: _backError,
              onPicked: (p) => setState(() {
                _back = p;
                _backError = null;
              }),
            ),
          ),
        ],
      ),
    ];
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.step,
    required this.title,
    required this.subtitle,
  });
  final int step;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          for (var i = 1; i <= 2; i++)
            Expanded(
              child: Container(
                height: 5,
                margin: EdgeInsets.only(right: i == 1 ? 6 : 0),
                decoration: BoxDecoration(
                  color: i <= step ? BazaColors.yellow : BazaColors.surface,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      Text(
        'Passo $step de 2',
        style: const TextStyle(
          color: BazaColors.muted,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        title,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 4),
      Text(
        subtitle,
        style: const TextStyle(color: BazaColors.muted, fontSize: 15),
      ),
    ],
  );
}
