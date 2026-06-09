// Dart projection of packages/content-schema/season.schema.json and the
// matching Go types in services/core-go/content/types.go.
//
// Kept hand-rolled rather than codegen'd because the surface is small and
// the JSON shape will not move except by an additive schema bump in M1.
// When the schema gains optional fields we'll add nullable getters here
// rather than re-running a generator.

/// A complete narrative arc consisting of exactly four [Act]s.
class Season {
  const Season({
    required this.id,
    required this.title,
    required this.locale,
    required this.version,
    required this.description,
    required this.acts,
  });

  factory Season.fromJson(Map<String, dynamic> json) {
    return Season(
      id: json['id'] as String,
      title: json['title'] as String,
      locale: json['locale'] as String,
      version: (json['version'] as num).toInt(),
      description: (json['description'] as String?) ?? '',
      acts: <Act>[
        for (final a in json['acts'] as List<dynamic>)
          Act.fromJson(a as Map<String, dynamic>),
      ],
    );
  }

  final String id;
  final String title;
  final String locale;
  final int version;
  final String description;
  final List<Act> acts;

  /// Flat-ordered list of every vignette in the Season, in author order
  /// (act-1 → act-4, vignette-1 → vignette-n within each act). The vignette
  /// renderer walks this list linearly in M1.
  List<Vignette> get flatVignettes => <Vignette>[
        for (final a in acts) ...a.vignettes,
      ];
}

/// A thematic block of vignettes within a [Season].
class Act {
  const Act({required this.id, required this.name, required this.vignettes});

  factory Act.fromJson(Map<String, dynamic> json) {
    return Act(
      id: json['id'] as String,
      name: json['name'] as String,
      vignettes: <Vignette>[
        for (final v in json['vignettes'] as List<dynamic>)
          Vignette.fromJson(v as Map<String, dynamic>),
      ],
    );
  }

  final String id;
  final String name;
  final List<Vignette> vignettes;
}

/// A single decision moment.
class Vignette {
  const Vignette({
    required this.id,
    required this.settingBeat,
    required this.choices,
    this.ambientAudio,
    this.ambientArt,
    this.resolutionBeats = const <String, String>{},
  });

  factory Vignette.fromJson(Map<String, dynamic> json) {
    final beats = (json['resolution_beats'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    return Vignette(
      id: json['id'] as String,
      settingBeat: json['setting_beat'] as String,
      ambientAudio: json['ambient_audio'] as String?,
      ambientArt: json['ambient_art'] as String?,
      choices: <Choice>[
        for (final c in json['choices'] as List<dynamic>)
          Choice.fromJson(c as Map<String, dynamic>),
      ],
      resolutionBeats: <String, String>{
        for (final e in beats.entries) e.key: e.value as String,
      },
    );
  }

  final String id;
  final String settingBeat;
  final String? ambientAudio;
  final String? ambientArt;
  final List<Choice> choices;

  /// Optional per-choice follow-up beats. Keyed by [Choice.id].
  final Map<String, String> resolutionBeats;

  /// Convenience: the resolution beat for a choice, or null if the
  /// vignette doesn't author one.
  String? resolutionFor(String choiceId) => resolutionBeats[choiceId];
}

/// One option presented within a [Vignette].
class Choice {
  const Choice({
    required this.id,
    required this.label,
    required this.weights,
  });

  factory Choice.fromJson(Map<String, dynamic> json) {
    return Choice(
      id: json['id'] as String,
      label: json['label'] as String,
      weights: <TraitWeight>[
        for (final w in json['weights'] as List<dynamic>)
          TraitWeight.fromJson(w as Map<String, dynamic>),
      ],
    );
  }

  final String id;
  final String label;
  final List<TraitWeight> weights;
}

/// Signed contribution a [Choice] makes to one trait dimension.
///
/// Weights are not surfaced to the player; they live in the Choice model
/// so the local sync can pre-compute deltas if it ever needs to render a
/// preview before round-tripping the server (out of scope for M1).
class TraitWeight {
  const TraitWeight({
    required this.dimension,
    required this.delta,
    this.rationale = '',
  });

  factory TraitWeight.fromJson(Map<String, dynamic> json) {
    return TraitWeight(
      dimension: json['dimension'] as String,
      delta: (json['delta'] as num).toDouble(),
      rationale: (json['rationale'] as String?) ?? '',
    );
  }

  final String dimension;
  final double delta;
  final String rationale;
}
