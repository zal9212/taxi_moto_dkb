import 'package:flutter/material.dart';

import '../services/database_service.dart';

/// Demande une nouvelle devise et l'ajoute a la liste (normalisee, sans
/// doublon). Retourne le code enregistre, ou null si annule.
Future<String?> ajouterDeviseDialogue(BuildContext context) async {
  final ctrl = TextEditingController();
  final saisie = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Nouvelle devise'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(labelText: 'Ex: FG, FCFA, USD'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        ElevatedButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Ajouter')),
      ],
    ),
  );
  if (saisie == null) return null;
  return DatabaseService.instance.ajouterDevise(saisie);
}

/// Menu des devises de la liste (saisies une fois, puis simplement
/// choisies), avec "+ Ajouter une devise..." en dernier choix. La valeur
/// actuelle reste proposee meme si elle a ete retiree de la liste.
class ChampDevise extends StatefulWidget {
  final String? valeur;
  final ValueChanged<String> onChanged;
  final String label;

  const ChampDevise({super.key, required this.valeur, required this.onChanged, this.label = 'Devise'});

  @override
  State<ChampDevise> createState() => _ChampDeviseState();
}

class _ChampDeviseState extends State<ChampDevise> {
  static const _ajouter = '__ajouter__';
  List<String> _devises = [];
  // Change apres un ajout annule pour reafficher la valeur precedente.
  int _version = 0;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final devises = await DatabaseService.instance.listerDevises();
    if (mounted) setState(() => _devises = devises);
  }

  Future<void> _nouvelle() async {
    final code = await ajouterDeviseDialogue(context);
    if (code == null) {
      if (mounted) setState(() => _version++);
      return;
    }
    await _charger();
    widget.onChanged(code);
  }

  @override
  Widget build(BuildContext context) {
    final valeur = (widget.valeur?.isEmpty ?? true) ? null : widget.valeur;
    final options = {..._devises, if (valeur != null) valeur}.toList()..sort();
    return DropdownButtonFormField<String>(
      key: ValueKey('$valeur-$_version-${options.length}'),
      initialValue: valeur,
      decoration: InputDecoration(labelText: widget.label),
      items: [
        for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
        const DropdownMenuItem(value: _ajouter, child: Text('+ Ajouter une devise...')),
      ],
      onChanged: (v) {
        if (v == _ajouter) {
          _nouvelle();
        } else if (v != null) {
          widget.onChanged(v);
        }
      },
      validator: (v) => (v == null || v == _ajouter) ? 'Choisissez une devise' : null,
    );
  }
}
