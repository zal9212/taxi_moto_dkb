import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../models/categorie_champ.dart';

/// Affiche l'input adapte au type d'un [CategorieChamp] (texte, montant,
/// date, ou choix dans une liste), et remonte la valeur saisie (toujours
/// en texte brut, ex: une date en ISO8601) via [onChanged].
class ChampPersonnaliseField extends StatefulWidget {
  final CategorieChamp champ;
  final String? valeurInitiale;
  final ValueChanged<String?> onChanged;

  const ChampPersonnaliseField({
    super.key,
    required this.champ,
    this.valeurInitiale,
    required this.onChanged,
  });

  @override
  State<ChampPersonnaliseField> createState() => _ChampPersonnaliseFieldState();
}

class _ChampPersonnaliseFieldState extends State<ChampPersonnaliseField> {
  late final TextEditingController _controleur;
  DateTime? _date;
  String? _choix;

  @override
  void initState() {
    super.initState();
    _controleur = TextEditingController(text: widget.valeurInitiale ?? '');
    if (widget.champ.type == AppConstants.typeChampDate && widget.valeurInitiale != null) {
      _date = DateTime.tryParse(widget.valeurInitiale!);
    }
    if (widget.champ.type == AppConstants.typeChampListe) {
      _choix = widget.valeurInitiale;
    }
  }

  @override
  void dispose() {
    _controleur.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.champ.type) {
      case AppConstants.typeChampMontant:
        return TextFormField(
          controller: _controleur,
          decoration: InputDecoration(labelText: widget.champ.nom),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (v) => widget.onChanged(v.trim().isEmpty ? null : v.trim()),
        );

      case AppConstants.typeChampDate:
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(widget.champ.nom, style: const TextStyle(fontSize: 13)),
          subtitle: Text(_date != null
              ? '${_date!.day.toString().padLeft(2, '0')}/${_date!.month.toString().padLeft(2, '0')}/${_date!.year}'
              : 'Non renseigne'),
          trailing: const Icon(Icons.calendar_today_outlined, size: 18),
          onTap: () async {
            final choisie = await showDatePicker(
              context: context,
              initialDate: _date ?? DateTime.now(),
              firstDate: DateTime(2015),
              lastDate: DateTime(2100),
            );
            if (choisie != null) {
              setState(() => _date = choisie);
              widget.onChanged(choisie.toIso8601String());
            }
          },
        );

      case AppConstants.typeChampListe:
        final options = widget.champ.options ?? [];
        return DropdownButtonFormField<String>(
          initialValue: _choix,
          decoration: InputDecoration(labelText: widget.champ.nom),
          items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
          onChanged: (v) {
            setState(() => _choix = v);
            widget.onChanged(v);
          },
        );

      case AppConstants.typeChampTexte:
      default:
        return TextFormField(
          controller: _controleur,
          decoration: InputDecoration(labelText: widget.champ.nom),
          onChanged: (v) => widget.onChanged(v.trim().isEmpty ? null : v.trim()),
        );
    }
  }
}
