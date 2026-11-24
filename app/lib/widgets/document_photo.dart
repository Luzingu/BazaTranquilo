import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/theme.dart';

/// Uma fotografia escolhida pelo utilizador, ainda por enviar.
class PickedPhoto {
  const PickedPhoto(this.bytes, this.contentType);
  final Uint8List bytes;
  final String contentType;
}

/// Substitui a escolha de imagem nos testes (onde não há câmara nem galeria).
@visibleForTesting
Future<PickedPhoto?> Function()? pickPhotoOverride;

/// Pergunta de onde vem a foto (câmara ou galeria) e devolve-a já reduzida.
Future<PickedPhoto?> pickDocumentPhoto(
  BuildContext context, {
  required String title,
}) async {
  if (pickPhotoOverride != null) return pickPhotoOverride!();
  final source = await showModalBottomSheet<ImageSource>(
    isDismissible: false,
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'A foto deve estar nítida, sem reflexos e com o documento inteiro visível.',
              textAlign: TextAlign.center,
              style: TextStyle(color: BazaColors.muted),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Tirar foto'),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Escolher da galeria'),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null) return null;
  // Reduz a imagem: continua legível e envia-se depressa com dados móveis.
  final file = await ImagePicker().pickImage(
    source: source,
    maxWidth: 1800,
    maxHeight: 1800,
    imageQuality: 85,
  );
  if (file == null) return null;
  return PickedPhoto(await file.readAsBytes(), file.mimeType ?? 'image/jpeg');
}

/// Cartão para fotografar um documento. Mostra a foto escolhida, ou a que já
/// está no servidor (carregada por [loadUploaded]), ou o convite para a tirar.
class DocumentPhotoTile extends StatefulWidget {
  const DocumentPhotoTile({
    super.key,
    required this.label,
    required this.onPicked,
    this.picked,
    this.uploaded = false,
    this.loadUploaded,
    this.errorText,
    this.height = 132,
  });

  /// Ex.: "Frente da carta".
  final String label;
  final ValueChanged<PickedPhoto> onPicked;
  final PickedPhoto? picked;

  /// Se já existe uma foto deste documento no servidor.
  final bool uploaded;
  final Future<Uint8List> Function()? loadUploaded;
  final String? errorText;
  final double height;

  @override
  State<DocumentPhotoTile> createState() => _DocumentPhotoTileState();
}

class _DocumentPhotoTileState extends State<DocumentPhotoTile> {
  Future<Uint8List>? _remote;

  @override
  void initState() {
    super.initState();
    if (widget.uploaded) _remote = widget.loadUploaded?.call();
  }

  Future<void> _pick() async {
    try {
      final photo = await pickDocumentPhoto(context, title: widget.label);
      if (photo != null) widget.onPicked(photo);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Não foi possível obter a fotografia. Tente de novo.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final picked = widget.picked;
    final hasPhoto = picked != null || widget.uploaded;
    final error = widget.errorText;
    final border = error != null
        ? BazaColors.red
        : hasPhoto
        ? BazaColors.green
        : const Color(0xFFD1D5DB);

    Widget preview(Uint8List bytes) =>
        Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          label:
              '${widget.label}: ${hasPhoto ? 'foto adicionada, toque para trocar' : 'toque para fotografar'}',
          child: Material(
            color: BazaColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: border,
                width: hasPhoto || error != null ? 1.8 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _pick,
              child: SizedBox(
                height: widget.height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (picked != null)
                      preview(picked.bytes)
                    else if (_remote != null)
                      FutureBuilder<Uint8List>(
                        future: _remote,
                        builder: (context, snap) => snap.hasData
                            ? preview(snap.data!)
                            : Center(
                                child: snap.hasError
                                    ? const Icon(
                                        Icons.image_outlined,
                                        color: BazaColors.muted,
                                        size: 32,
                                      )
                                    : const CircularProgressIndicator(
                                        color: BazaColors.ink,
                                        strokeWidth: 2.5,
                                      ),
                              ),
                      )
                    else if (!hasPhoto)
                      const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_a_photo_outlined,
                            size: 30,
                            color: BazaColors.ink,
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Fotografar',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    if (hasPhoto)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: BazaColors.green,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check, size: 14, color: Colors.white),
                              SizedBox(width: 4),
                              Text(
                                'Trocar',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          error ?? widget.label,
          maxLines: 2,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: error != null ? BazaColors.red : BazaColors.ink,
          ),
        ),
      ],
    );
  }
}

/// Etiqueta com o estado da revisão de um documento.
class ReviewChip extends StatelessWidget {
  const ReviewChip({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status) {
      'approved' => ('Aprovado', BazaColors.green, Icons.verified_outlined),
      'rejected' => ('Rejeitado', BazaColors.red, Icons.error_outline),
      _ => ('Em análise', const Color(0xFFB45309), Icons.hourglass_top),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Os documentos que cada viatura tem de ter: chave usada na API e nome a mostrar.
const vehicleDocuments = <(String, String)>[
  ('registration', 'Livrete'),
  ('ownership', 'Título de propriedade'),
  ('insurance', 'Seguro'),
];

/// Os três cartões de fotografia dos documentos de uma viatura.
class VehicleDocsSection extends StatelessWidget {
  const VehicleDocsSection({
    super.key,
    required this.picked,
    required this.onPicked,
    this.uploaded = const {},
    this.loadUploaded,
    this.showErrors = false,
  });

  /// Fotos escolhidas neste ecrã e ainda por enviar, por documento.
  final Map<String, PickedPhoto> picked;
  final void Function(String doc, PickedPhoto photo) onPicked;

  /// Documentos que já estão no servidor.
  final Set<String> uploaded;
  final Future<Uint8List> Function(String doc)? loadUploaded;

  /// Marca a vermelho os documentos em falta (depois de se tentar guardar).
  final bool showErrors;

  /// Documentos ainda sem foto, pelo nome a mostrar.
  static List<String> missing(
    Map<String, PickedPhoto> picked,
    Set<String> uploaded,
  ) => [
    for (final (key, label) in vehicleDocuments)
      if (!picked.containsKey(key) && !uploaded.contains(key)) label,
  ];

  @override
  Widget build(BuildContext context) {
    Widget tile(String key, String label) => DocumentPhotoTile(
      label: label,
      height: 104,
      picked: picked[key],
      uploaded: uploaded.contains(key),
      loadUploaded: loadUploaded == null ? null : () => loadUploaded!(key),
      errorText:
          showErrors && !picked.containsKey(key) && !uploaded.contains(key)
          ? 'Falta: $label'
          : null,
      onPicked: (photo) => onPicked(key, photo),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Documentos da viatura',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Fotografe o livrete, o título de propriedade e o seguro em vigor.',
          style: TextStyle(color: BazaColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, (key, label)) in vehicleDocuments.indexed) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(child: tile(key, label)),
            ],
          ],
        ),
      ],
    );
  }
}
