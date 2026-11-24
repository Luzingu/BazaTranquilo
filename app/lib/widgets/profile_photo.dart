import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../state/session.dart';

/// Escolhe (ou remove) a foto de perfil e envia-a para o servidor.
Future<void> changeProfilePhoto(BuildContext context) async {
  final session = context.read<Session>();
  final choice = await showModalBottomSheet<String>(
    isDismissible: false,
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Foto de perfil',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Escolher da galeria'),
            onTap: () => Navigator.pop(context, 'gallery'),
          ),
          if (!kIsWeb)
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Tirar uma foto'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
          // Para motoristas a foto é obrigatória: só se pode trocar.
          if (session.user?.photoUrl != null &&
              !(session.user?.isDriver ?? false))
            ListTile(
              leading: const Icon(Icons.delete_outline, color: BazaColors.red),
              title: const Text('Remover foto'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null) return;
  try {
    if (choice == 'remove') {
      await session.removePhoto();
      return;
    }
    // Reduz a imagem antes de enviar: chega para um avatar e poupa dados.
    final file = await ImagePicker().pickImage(
      source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 85,
    );
    if (file == null) return;
    await session.uploadPhoto(
      await file.readAsBytes(),
      file.mimeType ?? 'image/jpeg',
    );
  } catch (e) {
    if (context.mounted)
      showError(
        context,
        e is Exception ? e : 'Não foi possível usar essa imagem.',
      );
  }
}
