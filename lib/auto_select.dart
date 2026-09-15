part of 'main.dart';

// ============================ АВТОВЫБОР СЕРВЕРА: скоринг, гистерезис, обучение ============================
// Чистая логика режима «лучший сервер» (без UI и без движка), чтобы она была юнит-тестируема
// (auto_select_test), как node_stats.dart для спарклайнов.
//
// Что было не так с прежним выбором «минимальный пинг из живых замеров»:
//   • Пинг — ОДИН замер в один момент. Узел 30 мс с регулярными всплесками до полсекунды для
//     игры хуже узла со стабильными 45 мс, а по пингу они неотличимы → учимся на серии
//     /public/stats (джиттер и стабильность за 48 ч) и на собственной истории коннектов.
//   • Выбор ПЕРЕСЧИТЫВАЛСЯ безусловно после каждого замера: соседние узлы 40/42 мс менялись
//     местами от пробы к пробе, и карточка сервера «прыгала» — гистерезис (shouldSwitchBest)
//     разрешает смену только при разительной разнице.
//   • Узел, вчера пять раз рвущий коннект, сегодня стартовал с чистого листа → история
//     успехов/сбоев (NodeHistory) персистится и входит в скор штрафом.
//   • Проблемный узел переспрашивался в каждом фон-прогоне наравне с живыми → экспоненциальный
//     бэкофф проб (probeBackoff): чем чаще узел молчит, тем реже его дёргаем.

/// Как часто фон-таймер автовыбора просыпается. Тяжёлые действия внутри отдельно привязаны
/// к условиям (форграунд, туннель выключен, троттлинги) — сам тик дешёвый.
const Duration kAutoSelectTick = Duration(minutes: 5);

/// Абсолютный и относительный пороги гистерезиса: кандидат обязан быть лучше текущего И на
/// столько миллисекунд, И на эту долю — иначе соседние по отклику узлы менялись бы местами
/// от каждого замера (дребезг выбора), а человек видел бы «скачущий» сервер в карточке.
const double kSwitchHystMs = 12;
const double kSwitchHystRatio = 0.15;

/// Скор незамеренного узла. Хуже любого реального отклика (иначе незамеренный «выигрывал»
/// у замеренного — старая болезнь выбора по нулевому пингу), но лучше заведомо мёртвого.
const double kScoreUnmeasured = 900;

/// Штраф узлу, который хаб (/public/stats) считает мёртвым прямо сейчас. Не выбрасываем из
/// ротации совсем (хаб мог ошибиться, а локальный приговор важнее), но честный замер любого
/// живого узла такой штраф всегда перебьёт.
const double kScoreStatsDead = 500;

/// Лёгкий штраф CDN-рельсе в обычной сети: рельса — обход блокировки, а не первый выбор
/// (тот же принцип, что тай-брейк «прямой раньше CDN» в compareServers). В restricted-сети
/// порядок рельс задаёт ранг cdnFirst до скора — там этот штраф не работает.
const double kScoreCdnPenalty = 30;

/// Веса скоринга по режимам. Скор — в миллисекундном эквиваленте (меньше = лучше):
///   score = effPing + jitter·wJitter + (1−stability)·wStability + history + штрафы.
/// Игры чувствительны к джиттеру сильнее, чем к среднему пингу (всплеск = фриз), стрим —
/// к стабильности канала (разрыв серии = буферизация), Прив. — как Авто по цифрам.
(double, double) modeWeights(int mode) => switch (mode) {
      1 => (0.15, 200.0), // Стрим: джиттер почти не важен, стабильность — критична
      2 => (0.8, 100.0),  // Игры: джиттер — главный враг
      _ => (0.4, 100.0),  // Авто/Прив.: сбалансированно
    };

/// Взвешенный скор узла для автовыбора (меньше = лучше). Чистая функция — auto_select_test.
///
/// [pingMs] — живой замер сквозь узел (0 — не замерено). [statsRtt]/[statsDead] — взгляд
/// хаба (/public/stats): когда локального замера ещё нет (холодный старт), узлы упорядочиваем
/// по rtt_now, но с базой выше любого локального замера — серверная метрика измеряет путь
/// «хаб→нода», а не «пользователь→нода», и притворяться локальным пингом не должна.
/// [jitterMs]/[stability] — из серии stats (см. insightOf); нет данных → нейтральные 0/1.
/// [histPenalty] — обучение на истории коннектов (NodeHistory.historyPenalty), мс-эквивалент.
double autoScore({
  required int pingMs,
  required double jitterMs,
  required double stability,
  required int? statsRtt,
  required bool statsDead,
  required double histPenalty,
  required bool isCdn,
  required int mode,
}) {
  // Незамеренный узел: с данными хаба — 600+rtt (упорядочены, но ниже честных замеров),
  // совсем без данных — дно kScoreUnmeasured (как «незамеренные в конец» в compareServers).
  final effPing = pingMs > 0
      ? pingMs.toDouble()
      : (statsRtt != null && statsRtt > 0 ? 600.0 + statsRtt : kScoreUnmeasured);
  final (wJitter, wStability) = modeWeights(mode);
  var score = effPing +
      jitterMs * wJitter +
      (1.0 - stability.clamp(0.0, 1.0)) * wStability +
      histPenalty;
  if (statsDead) score += kScoreStatsDead;
  if (isCdn) score += kScoreCdnPenalty;
  return score;
}

/// Гистерезис против дребезга: менять текущий выбор на кандидата, только если тот лучше
/// разительно — И абсолютно, И относительно. Без этого узлы 40/42 мс перетягивали звание
/// «лучший» от пробы к пробе. [curValid] = false (текущий умер/заблокирован/исчез из выдачи)
/// — переключаемся безусловно: удерживать невалидного «ради стабильности» нельзя.
/// Чистая функция — auto_select_test.
bool shouldSwitchBest(double curScore, double candScore, {required bool curValid}) {
  if (!curValid) return true;
  return candScore < curScore - kSwitchHystMs && candScore < curScore * (1 - kSwitchHystRatio);
}

/// Что мы знаем про узел из публичной статистики хаба, приведённое к нуждам выбора.
class NodeInsight {
  /// Робастный джиттер: среднее |Δrtt| по соседним живым точкам за последние ~6 ч.
  /// Стандартное отклонение по всем 48 ч раздувают редкие всплески до бессмысленности
  /// (проверено на живом отчёте: «джиттер» 300+ мс у нормальных узлов), а средний модуль
  /// соседних разностей показывает именно рябь канала. 0 — данных нет.
  final double jitterMs;

  /// Доля живых точек серии за окно (1.0 — ни одного провала). Для стрима важнее пинга:
  /// провал серии — это буферизация у зрителя. Нет данных → 1.0 (нейтрально, не штрафуем).
  final double stability;

  /// Хаб считает узел мёртвым ПРЯМО СЕЙЧАС (ok==false в свежем отчёте).
  final bool dead;

  const NodeInsight({this.jitterMs = 0, this.stability = 1, this.dead = false});
}

/// Окно джиттера — последние 6 часов серии (точки идут ~раз в 5 минут): дальше лежит вчерашний
/// день, он про сегодняшнюю рябь ничего не говорит. Окно стабильности — вся серия (48 ч).
const int kInsightJitterWindowSec = 6 * 3600;

/// Отчёт старше этого — мёртвым узел не считаем: ok==false могло быть снято час назад,
/// а узел с тех пор поднялся. Живой эндпоинт генерит отчёт раз в ~5 минут.
const Duration kStatsFreshTtl = Duration(minutes: 20);

/// Свести NodeStat к выборочным метрикам. [statsAge] — возраст отчёта (старше kStatsFreshTtl
/// → dead не признаём). Чистая функция — auto_select_test.
NodeInsight insightOf(NodeStat? stat, {required int nowSec, Duration statsAge = Duration.zero}) {
  if (stat == null) return const NodeInsight();
  // Стабильность: доля живых точек серии. Точек нет вовсе — нейтральная 1.0, данных просто нет.
  var stability = 1.0;
  if (stat.series.isNotEmpty) {
    final alive = stat.series.where((p) => p.$2 != null).length;
    stability = alive / stat.series.length;
  }
  // Джиттер по живым соседним точкам внутри окна. Мёртвые точки разрывают соседство — разница
  // через провал мерила бы и даунтайм, а не рябь.
  var jitter = 0.0;
  final fromSec = nowSec - kInsightJitterWindowSec;
  var sum = 0.0, cnt = 0;
  int? prev;
  for (final (ts, ms) in stat.series) {
    if (ts < fromSec) continue;
    if (ms == null) { prev = null; continue; }
    if (prev != null) { sum += (ms - prev).abs(); cnt++; }
    prev = ms;
  }
  if (cnt > 0) jitter = sum / cnt;
  return NodeInsight(
    jitterMs: jitter,
    stability: stability,
    dead: !stat.ok && statsAge < kStatsFreshTtl,
  );
}

/// Сопоставить запись /public/stats узлу подписки. Сначала по адресу: id в отчёте — IP ноды,
/// как SubNode.server у прямых узлов (CDN-рельс в отчёте нет — хаб меряет только ноды). Иначе
/// по имени (name == remark, «🇫🇮 Финляндия»): запасной путь, если формат id съедет.
/// Чистая функция — auto_select_test.
NodeStat? matchNodeStat(List<NodeStat>? stats, {required String server, required String remark}) {
  if (stats == null) return null;
  for (final s in stats) {
    if (server.isNotEmpty && s.id == server) return s;
  }
  for (final s in stats) {
    if (remark.isNotEmpty && s.name == remark) return s;
  }
  return null;
}

/// Обучение на истории коннектов к узлу. Живёт между запусками (prefs), в отличие от
/// приговора (NodeVerdict — 30 минут и привязка к сети) это ДОЛГАЯ память: узел, который
/// систематически рвёт коннекты, штрафуется даже после того, как свежий приговор истёк.
class NodeHistory {
  /// Успешные сессии (verify после коннекта прошёл).
  int ok;

  /// Неудачные коннекты: узел не пропустил трафик или сессия умерла в первую минуту.
  int fail;

  /// Подряд неудачные ПРОБЫ узла (замер молчит) — для экспоненциального бэкоффа переспроса.
  int probeFails;

  DateTime? lastOkAt, lastFailAt, lastProbeAt;

  NodeHistory({this.ok = 0, this.fail = 0, this.probeFails = 0,
      this.lastOkAt, this.lastFailAt, this.lastProbeAt});

  void recordOk() {
    ok++;
    lastOkAt = DateTime.now();
  }

  void recordFail() {
    fail++;
    lastFailAt = DateTime.now();
  }

  /// Итог замера узла: молчит — растим серию для бэкоффа; ответил — серия сгорает.
  void recordProbe(bool answered) {
    lastProbeAt = DateTime.now();
    if (answered) {
      probeFails = 0;
    } else {
      probeFails++;
    }
  }

  /// Штраф/бонус в мс-эквиваленте к скору узла. Ограничен снизу небольшим бонусом (хорошая
  /// история — лёгкий приоритет, а не победа над быстрым соседом) и сверху — так, чтобы даже
  /// отъявленный сбойщик уступал живому узлу только через скор, а не навсегда: сети меняются,
  /// и вчерашний мёртвый узел мог быть просто на чужой сети.
  double historyPenalty(DateTime now) {
    var p = 0.0;
    final total = ok + fail;
    if (total >= 2) {
      final failRate = fail / total;
      p += failRate * 150; // систематические сбои: до +150
      if (failRate < 0.2 && total >= 4) p -= 15; // устойчиво живой узел: маленький бонус
    }
    final lf = lastFailAt;
    if (lf != null) {
      final ageMin = now.difference(lf).inMinutes;
      // свежий сбой важнее давнего: +60 сразу после, тает до нуля за час
      if (ageMin < 60) p += (60 - ageMin).toDouble();
    }
    return p.clamp(-15.0, 200.0);
  }

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'fail': fail,
        'pf': probeFails,
        'okAt': lastOkAt?.toIso8601String(),
        'failAt': lastFailAt?.toIso8601String(),
        'probeAt': lastProbeAt?.toIso8601String(),
      };

  static NodeHistory? fromJson(Object? j) {
    if (j is! Map) return null;
    DateTime? ts(Object? v) => v == null ? null : DateTime.tryParse('$v');
    return NodeHistory(
      ok: (j['ok'] is num) ? (j['ok'] as num).toInt() : 0,
      fail: (j['fail'] is num) ? (j['fail'] as num).toInt() : 0,
      probeFails: (j['pf'] is num) ? (j['pf'] as num).toInt() : 0,
      lastOkAt: ts(j['okAt']),
      lastFailAt: ts(j['failAt']),
      lastProbeAt: ts(j['probeAt']),
    );
  }
}

/// Пауза перед следующей фон-пробой узла с [probeFails] подряд неудачными пробами:
/// 5, 10, 20, 40 минут, дальше потолок в час. Живой узел переспрашиваем часто (его скор
/// интереснее всего свежего), молчащий не должен сжигать батарею каждый прогон.
/// Чистая функция — auto_select_test.
Duration probeBackoff(int probeFails) {
  if (probeFails <= 0) return Duration.zero;
  const cap = Duration(minutes: 60);
  const step = Duration(minutes: 5);
  final d = step * (1 << (probeFails - 1).clamp(0, 4));
  return d > cap ? cap : d;
}

/// Пора ли фону переспросить узел: бэкофф с прошлой пробы вышел. Ни разу не пробовали — пора.
/// Чистая функция — auto_select_test.
bool probeDue(NodeHistory? h, DateTime now) {
  final at = h?.lastProbeAt;
  if (at == null) return true;
  return now.difference(at) >= probeBackoff(h?.probeFails ?? 0);
}

// ── Мягкая миграция живого туннеля (десктоп, hot-switch) ──
// Почему так консервативно. Владелец уже жаловался «туннель постоянно скачет» — автоматика,
// переключающая живое соединение на ЧУТЬ лучший узел, это ровно то самое «скачет». Поэтому
// миграция — не оптимизация, а ПРЕВЕНТИВНЫЙ фейловер: только когда текущий узел деградировал
// (мертв по хабу, не читается observatory или отклик ушёл за 250 мс), кандидат лучше с двойным
// запасом, трафик в сессии низкий (не дёргаем человека посреди закачки/стрима), сессия
// пережила разгон (3 мин) и с прошлой миграции прошло 10 минут (анти-маятник).

/// Отклик текущего узла, начиная с которого он считается деградировавшим для миграции.
const int kMigrateDegradedPingMs = 250;

/// Суммарный трафик (down+up, kbps), выше которого миграцию откладываем: живой поток —
/// не время для переключений, даже бесшовных (hot-switch рвёт TCP-сессии в момент переписи
/// прокси, хоть и не открывает окно голого трафика).
const int kMigrateMaxTrafficKbps = 400;

bool shouldAutoMigrate({
  required bool bestOn,
  required bool desktop,
  required double curScore,
  required double bestScore,
  required int curPingMs,
  required bool curStatsDead,
  required int trafficKbps,
  required int sessionSecs,
  required int sinceLastSwitchSecs,
}) {
  if (!bestOn || !desktop) return false;
  if (sessionSecs < 180 || sinceLastSwitchSecs < 600) return false;
  if (trafficKbps > kMigrateMaxTrafficKbps) return false;
  // Текущий узел обязан быть ДЕГРАДИРОВАВШИМ: «нашли чуть лучше» — не повод дёргать туннель.
  final degraded = curStatsDead || curPingMs <= 0 || curPingMs >= kMigrateDegradedPingMs;
  if (!degraded) return false;
  // И кандидат — разительно лучше (двойной запас против маятника).
  return bestScore < curScore * 0.6;
}
