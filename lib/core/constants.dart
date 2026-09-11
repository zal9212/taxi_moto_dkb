/// Constantes globales. Les valeurs par défaut ici ne sont QUE des valeurs
/// de démarrage — tout est ensuite modifiable depuis les Réglages et stocké
/// en base (table `parametres`), rien n'est figé en dur dans les écrans.
library;

class AppConstants {
  AppConstants._();

  static const String dbName = 'moto_taxi_douka.db';
  static const int dbVersion = 3;

  // Valeurs par défaut au premier lancement (modifiables ensuite)
  static const String devisePardDefaut = 'FG';
  static const int delaiNotificationHeuresParDefaut = 24; // rappel 24h avant
  static const bool biometrieActiveParDefaut = false;

  // Types de fréquence de versement
  static const String freqHebdomadaire = 'hebdomadaire';
  static const String freqMensuelle = 'mensuelle';
  static const String freqPersonnalisee = 'personnalisee'; // intervalle en jours

  // Statuts moto (pas de notion de dette/solde : uniquement le cycle de vie)
  static const String motoActive = 'actif';
  static const String motoSuspendue = 'suspendu';
  static const String motoArchivee = 'archive';

  // Statuts versement
  static const String versementEnAttente = 'en_attente';
  static const String versementPaye = 'paye';
  static const String versementEnRetard = 'en_retard';

  // Catégories de dépenses par défaut (extensibles par l'utilisateur)
  static const List<Map<String, String>> categoriesParDefaut = [
    {'nom': 'Huile', 'icone': 'droplet'},
    {'nom': 'Reparation', 'icone': 'tool'},
    {'nom': 'Carburant', 'icone': 'gas_station'},
    {'nom': 'Assurance', 'icone': 'shield'},
    {'nom': 'Autre', 'icone': 'dots'},
  ];

  static const List<String> joursSemaine = [
    'Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'
  ];

  // ---------------------------------------------------------------------
  // Categories d'activite generiques (Boutiques, etc. - a cote de Motos,
  // qui reste un systeme specialise inchange). Statuts d'entite generique :
  // memes valeurs que motoActive/motoSuspendue/motoArchivee, reutilisees
  // telles quelles.
  // ---------------------------------------------------------------------

  // Niveau d'un champ personnalise
  static const String niveauChampEntite = 'entite';
  static const String niveauChampTransaction = 'transaction';

  // Type d'un champ personnalise
  static const String typeChampTexte = 'texte';
  static const String typeChampMontant = 'montant';
  static const String typeChampDate = 'date';
  static const String typeChampListe = 'liste';

  static const List<String> typesChampDisponibles = [
    typeChampTexte,
    typeChampMontant,
    typeChampDate,
    typeChampListe,
  ];

  // Type d'une transaction generique (revenu/depense d'une entite)
  static const String transactionRevenu = 'revenu';
  static const String transactionDepense = 'depense';

  // Palette de couleurs proposee a la creation d'une categorie
  static const List<String> couleursCategorieDisponibles = [
    '#2D6CDF', // bleu
    '#0EA5A5', // sarcelle
    '#8B5CF6', // violet
    '#E2554A', // corail
    '#B5860A', // ambre
    '#C8F169', // vert lime
  ];
}
