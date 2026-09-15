// Автовыбор сервера: чистая логика скоринга/гистерезиса/бэкоффа/миграции (auto_select.dart).
//
// Зачем именно этот тест. Режим «лучший сервер» раньше выбирал минимальный пинг без памяти
// и без гистерезиса: карточка сервера дребезжала между соседними узлами, узел с рябью канала
// выигрывал у стабильного, а систематически сбоящий стартовал каждый день с чистого листа.
// Здесь фиксируем контракт новых правил — чтобы следующая правка весов/порогов осознанно
// меняла поведение, а не ломала его молча.
import 'package:flutter_test/flutter_test.dart';
import 'package:bitaps_vpn/main.dart';

NodeStat _stat({bool ok = true, int? rtt, List<(int, int?)> series = const [], String name = '🇫🇮 Финляндия', String id = '1.2.3.4'}) =>
    NodeStat(name: name, id: id, ok: ok, rttNow: rtt, series: series);

void main() {
  const now = 2000000; // unix-секунды «сейчас» для тестов серии

  group('insightOf — джиттер/стабильность из серии /public/stats', () {
    test('ровная серия: джиттер ~0, стабильность 1', () {
      final s = _stat(series: [for (var i = 0; i < 20; i++) (now - i * 300, 40)]);
      final ins = insightOf(s, nowSec: now);
      expect(ins.jitterMs, closeTo(0, 0.001));
      expect(ins.stability, 1.0);
      expect(ins.dead, isFalse);
    });

    test('рябь канала считается как средний |Δrtt| соседних живых точек', () {
      // 40→80→40→80: |Δ| = 40,40,40 → джиттер 40
      final s = _stat(series: [(now - 900, 40), (now - 600, 80), (now - 300, 40), (now, 80)]);
      expect(insightOf(s, nowSec: now).jitterMs, closeTo(40, 0.001));
    });

    test('мёртвые точки рвут соседство джиттера и давят стабильность', () {
      final s = _stat(series: [(now - 600, 40), (now - 300, null), (now, 44)]);
      final ins = insightOf(s, nowSec: now);
      expect(ins.jitterMs, closeTo(0, 0.001),
          reason: 'разница через провал мерила бы даунтайм, а не рябь — не считаем её');
      expect(ins.stability, closeTo(2 / 3, 0.001));
    });

    test('старые точки (за окном 6 ч) в джиттер не входят', () {
      final s = _stat(series: [
        (now - 8 * 3600, 30), (now - 8 * 3600 + 300, 500), // давний всплеск — вне окна
        (now - 300, 40), (now, 40),
      ]);
      expect(insightOf(s, nowSec: now).jitterMs, closeTo(0, 0.001),
          reason: 'вчерашний всплеск про сегодняшнюю рябь ничего не говорит');
    });

    test('dead — только свежий отчёт с ok==false', () {
      final dead = _stat(ok: false);
      expect(insightOf(dead, nowSec: now, statsAge: const Duration(minutes: 3)).dead, isTrue);
      expect(insightOf(dead, nowSec: now, statsAge: const Duration(hours: 2)).dead, isFalse,
          reason: 'протухший отчёт — узел мог давно подняться, мёртвым не считаем');
    });

    test('нет записи — нейтральные метрики (без штрафа «за неизвестность»)', () {
      final ins = insightOf(null, nowSec: now);
      expect(ins.jitterMs, 0);
      expect(ins.stability, 1.0);
      expect(ins.dead, isFalse);
    });
  });

  group('autoScore — взвешенный скор по режимам', () {
    double score({int ping = 0, double jitter = 0, double stab = 1, int? statsRtt,
        bool dead = false, double hist = 0, bool cdn = false, int mode = 0}) =>
      autoScore(pingMs: ping, jitterMs: jitter, stability: stab, statsRtt: statsRtt,
          statsDead: dead, histPenalty: hist, isCdn: cdn, mode: mode);

    test('меньший честный пинг выигрывает у большего', () {
      expect(score(ping: 40), lessThan(score(ping: 90)));
    });

    test('незамеренный проигрывает любому замеренному', () {
      expect(score(ping: 0), greaterThan(score(ping: 400)),
          reason: 'ноль у незамеренного не должен выигрывать — болезнь прежнего выбора');
    });

    test('незамеренный с rtt от хаба лучше совсем неизвестного, но хуже замеренного', () {
      final withStats = score(ping: 0, statsRtt: 30);
      expect(withStats, lessThan(score(ping: 0)));
      expect(withStats, greaterThan(score(ping: 350)),
          reason: 'хаб меряет путь «хаб→нода», а не «пользователь→нода» — выше честного замера');
    });

    test('для Игр рябой узел проигрывает стабильному даже с меньшим пингом', () {
      final stable = score(ping: 60, jitter: 2, mode: 2);
      final spiky = score(ping: 40, jitter: 60, mode: 2);
      expect(stable, lessThan(spiky),
          reason: 'всплеск пинга в игре — фриз, джиттер весит сильнее среднего');
    });

    test('для Стрима решает стабильность серии, а не джиттер', () {
      final steady = score(ping: 80, jitter: 20, stab: 1.0, mode: 1);
      final flaky = score(ping: 60, jitter: 20, stab: 0.6, mode: 1);
      expect(steady, lessThan(flaky),
          reason: 'провал серии — буферизация у зрителя, стрим штрафует за неё');
    });

    test('мёртвый по хабу получает штраф, который перебивает только отсутствие альтернатив', () {
      expect(score(ping: 20, dead: true), greaterThan(score(ping: 300)));
      expect(score(ping: 20, dead: true), lessThan(score(ping: 0)),
          reason: 'мёртвый по хабу всё же лучше совсем неизвестного — хаб мог ошибиться');
    });

    test('CDN-рельса в обычной сети с лёгким штрафом, история сбоев — с нарастающим', () {
      expect(score(ping: 50, cdn: true), greaterThan(score(ping: 50)));
      expect(score(ping: 50, hist: 120), greaterThan(score(ping: 50, hist: -15)));
    });
  });

  group('shouldSwitchBest — гистерезис против дребезга', () {
    test('маленькая разница не переключает', () {
      expect(shouldSwitchBest(100, 95, curValid: true), isFalse,
          reason: '5 мс и 5% — в пределах гистерезиса, карточка не должна прыгать');
    });

    test('разительная разница переключает', () {
      expect(shouldSwitchBest(200, 100, curValid: true), isTrue);
    });

    test('невалидный текущий заменяется безусловно', () {
      expect(shouldSwitchBest(10, 500, curValid: false), isTrue,
          reason: 'удерживать заблокированный/исчезнувший узел «ради стабильности» нельзя');
    });
  });

  group('probeBackoff/probeDue — экспоненциальный бэкофф проб', () {
    test('серия неудач растит паузу 5→10→20→40→60 мин с потолком в час', () {
      expect(probeBackoff(0), Duration.zero);
      expect(probeBackoff(1), const Duration(minutes: 5));
      expect(probeBackoff(2), const Duration(minutes: 10));
      expect(probeBackoff(3), const Duration(minutes: 20));
      expect(probeBackoff(4), const Duration(minutes: 40));
      expect(probeBackoff(5), const Duration(minutes: 60));
      expect(probeBackoff(20), const Duration(minutes: 60), reason: 'потолок — час');
    });

    test('ни разу не пробованный — пора; внутри бэкоффа — рано; после — пора', () {
      final now = DateTime.now();
      expect(probeDue(null, now), isTrue);
      final h = NodeHistory(probeFails: 2, lastProbeAt: now.subtract(const Duration(minutes: 5)));
      expect(probeDue(h, now), isFalse, reason: 'при 2 неудачах пауза 10 минут');
      final old = NodeHistory(probeFails: 2, lastProbeAt: now.subtract(const Duration(minutes: 11)));
      expect(probeDue(old, now), isTrue);
    });
  });

  group('NodeHistory — обучение на коннектах', () {
    test('безупречный узел получает маленький бонус, сбойщик — большой штраф', () {
      final now = DateTime.now();
      final good = NodeHistory(ok: 10, lastOkAt: now);
      final bad = NodeHistory(ok: 1, fail: 9, lastFailAt: now);
      expect(good.historyPenalty(now), lessThan(0));
      expect(bad.historyPenalty(now), greaterThan(100));
    });

    test('свежий сбой важнее давнего: штраф тает за час', () {
      final now = DateTime.now();
      final fresh = NodeHistory(fail: 1, lastFailAt: now.subtract(const Duration(minutes: 1)));
      final old = NodeHistory(fail: 1, lastFailAt: now.subtract(const Duration(hours: 3)));
      expect(fresh.historyPenalty(now), greaterThan(old.historyPenalty(now)));
    });

    test('штраф ограничен: сети меняются, вчерашний сбойщик не изгоняется навсегда', () {
      final now = DateTime.now();
      final worst = NodeHistory(fail: 100, lastFailAt: now);
      expect(worst.historyPenalty(now), lessThanOrEqualTo(200));
    });

    test('удачная проба сбрасывает серию бэкоффа, неудачная — растит', () {
      final h = NodeHistory(probeFails: 3)..recordProbe(true);
      expect(h.probeFails, 0);
      h.recordProbe(false);
      expect(h.probeFails, 1);
    });

    test('история переживает запись и чтение', () {
      final h = NodeHistory(ok: 3, fail: 1, probeFails: 2, lastFailAt: DateTime.now());
      final back = NodeHistory.fromJson(h.toJson());
      expect(back, isNotNull);
      expect(back!.ok, 3);
      expect(back.fail, 1);
      expect(back.probeFails, 2);
      expect(back.lastFailAt, isNotNull);
      expect(NodeHistory.fromJson('мусор'), isNull);
    });
  });

  group('matchNodeStat — сопоставление stats узлу подписки', () {
    test('по IP (id отчёта == server узла), затем по имени', () {
      final stats = [_stat(id: '153.80.241.50', name: '🇫🇮 Финляндия'), _stat(id: '1.1.1.1', name: '🇫🇷 Франция')];
      expect(matchNodeStat(stats, server: '153.80.241.50', remark: 'x')!.name, '🇫🇮 Финляндия');
      expect(matchNodeStat(stats, server: 'bs01.bit-core.online', remark: '🇫🇷 Франция')!.id, '1.1.1.1',
          reason: 'рельсы по IP не матчатся — запасной путь по имени');
      expect(matchNodeStat(stats, server: '9.9.9.9', remark: '🇩🇪 Германия'), isNull);
      expect(matchNodeStat(null, server: '1.2.3.4', remark: 'x'), isNull);
    });
  });

  group('shouldAutoMigrate — мягкая миграция только при деградации', () {
    bool migrate({bool best = true, bool desktop = true, double cur = 400, double next = 100,
        int ping = 300, bool dead = false, int kbps = 0, int sess = 600, int last = 3600}) =>
      shouldAutoMigrate(bestOn: best, desktop: desktop, curScore: cur, bestScore: next,
          curPingMs: ping, curStatsDead: dead, trafficKbps: kbps,
          sessionSecs: sess, sinceLastSwitchSecs: last);

    test('деградировавший узел + разительно лучший кандидат + тишина → миграция', () {
      expect(migrate(), isTrue);
    });

    test('«нашли чуть лучше» — НЕ повод дёргать живой туннель', () {
      expect(migrate(ping: 60, dead: false), isFalse,
          reason: 'текущий не деградировал — владелец жаловался «туннель постоянно скачет»');
    });

    test('гейты: режим/платформа/возраст сессии/трафик/анти-маятник', () {
      expect(migrate(best: false), isFalse, reason: 'ручной выбор — уважаем, сам не переключаем');
      expect(migrate(desktop: false), isFalse, reason: 'hot-switch есть только на десктопе');
      expect(migrate(sess: 30), isFalse, reason: 'молодая сессия — дать разогнаться');
      expect(migrate(kbps: 5000), isFalse, reason: 'посреди закачки не переключаем');
      expect(migrate(last: 60), isFalse, reason: 'маятник миграций недопустим');
      expect(migrate(next: 350, cur: 400), isFalse, reason: 'кандидат обязан быть разительно лучше');
    });
  });
}
