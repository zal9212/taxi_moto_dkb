import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/dette.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../services/pdf_service.dart';
import '../services/schedule_service.dart';
import '../utils/formatters.dart';
import '../utils/messages.dart';
import 'add_edit_moto_screen.dart';
import 'dette/add_edit_dette_screen.dart';
import 'dette/dette_detail_screen.dart';

class MotoDetailScreen extends StatefulWidget {
  final int motoId;
  const MotoDetailScreen({super.key, required this.motoId});

  @override
  State<MotoDetailScreen> createState() => _MotoDetailScreenState();
}

class _MotoDetailScreenState extends State<MotoDetailScreen> {
  final _db = DatabaseService.instance;
  Moto? _moto;
  List<Versement> _versements = [];
  List<ChangementMontant> _changementsMontant = [];
  double _totalVerse = 0;
  /// Part de la caisse venant des remboursements de dettes liees a la moto.
  double _remboursementsDettes = 0;
  /// Retard et avance, separes (voir [ScheduleService.compte]).
  CompteMoto _compte = (retard: 0.0, avance: 0.0);
  String _devise = AppConstants.devisePardDefaut;
  List<Dette> _dettes = [];
  final Map<int, double> _soldeParDette = {};
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    // Roue plein ecran seulement au premier affichage : ensuite les chiffres
    // se mettent a jour sur place (la page reste visible, sans attente).
    final moto = await _db.obtenirMoto(widget.motoId);
    if (moto == null) {
      // Moto supprimee entre-temps (ex: lien depuis une dette vers une moto
      // qui n'existe plus) : referme l'ecran au lieu de rester bloque en
      // chargement infini.
      if (mounted) Navigator.pop(context);
      return;
    }

    // Maintient la fenetre d'echeances a venir pleine (versement recurrent
    // et indefini, pas de montant total a atteindre).
    if (moto.statut == AppConstants.motoActive) {
      await NotificationService.assurerEcheancesEtRappels(moto);
    }

    final versements = await _db.listerVersementsParMoto(widget.motoId);
    final changementsMontant = await _db.listerChangementsMontant(widget.motoId);
    final totalVerse = await _db.totalEncaisse(motoId: widget.motoId);
    final remboursementsDettes = await _db.totalRemboursementsMotos(motoId: widget.motoId);
    // Meme calcul que compteMoto, sur les echeances deja lues (sans relire).
    final compte = ScheduleService.compte(moto, versements, ScheduleService.aujourdHui());
    final params = await _db.obtenirParametres();
    final dettes = await _db.listerDettesParLien(AppConstants.detteLienMoto, widget.motoId);
    // Une seule lecture pour toutes les dettes (pas une par dette).
    final soldes = await _db.soldesDettes();
    _soldeParDette
      ..clear()
      ..addAll({for (final d in dettes) if (d.id != null) d.id!: soldes[d.id] ?? d.montantInitial});

    if (!mounted) return;
    setState(() {
      _moto = moto;
      _versements = versements;
      _changementsMontant = changementsMontant;
      _totalVerse = totalVerse;
      _remboursementsDettes = remboursementsDettes;
      _compte = compte;
      _devise = params.deviseSymbole;
      _dettes = dettes;
      _chargement = false;
    });
  }


  /// Regle du client : toujours la plus ancienne d'abord. Les semaines
  /// [impayees] d'avant doivent etre payees, ou, si elles sont deja
  /// passees, mises en dette (elles restent visibles dans la fiche et dans
  /// Dettes, a marquer payees plus tard). Retourne 'dette', 'payer' ou null.
  Future<String?> _demanderSemainesAnterieures(List<({DateTime date, String etat, double reste})> impayees,
      {required bool payerDAbord}) {
    final aujourdHui = ScheduleService.aujourdHui();
    final detteImpossible = impayees.any((p) => !p.date.isBefore(aujourdHui));
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Semaines anterieures impayees'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('On paie toujours la plus ancienne d\'abord.'),
            const SizedBox(height: 8),
            for (final p in impayees)
              Text('${formaterDate(p.date)} : ${formaterMontant(p.reste, _devise)}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              detteImpossible
                  ? 'Ce versement les paiera d\'abord.'
                  : 'Les passer en dette ? Elles restent visibles dans la fiche et dans Dettes, '
                      'a marquer payees plus tard.',
              style: TextStyle(color: AppColors.texteGris, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          if (payerDAbord)
            TextButton(onPressed: () => Navigator.pop(context, 'payer'), child: const Text('Payer d\'abord celles-ci')),
          if (!detteImpossible)
            ElevatedButton(onPressed: () => Navigator.pop(context, 'dette'), child: const Text('Passer en dette')),
        ],
      ),
    );
  }

  Future<void> _validerVersement(Versement v) async {
    final moto = _moto;
    if (moto == null) return;
    final anterieures = ScheduleService.impayeesAvant(
        existants: _versements, moto: moto, aujourdHui: ScheduleService.aujourdHui(), date: v.dateEcheance);
    var payeesDAbord = false;
    if (anterieures.isNotEmpty) {
      final choix = await _demanderSemainesAnterieures(anterieures, payerDAbord: true);
      if (choix == null) return;
      if (choix == 'dette') {
        for (final p in anterieures) {
          final ancienne = _versements.firstWhere((x) =>
              ScheduleService.dateSeule(x.dateEcheance) == p.date && x.statut != AppConstants.versementEnDette);
          await _db.marquerEnDette(ancienne, moto);
        }
      } else {
        payeesDAbord = true;
      }
    }
    if (!mounted) return;
    // Ce qui reste du (une echeance peut deja avoir recu une partie).
    final controleur = TextEditingController(text: ScheduleService.resteDu(v).toStringAsFixed(0));
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Valider le versement'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Echeance du ${formaterDate(v.dateEcheance)}',
                style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: controleur,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Montant verse',
                helperText: 'Au-dela du montant prevu : avance deduite des echeances suivantes',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 4),
            Text('Modifiable si le chauffeur a verse un montant different',
                style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Valider')),
        ],
      ),
    );

    if (confirme != true) return;
    // Avant, un montant mal lu ("10 000") enregistrait le montant prevu sans rien dire.
    final montant = lireMontant(controleur.text);
    if (montant == null) {
      _signalerMontantInvalide();
      return;
    }
    await _db.validerVersement(v.id!, montantPaye: montant);
    // _charger() complete les echeances et met leurs rappels a jour (seulement
    // ce qui change) si la moto est active.
    _charger();
    if (payeesDAbord && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Versement applique d\'abord aux semaines anterieures (la plus ancienne d\'abord).')));
    }
  }

  /// Semaine passee en dette, payee plus tard : le remboursement entre dans
  /// la caisse de la moto et la ligne passe a "Rembourse".
  Future<void> _rembourserDette(Versement v) async {
    final etat = _detteDe(v.detteId);
    if (v.detteId == null || etat == null || etat.reste <= 0) return;
    final controleur = TextEditingController(text: etat.reste.toStringAsFixed(0));
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Dette du ${formaterDate(v.dateEcheance)} payee'),
        content: TextField(
          controller: controleur,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: 'Montant recu', helperText: 'Reste du : ${formaterMontant(etat.reste, _devise)}'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (confirme != true) return;
    final montant = lireMontant(controleur.text);
    if (montant == null || montant <= 0 || montant > etat.reste) {
      _signalerMontantInvalide();
      return;
    }
    await _db.insererRemboursement(DetteRemboursement(detteId: v.detteId!, montant: montant, date: DateTime.now()));
    _charger();
  }

  /// Echeance non payee -> vraie dette liee a la moto (ecran Dettes). Elle ne
  /// compte plus dans le retard ; ses remboursements vont dans la caisse.
  Future<void> _marquerEnDette(Versement v) async {
    if (_moto == null || v.id == null) return;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Marquer en dette ?'),
        content: Text(
          'Le versement du ${formaterDate(v.dateEcheance)} '
          '(${formaterMontant(ScheduleService.resteDu(v), _devise)}) sera suivi dans Dettes, '
          'lie a cette moto, et ne comptera plus dans le retard. Quand le chauffeur paiera, ajoutez '
          'un remboursement : l\'argent ira dans la caisse de la moto et l\'echeance affichera « Rembourse ».',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Marquer en dette')),
        ],
      ),
    );
    if (confirme != true) return;
    await _db.marquerEnDette(v, _moto!);
    _charger();
  }

  List<({DateTime date, String etat, double reste})> _periodesAPayer() => ScheduleService.periodesAPayer(
        existants: _versements,
        moto: _moto!,
        aujourdHui: ScheduleService.aujourdHui(),
      );

  /// Periodes deja passees et pas soldees (ce que le chauffeur doit).
  List<({DateTime date, String etat, double reste})> _periodesDues() =>
      _periodesAPayer().where((p) => p.date.isBefore(ScheduleService.aujourdHui())).toList();

  /// "Ajouter un versement" : on coche les periodes payees (les dues sont
  /// cochees d'avance ; les suivantes du rythme permettent de payer
  /// d'avance), le montant se remplit avec leur total et reste modifiable.
  /// L'apercu vient du meme calcul que l'enregistrement
  /// ([ScheduleService.affecterVersement]) : ce qu'on voit est ce qui est
  /// enregistre. Puis on peut envoyer le recu.
  Future<void> _encaisserVersement() async {
    final moto = _moto;
    if (moto == null) return;
    final aujourdHui = ScheduleService.aujourdHui();
    final periodes = ScheduleService.periodesChoisissables(
        moto: moto, existants: _versements, changements: _changementsMontant, aujourdHui: aujourdHui);
    if (periodes.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Aucune periode a payer pour le moment.')));
      return;
    }
    final dues = periodes.where((p) => p.date.isBefore(aujourdHui)).map((p) => p.date).toSet();
    final choisies = dues.isNotEmpty ? dues : {periodes.first.date};
    // Semaines deja passees mises de cote : elles passeront en dette (restent
    // visibles, a marquer payees plus tard).
    final enDette = <DateTime>{};
    double totalChoisi() => periodes.where((p) => choisies.contains(p.date)).fold(0, (t, p) => t + p.reste);
    final montantCtrl = TextEditingController(text: totalChoisi().toStringAsFixed(0));
    var montantModifie = false;

    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          final saisi = lireMontant(montantCtrl.text);
          // Apercu exact : les semaines mises de cote comptent deja comme dettes.
          final existants = [
            for (final v in _versements)
              enDette.contains(ScheduleService.dateSeule(v.dateEcheance))
                  ? v.copyWith(statut: AppConstants.versementEnDette)
                  : v,
          ];
          void majMontant() {
            if (!montantModifie) montantCtrl.text = totalChoisi().toStringAsFixed(0);
          }

          final apercu = saisi == null || saisi <= 0
              ? null
              : ScheduleService.affecterVersement(
                  moto: moto,
                  existants: existants,
                  changements: _changementsMontant,
                  aujourdHui: aujourdHui,
                  montant: saisi,
                  choisies: choisies,
                );
          return AlertDialog(
            title: const Text('Ajouter un versement'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Periodes payees', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const Text('La plus ancienne d\'abord : une semaine passee non payee peut etre mise en dette.',
                        style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
                    for (final (i, p) in periodes.indexed)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: choisies.contains(p.date),
                        title: Text('${formaterDate(p.date)} : ${formaterMontant(p.reste, _devise)}',
                            style: enDette.contains(p.date)
                                ? const TextStyle(decoration: TextDecoration.lineThrough)
                                : null),
                        subtitle: Text(enDette.contains(p.date)
                            ? 'Passera en dette (reste visible, a marquer payee plus tard)'
                            : '${p.etat[0].toUpperCase()}${p.etat.substring(1)}'),
                        secondary: enDette.contains(p.date)
                            ? IconButton(
                                icon: const Icon(Icons.undo, size: 18),
                                tooltip: 'Ne pas la passer en dette',
                                onPressed: () => setStateDialog(() {
                                  enDette.remove(p.date);
                                  // Plus de trou : elle est payee avec les suivantes.
                                  if (periodes.skip(i + 1).any((q) => choisies.contains(q.date))) choisies.add(p.date);
                                  majMontant();
                                }),
                              )
                            : null,
                        onChanged: enDette.contains(p.date)
                            ? null
                            : (coche) async {
                                if (coche == true) {
                                  // Cocher une semaine coche celles d'avant (la plus ancienne d'abord).
                                  setStateDialog(() {
                                    for (final q in periodes.take(i + 1)) {
                                      if (!enDette.contains(q.date)) choisies.add(q.date);
                                    }
                                    majMontant();
                                  });
                                  return;
                                }
                                final suivantesCochees = periodes.skip(i + 1).any((q) => choisies.contains(q.date));
                                if (suivantesCochees && p.date.isBefore(aujourdHui)) {
                                  // Sauter une semaine passee : seulement en la mettant en dette.
                                  if (await _demanderSemainesAnterieures([p], payerDAbord: false) != 'dette') return;
                                  setStateDialog(() {
                                    enDette.add(p.date);
                                    choisies.remove(p.date);
                                    majMontant();
                                  });
                                  return;
                                }
                                // Une semaine a venir : on decoche aussi celles d'apres.
                                setStateDialog(() {
                                  for (final q in periodes.skip(i)) {
                                    choisies.remove(q.date);
                                  }
                                  majMontant();
                                });
                              },
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: montantCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: 'Montant recu ($_devise)'),
                      onChanged: (_) => setStateDialog(() => montantModifie = true),
                    ),
                    const SizedBox(height: 12),
                    const Text('Applique sur :', style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
                    const SizedBox(height: 4),
                    if (apercu == null)
                      const Text('Montant invalide', style: TextStyle(color: AppColors.danger, fontSize: 12))
                    else
                      for (final a in apercu)
                        Text(
                          '${formaterDate(a.date)} : ${formaterMontant(a.montant, _devise)}'
                          '${_libelleApresPaiement(periodes, a)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
              ElevatedButton(
                onPressed: apercu == null || apercu.isEmpty ? null : () => Navigator.pop(context, true),
                child: const Text('Enregistrer'),
              ),
            ],
          );
        },
      ),
    );

    if (confirme != true) return;
    final montant = lireMontant(montantCtrl.text);
    if (montant == null || montant <= 0) {
      _signalerMontantInvalide();
      return;
    }
    for (final d in enDette) {
      final v = _versements.firstWhere((v) =>
          ScheduleService.dateSeule(v.dateEcheance) == d && v.statut != AppConstants.versementEnDette);
      await _db.marquerEnDette(v, moto);
    }
    final affectations = await _db.encaisser(moto, montant, choisies: choisies);
    // _charger() met les rappels a jour (ceux des periodes soldees disparaissent).
    await _charger();
    if (!mounted) return;
    final resteDu = _compte.retard; // meme chiffre que la fiche et la relance
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${formaterMontant(montant, _devise)} encaisses.'),
      action: SnackBarAction(
        label: 'Envoyer le recu',
        onPressed: () => Share.share(messageRecu(
          chauffeur: moto.chauffeur,
          moto: moto.nom,
          montant: montant,
          date: DateTime.now(),
          affectations: affectations,
          resteDu: resteDu,
          devise: _devise,
        )),
      ),
    ));
  }

  /// " (solde)", " (partiel, reste X)" ou " (avance)" pour l'apercu.
  String _libelleApresPaiement(
      List<({DateTime date, String etat, double reste})> periodes, ({DateTime date, double montant}) a) {
    final p = periodes.where((p) => p.date == a.date).firstOrNull;
    if (p == null) return ' (avance)';
    if (a.montant >= p.reste) return ' (solde)';
    return ' (partiel, reste ${formaterMontant(p.reste - a.montant, _devise)})';
  }

  /// Message de relance pret a envoyer (WhatsApp, SMS...) au chauffeur.
  void _relancerChauffeur() {
    final dues = _periodesDues();
    if (_moto == null) return;
    if (dues.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rien a relancer : aucun versement en retard pour cette moto.')));
      return;
    }
    Share.share(messageRelance(chauffeur: _moto!.chauffeur, moto: _moto!.nom, dues: dues, devise: _devise));
  }

  void _signalerMontantInvalide() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Montant invalide : rien n\'a ete enregistre.')),
    );
  }

  Future<void> _exporterPdf() async {
    if (_moto == null) return;
    final depenses = await _db.listerDepensesParMoto(widget.motoId);
    await PdfService.genererEtPartagerReleve(
      // Le releve affiche le montant en vigueur aujourd'hui.
      moto: _moto!.copyWith(
          montantVersement:
              ScheduleService.montantAu(_moto!, _changementsMontant, ScheduleService.aujourdHui())),
      versements: _versements,
      depenses: depenses,
      deviseSymbole: _devise,
      // Memes chiffres que la fiche, pas un second calcul.
      totalEncaisse: _totalVerse,
      remboursementsDettes: _remboursementsDettes,
      compte: _compte,
      dettes: _dettes,
      detteDe: _detteDe,
    );
  }

  /// Suspend (hors service) ou reactive la moto. Une moto suspendue arrete
  /// de generer de nouvelles echeances, de notifier, et son solde/retard
  /// n'accumule plus rien pendant qu'elle est en pause — sans rien
  /// supprimer, elle peut etre reactivee a tout moment.
  Future<void> _basculerSuspension() async {
    if (_moto?.id == null) return;
    final estActive = _moto!.statut == AppConstants.motoActive;

    if (estActive) {
      final confirme = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Suspendre cette moto ?'),
          content: const Text(
              'Aucune nouvelle echeance ne sera generee et les rappels de '
              'notification seront arretes tant qu\'elle est suspendue. '
              'L\'historique deja paye est conserve. A la reactivation, les '
              'echeances tombees pendant la pause ne compteront pas (la moto '
              'n\'aura pas travaille) : le suivi repartira de la date de '
              'reactivation. Les retards et dettes d\'avant la pause restent dus.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Suspendre')),
          ],
        ),
      );
      if (confirme != true) return;
    }

    final motoMisAJour = _moto!.copyWith(
      statut: estActive ? AppConstants.motoSuspendue : AppConstants.motoActive,
    );
    await _db.modifierMoto(motoMisAJour);

    if (!estActive) {
      // Reactivation apres une pause : la moto n'a pas travaille pendant
      // ce temps, les echeances tombees pendant la pause ne comptent pas
      // (les retards d'avant la pause restent dus) - on repart d'une
      // fenetre fraiche a partir d'aujourd'hui.
      await _db.redemarrerEcheancesApresReactivation(motoMisAJour);
    }
    // Une seule mise a jour des rappels, seulement ce qui change : suspendue,
    // ils disparaissent ; reactivee, ceux de la nouvelle fenetre arrivent.
    try {
      await NotificationService.synchroniserRappelsMoto(
        moto: motoMisAJour,
        versements: await _db.listerVersementsParMoto(motoMisAJour.id!),
        delaiHeures: (await _db.obtenirParametres()).delaiNotificationHeures,
      );
    } catch (_) {}

    _charger();
  }

  Future<void> _supprimerMoto() async {
    if (_moto?.id == null) return;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette moto ?'),
        content: Text(
          '"${_moto!.nom}" et tout son historique (versements, depenses) '
          'seront definitivement supprimes. Cette action est irreversible.'
          '${_dettes.isEmpty ? '' : '\n\n${_dettes.length} dette(s) liee(s) seront conservee(s), detachee(s) de cette moto.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirme != true || _moto?.id == null) return;

    try {
      // Annule seulement ses rappels reellement programmes (une moto hors
      // service n'en a plus). Secondaire : un echec du plugin ne bloque pas
      // la suppression.
      try {
        await NotificationService.synchroniserRappelsMoto(
            moto: _moto!.copyWith(statut: AppConstants.motoArchivee), versements: _versements, delaiHeures: 0);
      } catch (_) {}
      await _db.supprimerMoto(_moto!.id!);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur lors de la suppression : $e')));
      }
    }
  }

  /// Corrige le montant d'un versement deja valide, ou annule sa
  /// validation (redevient en attente / en retard) en cas d'erreur de
  /// saisie du gerant.
  Future<void> _modifierVersementPaye(Versement v) async {
    if (v.id == null) return;
    final controleur = TextEditingController(
      text: (v.montantPaye ?? v.montantPrevu).toStringAsFixed(0),
    );
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier ce versement'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Echeance du ${formaterDate(v.dateEcheance)}',
                style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: controleur,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Montant verse',
                helperText: 'Au-dela du montant prevu : avance deduite des echeances suivantes',
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'annuler_validation'),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Annuler la validation'),
          ),
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Fermer')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, 'enregistrer'),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );

    if (action == 'enregistrer') {
      final montant = lireMontant(controleur.text);
      if (montant == null) {
        _signalerMontantInvalide();
        return;
      }
      await _db.modifierMontantPaye(v.id!, montant);
      _charger();
    } else if (action == 'annuler_validation') {
      if (!mounted) return;
      final confirme = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Annuler la validation ?'),
          content: const Text(
              'Ce versement redeviendra en attente (ou en retard si l\'echeance est deja passee).'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Non')),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Oui, annuler')),
          ],
        ),
      );
      if (confirme == true) {
        await _db.annulerValidationVersement(v.id!);
        _charger();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_chargement || _moto == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final moto = _moto!;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${moto.nom} - ${moto.chauffeur}'),
            if (moto.id != null)
              Text(
                'N°${moto.id}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
              ),
          ],
        ),
        actions: [
          // Toujours visible : un bouton qui disparait quand la moto est a
          // jour laisse croire a un bug ; on explique plutot pourquoi.
          IconButton(
            icon: const Icon(Icons.send_outlined),
            tooltip: 'Relancer le chauffeur',
            onPressed: _relancerChauffeur,
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Exporter le releve',
            onPressed: _exporterPdf,
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => AddEditMotoScreen(motoExistante: moto)),
              );
              _charger();
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'suspendre') _basculerSuspension();
              if (v == 'supprimer') _supprimerMoto();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'suspendre',
                child: Text(moto.statut == AppConstants.motoActive
                    ? 'Suspendre (hors service)'
                    : 'Reactiver cette moto'),
              ),
              PopupMenuItem(
                value: 'supprimer',
                child: Text('Supprimer la moto', style: TextStyle(color: AppColors.danger)),
              ),
            ],
          ),
        ],
      ),
      // Un seul geste quand le chauffeur donne de l'argent.
      floatingActionButton: moto.statut == AppConstants.motoActive
          ? FloatingActionButton.extended(
              onPressed: _encaisserVersement,
              icon: const Icon(Icons.add),
              label: const Text('Ajouter versement'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _charger,
        child: ListView(
          // En bas : place pour le bouton "Ajouter versement".
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.carteNoire, borderRadius: BorderRadius.circular(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Total encaisse', style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                  const SizedBox(height: 4),
                  Text(formaterMontant(_totalVerse, _devise),
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                  if (_remboursementsDettes > 0)
                    Text('dont ${formaterMontant(_remboursementsDettes, _devise)} de remboursements de dettes',
                        style: const TextStyle(color: AppColors.texteGris, fontSize: 10)),
                  const SizedBox(height: 4),
                  Text(
                    ScheduleService.libelleFrequence(moto.frequenceType, moto.frequenceValeur),
                    style: TextStyle(color: AppColors.texteGris, fontSize: 11),
                  ),
                  // Retard et avance separes : une avance ne cache pas un retard.
                  // Moto suspendue : ses retards d'avant la pause restent dus.
                  ...[
                    for (final (montant, enRetard) in [(_compte.retard, true), (_compte.avance, false)])
                      if (montant > 0) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Icon(
                              enRetard ? Icons.error_outline : Icons.trending_up,
                              color: enRetard ? const Color(0xFFE2554A) : AppColors.accentLime,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              enRetard
                                  ? 'En retard de : ${formaterMontant(montant, _devise)}'
                                  : 'Paye d\'avance : ${formaterMontant(montant, _devise)}',
                              style: TextStyle(
                                color: enRetard ? const Color(0xFFE2554A) : AppColors.accentLime,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                  ],
                  if (moto.statut != AppConstants.motoActive) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
                      child: Center(
                        child: Text(
                          moto.statut == AppConstants.motoSuspendue ? 'Moto suspendue' : 'Moto archivee',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Dettes liees', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                TextButton.icon(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AddEditDetteScreen(
                          lienTypeInitial: AppConstants.detteLienMoto,
                          lienIdInitial: widget.motoId,
                          lienNomInitial: moto.nom,
                        ),
                      ),
                    );
                    _charger();
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Ajouter'),
                ),
              ],
            ),
            if (_dettes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Aucune dette liee.', style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
              )
            else
              ..._dettes.map((d) => _ligneDette(d)),
            const SizedBox(height: 20),
            const Text('Historique des versements', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._versements.map((v) => _ligneVersement(v)),
          ],
        ),
      ),
    );
  }

  Widget _ligneDette(Dette d) {
    // Jamais negatif a l'ecran : une dette trop remboursee est "Remboursee".
    final solde = (_soldeParDette[d.id] ?? d.montantInitial).clamp(0, double.infinity).toDouble();
    return InkWell(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => DetteDetailScreen(detteId: d.id!)));
        _charger();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.bordure, width: 0.6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.nomPersonne, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                  Text(formaterDate(d.date), style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                ],
              ),
            ),
            Text(
              formaterMontant(solde, _devise),
              style: TextStyle(
                color: solde > 0 ? AppColors.danger : AppColors.succes,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Deja rembourse et reste du d'une dette de la moto (null si elle
  /// n'existe plus).
  ({double rembourse, double reste})? _detteDe(int? detteId) {
    final reste = _soldeParDette[detteId];
    final dette = _dettes.where((d) => d.id == detteId).firstOrNull;
    if (reste == null || dette == null) return null;
    return (rembourse: dette.montantInitial - reste, reste: reste);
  }

  Widget _ligneVersement(Versement v) {
    final estPaye = v.statut == AppConstants.versementPaye;
    final estDette = v.statut == AppConstants.versementEnDette;
    // Une echeance passee en dette se suit dans Dettes : reste du, ou "Rembourse".
    final resteDette = estDette ? _soldeParDette[v.detteId] : null;
    // Meme regle que les calculs : une semaine de pause n'est pas due.
    final passeeNonPayee = !estPaye && !estDette && ScheduleService.estDue(v, _moto!, ScheduleService.aujourdHui());

    // Meme libelle et meme montant que le releve PDF (voir [ligneVersement]).
    final ligne =
        ligneVersement(v, moto: _moto!, dette: _detteDe(v.detteId), aujourdHui: ScheduleService.aujourdHui(), devise: _devise);
    final libelle = ligne.libelle;
    final Color couleur;
    if (estPaye) {
      // Paye en partie : le reste sera complete au prochain encaissement.
      couleur = ScheduleService.resteDu(v) > 0 ? AppColors.danger : AppColors.succes;
    } else if (estDette) {
      couleur = resteDette != null && resteDette <= 0 ? AppColors.succes : AppColors.danger;
    } else if (passeeNonPayee) {
      couleur = AppColors.danger;
    } else {
      couleur = AppColors.texteGris;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: estPaye
          ? () => _modifierVersementPaye(v)
          : estDette && v.detteId != null
              ? () async {
                  await Navigator.push(
                      context, MaterialPageRoute(builder: (_) => DetteDetailScreen(detteId: v.detteId!)));
                  _charger();
                }
              : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.bordure, width: 0.6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(formaterDate(v.dateEcheance), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                  Text(libelle, style: TextStyle(color: couleur, fontSize: 10)),
                ],
              ),
            ),
            Text(
              formaterMontant(ligne.paye ?? v.montantPrevu, _devise),
              style: TextStyle(
                color: estPaye ? AppColors.succes : AppColors.texteNoir,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            if (estDette) ...[
              const SizedBox(width: 8),
              if (resteDette != null && resteDette > 0)
                IconButton(
                  icon: const Icon(Icons.check_circle_outline, size: 20),
                  color: AppColors.succes,
                  tooltip: 'Marquer la dette payee',
                  onPressed: () => _rembourserDette(v),
                ),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.texteGris),
            ] else if (!estPaye) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.check_circle_outline, size: 20),
                color: AppColors.succes,
                tooltip: 'Valider le versement',
                onPressed: () => _validerVersement(v),
              ),
              if (passeeNonPayee)
                IconButton(
                  icon: const Icon(Icons.request_page_outlined, size: 20),
                  color: AppColors.danger,
                  tooltip: 'Marquer en dette',
                  onPressed: () => _marquerEnDette(v),
                ),
            ] else ...[
              const SizedBox(width: 8),
              Icon(Icons.edit_outlined, size: 16, color: AppColors.texteGris),
            ],
          ],
        ),
      ),
    );
  }
}
