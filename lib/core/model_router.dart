import '../models/model_info.dart';

/// ── Auto model / smart routing ──────────────────────────────────────────────
///
/// The proxy serves **one virtual model** (`auto`) backed by every model of
/// every connected provider, so clients (Claude Code, OpenAI SDKs, …) never have
/// to pick a real upstream model:
///
///   * `auto`            → smart routing: the request is classified, the
///                         best-matching capability tier runs first and the
///                         chain escalates / degrades on failure.
///   * `auto:strong`     → always start at the strongest tier.
///   * `auto:fast`       → always start at the lightest / cheapest tier.
///   * `<provider>/auto` → same, restricted to one provider.
///
/// Everything here is pure and unit-tested (`test/auto_router_test.dart`).

/// Estimated capability tier of an upstream model.
enum ModelTier {
  light('light'),
  balanced('balanced'),
  strong('strong');

  final String label;
  const ModelTier(this.label);

  /// 0 = lightest … 2 = strongest.
  int get rank => index;
}

/// How demanding an incoming request looks.
enum TaskComplexity {
  trivial('trivial'),
  simple('simple'),
  moderate('moderate'),
  complex('complex');

  final String label;
  const TaskComplexity(this.label);
}

/// Cost bucket: keeps credit-burning models out of the way.
enum ModelCost {
  /// Reported free by the provider (`:free` id, zero pricing, free-tier flag).
  free,

  /// No pricing metadata — manually declared models, private gateways.
  /// Treated as usable, ranked just behind free models.
  unknown,

  /// Pricing metadata explicitly greater than zero.
  paid;

  int get order => index;
}

/// Result of classifying one request.
class AutoPlan {
  final TaskComplexity complexity;
  final ModelTier targetTier;

  /// Short explanation, logged next to the request.
  final String reason;

  const AutoPlan({
    required this.complexity,
    required this.targetTier,
    required this.reason,
  });

  @override
  String toString() =>
      'task=${complexity.label} tier=${targetTier.label} ($reason)';
}

/// Heuristic capability estimation for upstream models.
class ModelCapability {
  const ModelCapability._();

  static const double strongFloor = 18;
  static const double balancedFloor = 6;

  /// `20b`, `1.7b`, `235b`, `671b` … (deliberately not `a3b`).
  static final RegExp _paramSize =
      RegExp(r'(?<![a-z0-9.])(\d+(?:[._]\d+)?)b(?![a-z0-9])');

  /// `gpt-6`, `gemini-4`, `kimi-k3`, `deepseek-v4`, `qwen3`, `hy4`, `grok-4-7`…
  static final RegExp _familyVersion = RegExp(
    r'(?:^|[^a-z0-9])(?:gpt|chatgpt|claude|gemini|deepseek|qwen|llama|kimi|grok'
    r'|glm|mistral|ministral|nova|hy|phi|gemma|minimax|mimo|command|ernie|seed)'
    r'[-_]?(?:[vkrim]|v)?[-_]?(\d+(?:\.\d+)?)',
  );

  /// Names that reliably mark a flagship / reasoning / heavy model.
  static const Map<String, double> _strongTokens = {
    'opus': 16,
    'ultra': 16,
    'super': 14,
    'max': 12,
    'pro': 10,
    'large': 8,
    'preview': 8,
    'reasoner': 10,
    'reasoning': 10,
    'thinking': 8,
    'think': 8,
    'r1': 8,
    'sonnet': 8,
  };

  /// Names that reliably mark a small / fast / cheap variant.
  static const Set<String> _weakTokens = {
    'flash', 'lite', 'light', 'mini', 'small', 'nano', 'tiny', 'haiku',
    'turbo', 'instant', 'lightning', 'particle', 'eco', 'fast', 'compact',
    'express', 'starter', 'spark', 'edge',
  };

  /// Cheap-variant markers that may hide inside a longer token
  /// (`ministral`, `gemini-flash-x`, `…-nanobot`).
  static const List<String> _weakSubstrings = [
    'mini', 'nano', 'flash', 'turbo', 'haiku', 'light', 'compact', 'express'
  ];

  /// Text of everything the router should look at when scoring a model id.
  static String haystack(ModelInfo m) {
    final tail = m.id
        .toLowerCase()
        .split('/')
        .last
        .replaceFirst(RegExp(r'[:.](free|nitro|exp|preview)$'), '');
    final name = (m.displayName ?? '').toLowerCase();
    final owner = (m.ownedBy ?? '').toLowerCase();
    return '$tail $name $owner'.trim();
  }

  /// Estimated capability score (roughly −10 … 60).
  ///
  /// Signals: parameter size, family version (gpt-6 > gpt-4), flagship vs. small
  /// name tokens, advertised context window. Deliberately approximate — it only
  /// decides the *starting order*; failover repairs the mistakes.
  static double score(ModelInfo m) {
    final hay = haystack(m);
    final tokens =
        RegExp(r'[a-z0-9.]+').allMatches(hay).map((e) => e[0]!).toSet();

    var s = 10.0;

    final sizeMatch = _paramSize.firstMatch(hay);
    if (sizeMatch != null) {
      final size = double.tryParse(sizeMatch.group(1)!.replaceAll('_', '.'));
      if (size != null) {
        if (size >= 200) {
          s += 26;
        } else if (size >= 70) {
          s += 18;
        } else if (size >= 27) {
          s += 12;
        } else if (size >= 14) {
          s += 6;
        } else if (size <= 4) {
          s -= 12;
        }
      }
    }

    final versionMatch = _familyVersion.firstMatch(hay);
    if (versionMatch != null) {
      final v = double.tryParse(versionMatch.group(1)!.replaceAll('_', '.'));
      if (v != null) s += v.clamp(0.0, 8.0).toDouble() * 2.5;
    }

    var strong = 0.0;
    for (final e in _strongTokens.entries) {
      if (tokens.contains(e.key)) strong += e.value;
    }
    s += strong > 16 ? 16.0 : strong;

    if (tokens.any(_weakTokens.contains) ||
        _weakSubstrings.any(hay.contains)) {
      s -= 12;
    }

    final ctx = m.contextLength;
    if (ctx != null) {
      if (ctx >= 500000) {
        s += 8;
      } else if (ctx >= 200000) {
        s += 5;
      } else if (ctx >= 64000) {
        s += 2;
      } else if (ctx < 16000) {
        s -= 6;
      }
    }

    return s;
  }

  /// True for `…-flash`, `…-lite`, `mini…`, `haiku`, `lightning` … i.e. the
  /// cheap sibling of a family, whatever generation it belongs to.
  static bool isSmallVariant(ModelInfo m) {
    final hay = haystack(m);
    final tokens =
        RegExp(r'[a-z0-9.]+').allMatches(hay).map((e) => e[0]!).toSet();
    return tokens.any(_weakTokens.contains) ||
        _weakSubstrings.any(hay.contains);
  }

  static ModelTier _tierFromScore(double s) {
    if (s >= strongFloor) return ModelTier.strong;
    if (s >= balancedFloor) return ModelTier.balanced;
    return ModelTier.light;
  }

  /// A `-flash` / `-mini` variant is **never** the tier the router starts a
  /// complex task with, even when its generation number is high.
  static ModelTier tier(ModelInfo m) {
    final t = _tierFromScore(score(m));
    if (t == ModelTier.strong && isSmallVariant(m)) return ModelTier.balanced;
    return t;
  }

  /// Without evidence that a model is free, the router assumes it costs money —
  /// guessing from *missing* pricing metadata would push hundreds of paid
  /// OpenRouter models in front of the models that actually answer.
  static ModelCost cost(ModelInfo m) {
    if (m.isFree) return ModelCost.free;
    // Hand-declared = the user vouches for this gateway model.
    if (m.manuallyAdded && !m.isKnownPaid) return ModelCost.unknown;
    return ModelCost.paid;
  }

  /// Ordering weight inside a tier: free first, then "usable, no pricing
  /// metadata" (private gateways, manual models), paid last.
  static double priority(ModelInfo m) {
    final boost = switch (cost(m)) {
      ModelCost.free => 6.0,
      ModelCost.unknown => 3.0,
      ModelCost.paid => 0.0,
    };
    return score(m) + boost;
  }
}

/// The virtual proxy model and its aliases.
class AutoModel {
  const AutoModel._();

  static const String canonical = 'auto';
  static const String strongVariant = 'auto:strong';
  static const String fastVariant = 'auto:fast';

  /// Model ids advertised by `/v1/models`.
  static const List<String> served = [canonical, strongVariant, fastVariant];

  static const String displayName =
      'Auto — smart routing across every connected provider';

  /// Aliases meaning "route it for me" (tier chosen by task complexity).
  static const Set<String> _plain = {
    'auto', 'smart', 'auto-smart', 'auto:smart', 'auto-router', 'router',
    'proxy-auto', 'hub-auto', 'llm-hub-auto', 'llm-proxy-auto',
    'all-providers', 'merged',
  };

  /// Aliases that pin the starting tier.
  static const Map<String, ModelTier> _forced = {
    'auto:strong': ModelTier.strong,
    'auto-strong': ModelTier.strong,
    'auto:max': ModelTier.strong,
    'auto:pro': ModelTier.strong,
    'strong': ModelTier.strong,
    'best': ModelTier.strong,
    'auto:fast': ModelTier.light,
    'auto-fast': ModelTier.light,
    'auto:light': ModelTier.light,
    'auto:cheap': ModelTier.light,
    'auto-lite': ModelTier.light,
    'fast': ModelTier.light,
    'cheap': ModelTier.light,
    'auto:balanced': ModelTier.balanced,
    'auto:medium': ModelTier.balanced,
    'balanced': ModelTier.balanced,
  };

  /// True when [requested] should be handled by the auto router.
  static bool matches(String requested) => bare(requested) != null;

  /// Stripped, lower-cased alias (`provider/auto` → `auto`), or null.
  static String? bare(String requested) {
    var x = requested.trim().toLowerCase();
    if (x.isEmpty) return null;
    x = x.replaceFirst(RegExp(r'\[\d+m\]$'), '');
    final slash = x.lastIndexOf('/');
    if (slash >= 0) x = x.substring(slash + 1);
    if (_plain.contains(x) || _forced.containsKey(x)) return x;
    return null;
  }

  /// Forced starting tier: `auto:strong` → [ModelTier.strong];
  /// plain `auto` (or non-auto names) → null = smart routing.
  static ModelTier? forcedTier(String requested) {
    final b = bare(requested);
    if (b == null) return null;
    return _forced[b];
  }
}

/// Smart-routing decisions for incoming requests.
class TaskRouter {
  const TaskRouter._();

  /// Bare greetings / acknowledgements (English + Persian). Anything else is
  /// scored on substance, not matched against a word list.
  static final RegExp _greeting = RegExp(
    r'^(hi|hey|hello|yo|sup|ok|okay|okey|dokey|yes|yep|no|nope|sure|'
    r'thanks|thank you|thankyou|thx|ty|nice|great|cool|good|got it|understood|'
    r'lol|ping|test|who are you|what time is it|'
    r'سلام|سلامت|درود|چطوری|خوبی|ممنون|مرسی|قربان|فدات|تشکر|سپاس|'
    r'بله|بلی|نه|خیر|باشه|باشید|خوبه|اوکی|حله)'
    r'[^a-zA-Z\u0600-\u06FF]*$',
    caseSensitive: false,
  );

  static final List<RegExp> _complexityHints = [
    RegExp(
        r'\b(implement|refactor|architect(ure)?|optimi[sz]e|debug|migrat(e|ion)'
        r'|design|review|prove|derive|analy[sz]e|root cause|race condition|'
        r'stack ?trace|traceback|exception|deadlock|concurrency|benchmark)\b',
        caseSensitive: false),
    RegExp(r'\b(write|fix|add)\b.{0,40}\b(test|bug|error|failing|issue)\b',
        caseSensitive: false),
    RegExp(
        r'(پیاده‌?سازی|بازنویسی|معماری|بهینه‌?سازی|دیباگ|رفع خطا|بررسی|تحلیل|'
        r'چرا|تست بنویس|کد بزن|کدنویسی|مستندسازی)'),
  ];

  /// Classifies [body] (OpenAI-style chat body) and picks the tier to start
  /// from. Short/simple requests start on a light model; the failover chain
  /// still escalates to stronger models if that one cannot deliver.
  static AutoPlan assess(Map<String, dynamic> body) {
    final messages = (body['messages'] as List?) ?? const [];

    var lastUser = '';
    var userTurns = 0;
    var toolTurns = 0;
    for (final m in messages) {
      if (m is! Map) continue;
      final role = (m['role'] ?? '').toString();
      final text = textOf(m['content']);
      if (role == 'user' && text.trim().isNotEmpty) {
        lastUser = text.trim();
        userTurns++;
      } else if (role == 'tool' || role == 'function') {
        toolTurns++;
      }
    }

    final totalChars =
        messages.fold<int>(0, (sum, m) => sum + (m is Map ? textOf(m['content']).length : 0));
    final tools = (body['tools'] as List?) ?? const [];
    final maxTokens = (body['max_tokens'] as num?)?.toInt() ??
        (body['max_completion_tokens'] as num?)?.toInt() ??
        0;
    final lower = lastUser.toLowerCase();

    // A bare greeting stays trivial no matter what else the client ships
    // (Claude Code always sends a huge system prompt + tool schema).
    if (lower.isNotEmpty &&
        lastUser.length <= 48 &&
        _greeting.hasMatch(lower)) {
      return const AutoPlan(
        complexity: TaskComplexity.trivial,
        targetTier: ModelTier.light,
        reason: 'greeting / acknowledgement',
      );
    }

    var score = 0;
    final notes = <String>[];
    void add(int v, String why) {
      if (v == 0) return;
      score += v;
      notes.add('$why:+$v');
    }

    if (lastUser.length > 4000) {
      add(3, 'prompt=${lastUser.length}c');
    } else if (lastUser.length > 1200) {
      add(2, 'prompt=${lastUser.length}c');
    } else if (lastUser.length > 350) {
      add(1, 'prompt=${lastUser.length}c');
    }

    final fences = '```'.allMatches(lastUser).length ~/ 2;
    if (fences >= 3) {
      add(2, 'code-blocks=$fences');
    } else if (fences >= 1) {
      add(1, 'code-blocks=$fences');
    }

    if (userTurns >= 12) {
      add(2, 'turns=$userTurns');
    } else if (userTurns >= 5) {
      add(1, 'turns=$userTurns');
    }
    add(toolTurns > 0 ? 1 : 0, 'tool-results');
    add(tools.isNotEmpty ? 1 : 0, 'tools=${tools.length}');
    if (totalChars > 60000) add(1, 'context=${totalChars}c');
    if (maxTokens >= 4000) add(1, 'max_tokens=$maxTokens');

    var hits = 0;
    for (final re in _complexityHints) {
      if (re.hasMatch(lastUser)) hits++;
    }
    if (hits > 0) add(hits > 3 ? 3 : hits, 'keywords=$hits');

    final complexity = switch (score) {
      <= 0 => TaskComplexity.trivial,
      <= 2 => TaskComplexity.simple,
      <= 4 => TaskComplexity.moderate,
      _ => TaskComplexity.complex,
    };
    final tier = switch (complexity) {
      TaskComplexity.trivial => ModelTier.light,
      TaskComplexity.simple => ModelTier.light,
      TaskComplexity.moderate => ModelTier.balanced,
      TaskComplexity.complex => ModelTier.strong,
    };

    return AutoPlan(
      complexity: complexity,
      targetTier: tier,
      reason: notes.isEmpty ? 'minimal prompt' : notes.join(', '),
    );
  }

  /// Flattens OpenAI/Anthropic message content (`String` or block list).
  static String textOf(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final buf = StringBuffer();
      for (final block in content) {
        if (block is Map) {
          final t = block['text'] ?? block['content'];
          if (t is String) buf.write('$t\n');
        } else if (block is String) {
          buf.write('$block\n');
        }
      }
      return buf.toString();
    }
    return '';
  }
}

/// Builds the ordered candidate list for an `auto` request.
class AutoChain {
  const AutoChain._();

  /// Known-paid models are only a final safety net, so a huge paid catalogue
  /// (OpenRouter lists hundreds) can never crowd out the free / private-gateway
  /// models that actually answer.
  static const int maxPaidCandidates = 2;

  /// [consented] marks models the user deliberately added (models of a **custom
  /// provider**): those are their own gateway and their own credit plan, so they
  /// compete normally by capability instead of being pushed behind a paid cap.
  static List<ModelInfo> order({
    required List<ModelInfo> models,
    required ModelTier target,
    int maxCandidates = 12,
    int maxPaid = maxPaidCandidates,
    Set<String>? consented,
  }) {
    final usable = <ModelInfo>[];
    final paid = <ModelInfo>[];
    for (final m in models) {
      final demote = ModelCapability.cost(m) == ModelCost.paid &&
          !(consented?.contains(m.key) ?? false);
      (demote ? paid : usable).add(m);
    }

    /// Capability + cost weight. A consented (custom-provider) model that merely
    /// looks paid is weighted like an unknown one — the user added it on purpose.
    double prio(ModelInfo m) {
      final boost = switch (ModelCapability.cost(m)) {
        ModelCost.free => 6.0,
        ModelCost.unknown => 3.0,
        ModelCost.paid => (consented?.contains(m.key) ?? false) ? 3.0 : 0.0,
      };
      return ModelCapability.score(m) + boost;
    }

    int byLadder(ModelInfo a, ModelInfo b) {
      final ta = ModelCapability.tier(a).rank;
      final tb = ModelCapability.tier(b).rank;
      final da = (ta - target.rank).abs();
      final db = (tb - target.rank).abs();
      if (da != db) return da.compareTo(db);
      // Equidistant: escalate upwards before degrading downwards.
      if (ta != tb) return tb.compareTo(ta);
      final p = prio(b).compareTo(prio(a));
      if (p != 0) return p;
      final ca = a.contextLength ?? 0;
      final cb = b.contextLength ?? 0;
      if (ca != cb) return cb.compareTo(ca);
      return a.id.compareTo(b.id);
    }

    usable.sort(byLadder);
    paid.sort((a, b) {
      final t = ModelCapability.tier(b).rank.compareTo(ModelCapability.tier(a).rank);
      if (t != 0) return t;
      return prio(b).compareTo(prio(a));
    });

    final out = <ModelInfo>[
      ...usable,
      // A provider catalogue with nothing free/unknown in it (pure paid
      // account) must still get a usable chain.
      ...paid.take(usable.isEmpty ? maxCandidates : maxPaid),
    ];
    return out.length > maxCandidates ? out.sublist(0, maxCandidates) : out;
  }
}
