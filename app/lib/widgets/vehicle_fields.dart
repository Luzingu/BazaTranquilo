import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';

/// Campos de uma viatura (tipo, marca, modelo, cor, matrícula), partilhados
/// pelo registo de motorista e pela garagem.
class VehicleFieldsController {
  VehicleFieldsController([Vehicle? v])
    : make = TextEditingController(text: v?.make),
      model = TextEditingController(text: v?.carModel),
      color = TextEditingController(text: v?.color),
      plate = TextEditingController(text: v?.plate),
      category = ValueNotifier(v?.category ?? 'economy'),
      hasAC = ValueNotifier(v?.hasAC ?? false),
      insuranceExpiry = ValueNotifier(v?.insuranceExpiresAt);

  final TextEditingController make, model, color, plate;
  final ValueNotifier<String> category;
  final ValueNotifier<bool> hasAC;

  /// Validade do seguro da viatura.
  final ValueNotifier<DateTime?> insuranceExpiry;

  /// Devolve a viatura preenchida ou lança a mensagem de erro a mostrar.
  Vehicle read() {
    final t = [make, model, color, plate].map((c) => c.text.trim()).toList();
    if (t.any((f) => f.isEmpty) || t[3].length < 3)
      throw 'Preencha os dados da viatura.';

    final insurance = insuranceExpiry.value;
    if (insurance == null) throw 'Indique a validade do seguro da viatura.';
    return Vehicle(
      make: t[0],
      carModel: t[1],
      color: t[2],
      plate: t[3].toUpperCase(),
      category: category.value,
      hasAC:
          acCategories.contains(category.value) &&
          (hasAC.value || category.value == 'comfort'),
      // Válido até ao fim do dia indicado.
      insuranceExpiresAt: DateTime(
        insurance.year,
        insurance.month,
        insurance.day,
        23,
        59,
      ),
    );
  }

  void dispose() {
    for (final c in [make, model, color, plate]) {
      c.dispose();
    }
    category.dispose();
    hasAC.dispose();
    insuranceExpiry.dispose();
  }
}

class VehicleFields extends StatelessWidget {
  const VehicleFields({super.key, required this.controller});
  final VehicleFieldsController controller;

  Future<void> _pickCategory(BuildContext context) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  'Que tipo de viatura é?',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              for (final (title, keys) in const [
                ('Transporte de passageiros', passengerCategories),
                ('Carga e entregas', cargoCategories),
              ]) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: BazaColors.muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final key in keys)
                  ListTile(
                    leading: Icon(categoryIcons[key], color: BazaColors.ink),
                    title: Text(categoryLabels[key]!),
                    subtitle: Text(categoryHints[key]!),
                    trailing: key == controller.category.value
                        ? const Icon(Icons.check, color: BazaColors.green)
                        : null,
                    onTap: () => Navigator.pop(context, key),
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) controller.category.value = chosen;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ValueListenableBuilder<String>(
          valueListenable: controller.category,
          builder: (context, category, _) => InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _pickCategory(context),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Tipo de viatura',
                suffixIcon: Icon(Icons.expand_more),
              ),
              child: Row(
                children: [
                  Icon(categoryIcons[category], size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      categoryLabels[category] ?? category,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: controller.make,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Marca',
            hintText: 'Toyota',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: controller.model,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Modelo',
            hintText: 'Corolla',
          ),
        ),
        const SizedBox(height: 12),
        _ColorField(controller: controller.color),
        const SizedBox(height: 12),
        TextField(
          controller: controller.plate,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Matrícula',
            hintText: 'LD-12-34-AB',
          ),
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<DateTime?>(
          valueListenable: controller.insuranceExpiry,
          builder: (context, expiry, _) => Semantics(
            button: true,
            label: 'Validade do seguro',
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  helpText: 'Validade do seguro da viatura',
                  initialDate: expiry != null && expiry.isAfter(now)
                      ? expiry
                      : now,
                  firstDate: now,
                  lastDate: DateTime(now.year + 5),
                );
                if (picked != null) controller.insuranceExpiry.value = picked;
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Validade do seguro',
                  prefixIcon: Icon(Icons.verified_user_outlined),
                  suffixIcon: Icon(Icons.expand_more),
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
        ),
        // Ar condicionado: só nos veículos fechados.
        ListenableBuilder(
          listenable: Listenable.merge([controller.category, controller.hasAC]),
          builder: (context, _) {
            final category = controller.category.value;
            if (!acCategories.contains(category))
              return const SizedBox.shrink();
            final comfort = category == 'comfort';
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Material(
                color: BazaColors.surface,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: SwitchListTile(
                  secondary: const Icon(Icons.ac_unit),
                  title: const Text('Tem ar condicionado'),
                  subtitle: Text(
                    comfort
                        ? 'Modo conforto activo: recebe pedidos Conforto e também Económico.'
                        : category == 'economy'
                        ? 'Com ar condicionado a viatura passa a Conforto e recebe pedidos Conforto e Económico.'
                        : 'Os passageiros vêem esta informação.',
                  ),
                  activeThumbColor: BazaColors.ink,
                  activeTrackColor: BazaColors.yellow,
                  value: comfort || controller.hasAC.value,
                  onChanged: (v) {
                    controller.hasAC.value = v;
                    // O ar condicionado é o que distingue Conforto de Económico:
                    // ligá-lo activa o modo conforto, desligá-lo volta a Económico.
                    if (v && category == 'economy')
                      controller.category.value = 'comfort';
                    if (!v && comfort) controller.category.value = 'economy';
                  },
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Escolha da cor da viatura a partir de uma lista, para o passageiro ver o
/// ícone da viatura na cor certa.
class _ColorField extends StatelessWidget {
  const _ColorField({required this.controller});
  final TextEditingController controller;

  static Widget _swatch(Color color, {double size = 26}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: const Color(0xFF9CA3AF)),
    ),
  );

  Future<void> _pick(BuildContext context) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Cor da viatura',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in vehicleColors.entries)
                    ActionChip(
                      avatar: _swatch(entry.value, size: 20),
                      label: Text(entry.key),
                      backgroundColor: entry.key == controller.text
                          ? BazaColors.yellow.withValues(alpha: 0.3)
                          : Colors.white,
                      side: BorderSide(
                        color: entry.key == controller.text
                            ? BazaColors.ink
                            : const Color(0xFFD1D5DB),
                      ),
                      onPressed: () => Navigator.pop(context, entry.key),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) controller.text = chosen;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _pick(context),
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Cor',
            suffixIcon: Icon(Icons.expand_more),
          ),
          child: Row(
            children: [
              if (value.text.isNotEmpty) ...[
                _swatch(vehicleColor(value.text), size: 22),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  value.text.isEmpty ? 'Escolher cor' : value.text,
                  style: TextStyle(
                    fontSize: 16,
                    color: value.text.isEmpty
                        ? BazaColors.muted
                        : BazaColors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
