import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/moto.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../services/schedule_service.dart';
import '../utils/formatters.dart';

/// Formulaire de création/édition d'une moto. Rien n'est en liste fermée :
/// la fréquence propose 3 modes (hebdomadaire / mensuelle / personnalisée)
/// et chacun a son propre paramètre libre. Il n'y a pas de montant total à
/// rembourser : le versement est récurrent et indéfini tant que la moto
/// est active.
class AddEditMotoScreen extends StatefulWidget {
  final Moto? motoExistante;
  const AddEditMotoScreen({super.key, this.motoExistante});

  @override
  State<AddEditMotoScreen> createState() => _AddEditMotoScreenState();
}

class _AddEditMotoScreenState extends State<AddEditMotoScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseService.instance;

  late final TextEditingController _nomCtrl;
  late final TextEditingController _chauffeurCtrl;
  late final TextEditingController _montantVersementCtrl;
  late final TextEditingController _notesCtrl;

  String _frequenceType = AppConstants.freqHebdomadaire;
  int _jourSemaine = DateTime.monday;
  int _jourMois = 1;
  int _intervalleJours = 7;
  /// Date du 1er versement (sans l'heure).
  DateTime _dateDebut = ScheduleService.aujourdHui();
  /// En creation, tant que la date n'est pas choisie a la main, elle suit
  /// la frequence (voir [_majDateParDefaut]).
  bool _dateDebutChoisie = false;
  String _statut = AppConstants.motoActive;
  /// Date a partir de laquelle un nouveau montant de versement s'applique
  /// (voir [DatabaseService.changerMontant]).
  DateTime _montantDepuis = ScheduleService.aujourdHui();
  /// Changements de montant deja enregistres (passes et prevus).
  List<ChangementMontant> _changements = [];
  /// Montant en vigueur aujourd'hui (en edition) : celui qu'affiche le champ.
  double? _montantActuel;

  bool get _modeEdition => widget.motoExistante != null;

  bool get _montantChange {
    final montant = lireMontant(_montantVersementCtrl.text);
    return _modeEdition && montant != null && montant != _montantActuel;
  }

  /// Changement deja prevu apres [jour] : le nouveau montant s'arrete la.
  ChangementMontant? _changementApres(DateTime jour) {
    for (final c in _changements) {
      if (c.depuis.isAfter(jour)) return c;
    }
    return null;
  }
  bool _enregistrement = false;

  @override
  void initState() {
    super.initState();
    final m = widget.motoExistante;
    _nomCtrl = TextEditingController(text: m?.nom ?? '');
    _chauffeurCtrl = TextEditingController(text: m?.chauffeur ?? '');
    _montantVersementCtrl = TextEditingController(text: m?.montantVersement.toStringAsFixed(0) ?? '');
    _notesCtrl = TextEditingController(text: m?.notes ?? '');

    if (m == null) {
      _majDateParDefaut();
    } else {
      _frequenceType = m.frequenceType;
      _dateDebut = ScheduleService.dateSeule(m.dateDebut);
      _dateDebutChoisie = true;
      _statut = m.statut;
      _montantActuel = m.montantVersement;
      _chargerChangements();
      switch (m.frequenceType) {
        case AppConstants.freqHebdomadaire:
          _jourSemaine = m.frequenceValeur;
          break;
        case AppConstants.freqMensuelle:
          _jourMois = m.frequenceValeur;
          break;
        case AppConstants.freqPersonnalisee:
          _intervalleJours = m.frequenceValeur;
          break;
      }
    }
  }

  /// Le champ montant affiche le montant en vigueur aujourd'hui, pas le
  /// montant de depart de la moto.
  Future<void> _chargerChangements() async {
    final m = widget.motoExistante!;
    final changements = await _db.listerChangementsMontant(m.id!);
    if (!mounted) return;
    final actuel = ScheduleService.montantAu(m, changements, ScheduleService.aujourdHui());
    setState(() {
      // Ne pas ecraser un montant deja tape entre-temps.
      if (lireMontant(_montantVersementCtrl.text) == _montantActuel) {
        _montantVersementCtrl.text = actuel.toStringAsFixed(0);
      }
      _changements = changements;
      _montantActuel = actuel;
    });
  }

  /// Annule tout de suite un changement de montant (saisi par erreur, ou
  /// prevu et abandonne) : sa periode reprend le montant d'avant.
  Future<void> _supprimerChangement(ChangementMontant c) async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Annuler ce changement ?'),
        content: Text('Le passage a ${formaterNombre(c.montant)} du ${formaterDate(c.depuis)} sera annule '
            'tout de suite : ses echeances reprennent le montant d\'avant et le solde sera recalcule.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Garder')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Annuler le changement')),
        ],
      ),
    );
    if (confirme != true) return;
    final moto = widget.motoExistante!;
    await _db.supprimerChangementMontant(moto.id!, c.depuis);
    await _planifierNotifications(moto);
    await _chargerChangements();
  }

  int get _frequenceValeur {
    switch (_frequenceType) {
      case AppConstants.freqHebdomadaire:
        return _jourSemaine;
      case AppConstants.freqMensuelle:
        return _jourMois;
      case AppConstants.freqPersonnalisee:
        return _intervalleJours;
      default:
        return 1;
    }
  }

  /// En creation, propose comme 1er versement le prochain jour qui respecte
  /// la frequence (ex: le prochain lundi) tant que l'utilisateur n'a pas
  /// choisi une date lui-meme.
  void _majDateParDefaut() {
    if (_dateDebutChoisie) return;
    _dateDebut = ScheduleService.premiereEcheance(
      dateDebut: ScheduleService.aujourdHui(),
      type: _frequenceType,
      valeur: _frequenceValeur,
    );
  }

  Future<void> _enregistrer() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _enregistrement = true);

    try {
      final montantVersement = lireMontant(_montantVersementCtrl.text)!;

      final moto = Moto(
        id: widget.motoExistante?.id,
        nom: _nomCtrl.text.trim(),
        chauffeur: _chauffeurCtrl.text.trim(),
        // En edition, le montant de depart ne change pas : un nouveau
        // montant s'enregistre dans l'historique (voir plus bas).
        montantVersement: widget.motoExistante?.montantVersement ?? montantVersement,
        frequenceType: _frequenceType,
        frequenceValeur: _frequenceValeur,
        dateDebut: _dateDebut,
        statut: _statut,
        dateCreation: widget.motoExistante?.dateCreation,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      );

      if (!_modeEdition) {
        final id = await _db.insererMoto(moto);
        final motoAvecId = moto.copyWith(id: id);
        await _db.assurerEcheances(motoAvecId);
        await _planifierNotifications(motoAvecId);
      } else {
        final ancien = widget.motoExistante!;
        final dateDebutChangee = !DateUtils.isSameDay(ancien.dateDebut, _dateDebut);
        final montantChange = _montantChange;
        // Le montant ne replanifie rien : il s'applique depuis sa date de
        // mise en vigueur (voir [DatabaseService.changerMontant]).
        final planChange = dateDebutChangee ||
            ancien.frequenceType != _frequenceType ||
            ancien.frequenceValeur != _frequenceValeur;
        final active = _statut == AppConstants.motoActive;
        final reactivee = active && ancien.statut != AppConstants.motoActive;
        // Une moto suspendue/archivee garde ses echeances telles quelles :
        // elles sont recalculees a sa reactivation. Une reactivation sans
        // nouvelle date de debut suit la meme regle que "Reactiver" depuis
        // la fiche moto.
        final replanifier = active && planChange && (dateDebutChangee || !reactivee);

        final messages = <String>[];
        if (replanifier) {
          if (dateDebutChangee) {
            // Apercu exact de ce qui sera ajoute (meme calcul que l'enregistrement).
            final plan = ScheduleService.replanifier(
              existants: await _db.listerVersementsParMoto(moto.id!),
              moto: moto,
              depuisDateDebut: true,
              aujourdHui: ScheduleService.aujourdHui(),
            );
            final passees = plan.aCreer.where((d) => d.isBefore(ScheduleService.aujourdHui())).toList();
            messages.add('${passees.isEmpty ? '' : '${passees.length} echeance(s) passee(s) seront ajoutee(s) en retard : '
                '${passees.map(formaterDate).join(', ')}.\n\n'}'
                'Les echeances a venir suivront la frequence a partir du ${formaterDate(_dateDebut)}. '
                'Aucun versement paye, retard ou dette ne sera supprime.');
          } else {
            messages.add('Le changement de frequence prendra effet au prochain versement prevu. Les versements '
                'deja payes, les retards et les dettes ne changent pas.');
          }
        }
        if (montantChange) {
          final suivant = _changementApres(_montantDepuis);
          messages.add('Le versement passe a ${formaterNombre(montantVersement)} a partir du '
              '${formaterDate(_montantDepuis)}'
              '${suivant == null ? '' : ', jusqu\'au ${formaterDate(suivant.depuis)} (changement deja prevu)'}. '
              'Les echeances de cette periode prennent ce montant, meme celles deja passees ou payees : '
              'le solde sera recalcule. Les echeances d\'avant et les dettes ne changent pas.');
        }
        if (messages.isNotEmpty) {
          if (!mounted) return;
          final confirme = await _confirmerReplanification(messages.join('\n\n'));
          if (!confirme) {
            if (mounted) setState(() => _enregistrement = false);
            return;
          }
        }

        await _db.modifierMoto(moto);
        // Avant la replanification : les echeances recreees prennent le
        // montant en vigueur a leur date, nouveau changement compris.
        if (montantChange) await _db.changerMontant(moto.id!, montantVersement, _montantDepuis);
        // Les rappels suivent dans _planifierNotifications (seulement ce qui change).
        if (replanifier || reactivee) {
          if (replanifier) {
            await _db.replanifierEcheances(moto, depuisDateDebut: dateDebutChangee);
          } else {
            await _db.redemarrerEcheancesApresReactivation(moto);
          }
        }
        await _planifierNotifications(moto);
      }

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _enregistrement = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur lors de l\'enregistrement : $e')),
      );
    }
  }

  /// Plus de choix "garder les echeances telles quelles" : c'est ce qui
  /// laissait la moto sur l'ancien jour (ex: toujours le lundi apres un
  /// passage au mercredi). Annuler ne modifie rien.
  Future<bool> _confirmerReplanification(String message) async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mettre a jour les echeances ?'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirmer')),
        ],
      ),
    );
    return confirme == true;
  }

  Future<void> _planifierNotifications(Moto moto) async {
    if (moto.id == null) return;
    final versements = await _db.listerVersementsParMoto(moto.id!);
    final params = await _db.obtenirParametres();
    await NotificationService.synchroniserRappelsMoto(
      moto: moto,
      versements: versements,
      delaiHeures: params.delaiNotificationHeures,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_modeEdition ? 'Modifier la moto' : 'Nouvelle moto')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _nomCtrl,
                decoration: const InputDecoration(labelText: 'Nom de la moto'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _chauffeurCtrl,
                decoration: const InputDecoration(labelText: 'Chauffeur'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _montantVersementCtrl,
                decoration: const InputDecoration(labelText: 'Montant par versement'),
                keyboardType: TextInputType.number,
                validator: (v) => lireMontant(v) == null ? 'Montant invalide' : null,
                onChanged: (_) => setState(() {}),
              ),
              if (_montantChange)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Nouveau montant en vigueur depuis le', style: TextStyle(fontSize: 13)),
                  subtitle: Text(formaterDate(_montantDepuis)),
                  trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                  onTap: () async {
                    // Passee (oubli de le faire le jour meme) ou future (changement prevu).
                    final choisie = await showDatePicker(
                      context: context,
                      initialDate: _montantDepuis,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (choisie != null) setState(() => _montantDepuis = ScheduleService.dateSeule(choisie));
                  },
                ),
              if (_changements.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('Changements de montant', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                Text('Depart : ${formaterNombre(widget.motoExistante!.montantVersement)}',
                    style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
                for (final c in _changements)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('A partir du ${formaterDate(c.depuis)} : ${formaterNombre(c.montant)}'
                        '${c.depuis.isAfter(ScheduleService.aujourdHui()) ? ' (prevu)' : ''}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: 'Annuler ce changement',
                      onPressed: () => _supprimerChangement(c),
                    ),
                  ),
              ],
              const SizedBox(height: 20),
              const Text('Frequence de versement', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 8),
              _selecteurFrequenceType(),
              const SizedBox(height: 12),
              _parametreFrequence(),
              const SizedBox(height: 20),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date de debut (1er versement)', style: TextStyle(fontSize: 13)),
                subtitle: Text('${_dateDebut.day}/${_dateDebut.month}/${_dateDebut.year}'),
                trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                onTap: () async {
                  final choisie = await showDatePicker(
                    context: context,
                    initialDate: _dateDebut,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (choisie != null) {
                    setState(() {
                      _dateDebut = ScheduleService.dateSeule(choisie);
                      _dateDebutChoisie = true;
                    });
                  }
                },
              ),
              const Divider(),
              const SizedBox(height: 8),
              TextFormField(
                controller: _notesCtrl,
                decoration: const InputDecoration(labelText: 'Notes (optionnel)'),
                maxLines: 2,
              ),
              if (_modeEdition) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _statut,
                  decoration: const InputDecoration(labelText: 'Statut'),
                  items: const [
                    DropdownMenuItem(value: AppConstants.motoActive, child: Text('Actif')),
                    DropdownMenuItem(value: AppConstants.motoSuspendue, child: Text('Suspendu')),
                    DropdownMenuItem(value: AppConstants.motoArchivee, child: Text('Archive')),
                  ],
                  onChanged: (v) => setState(() => _statut = v!),
                ),
              ],
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: _enregistrement ? null : _enregistrer,
                child: Text(_enregistrement ? 'Enregistrement...' : 'Enregistrer'),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selecteurFrequenceType() {
    Widget puce(String label, String valeur) {
      final actif = _frequenceType == valeur;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() {
            _frequenceType = valeur;
            _majDateParDefaut();
          }),
          child: Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: actif ? AppColors.carteNoire : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: actif ? AppColors.carteNoire : AppColors.bordure),
            ),
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(color: actif ? Colors.white : AppColors.texteGris, fontSize: 11)),
          ),
        ),
      );
    }

    return Row(
      children: [
        puce('Hebdomadaire', AppConstants.freqHebdomadaire),
        puce('Mensuelle', AppConstants.freqMensuelle),
        puce('Personnalisee', AppConstants.freqPersonnalisee),
      ],
    );
  }

  Widget _parametreFrequence() {
    switch (_frequenceType) {
      case AppConstants.freqHebdomadaire:
        return DropdownButtonFormField<int>(
          initialValue: _jourSemaine,
          decoration: const InputDecoration(labelText: 'Jour de la semaine'),
          items: List.generate(
            7,
            (i) => DropdownMenuItem(value: i + 1, child: Text(AppConstants.joursSemaine[i])),
          ),
          onChanged: (v) => setState(() {
            _jourSemaine = v!;
            _majDateParDefaut();
          }),
        );
      case AppConstants.freqMensuelle:
        return DropdownButtonFormField<int>(
          initialValue: _jourMois,
          decoration: const InputDecoration(labelText: 'Jour du mois'),
          items: List.generate(31, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
          onChanged: (v) => setState(() {
            _jourMois = v!;
            _majDateParDefaut();
          }),
        );
      case AppConstants.freqPersonnalisee:
      default:
        return TextFormField(
          initialValue: _intervalleJours.toString(),
          decoration: const InputDecoration(labelText: 'Intervalle en jours (ex: tous les 10 jours)'),
          keyboardType: TextInputType.number,
          // Au moins 1 jour : 0 ou un nombre negatif casserait la suite des echeances.
          validator: (v) => (int.tryParse(v ?? '') ?? 0) < 1 ? 'Au moins 1 jour' : null,
          onChanged: (v) => _intervalleJours = int.tryParse(v) ?? _intervalleJours,
        );
    }
  }
}
