part of '../main.dart';

// ============================ B-BOX ============================
// Раньше кнопка «B-box — VPN для всего дома» в Кабинете просто выкидывала человека в Telegram-бота.
// Это худший вид рекламы собственного товара: интерес возник в приложении, а рассказ про товар —
// где-то снаружи, и половина людей туда не доходит. Теперь у коробки есть свой экран: что это,
// что внутри, когда будет в продаже, и тут же — предзаказ и способ поторопить сборку.
//
// Заявки уходят в ту же ручку box-order, что и с сайта: заказ в ветку «🛒 Заказы», вопрос — в
// «📨 Заявки». Telegram-подписи у приложения нет, поэтому заявка приходит как лид «из приложения»
// (ручка это умеет: telegram_id может быть пустым).

/// Когда коробка появится в продаже. Держим одной константой: дату обещаем в трёх местах экрана,
/// и разъехаться им нельзя — обещание срока это то, за что спрашивают.
const String kBBoxEtaRu = 'примерно через месяц';
const String kBBoxEtaEn = 'in about a month';

extension ShellBBox on ShellState {
  void _openBBox() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _BBoxScreen()));
  }
}

class _BBoxScreen extends StatefulWidget {
  const _BBoxScreen();
  @override
  State<_BBoxScreen> createState() => _BBoxScreenState();
}

class _BBoxScreenState extends State<_BBoxScreen> {
  // Предзаказ
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _city = TextEditingController();
  final _addr = TextEditingController();
  final _zip = TextEditingController();
  final _note = TextEditingController();
  int _qty = 1;
  bool _sending = false;
  String? _err;
  bool _done = false;

  // «Поторопить сборку» — это та же поддержка, только с понятной темой
  final _hurry = TextEditingController();
  final _hurryContact = TextEditingController();
  bool _hurrySending = false;
  String? _hurryErr;
  bool _hurryDone = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _city, _addr, _zip, _note, _hurry, _hurryContact]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _en => appLang == 'en';

  Future<Map<String, dynamic>?> _post(Map<String, dynamic> body) async {
    try {
      final r = await http
          .post(Uri.parse('${kFnBase}box-order'),
              headers: {'content-type': 'application/json', 'apikey': kApiKey},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      try {
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) return d;
        if (d is Map) return d.cast<String, dynamic>();
      } catch (_) { /* не JSON — ниже отдадим общую ошибку */ }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _order() async {
    if (_sending) return;
    setState(() { _err = null; _sending = true; });
    final d = await _post({
      'action': 'order',
      'name': _name.text.trim(),
      'phone': _phone.text.trim(),
      'city': _city.text.trim(),
      'address': _addr.text.trim(),
      'postcode': _zip.text.trim(),
      'qty': _qty,
      // Комментарий помечаем предзаказом: менеджер не должен принять его за «отгрузите сегодня».
      'comment': [
        _en ? 'PRE-ORDER (from the app)' : 'ПРЕДЗАКАЗ (из приложения)',
        _note.text.trim(),
      ].where((s) => s.isNotEmpty).join(' · '),
    });
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (d != null && d['ok'] == true) {
        _done = true;
      } else {
        _err = (d?['error'] as String?) ??
            (_en ? 'Could not send the request, try again' : 'Не удалось отправить заявку, попробуй ещё раз');
      }
    });
  }

  Future<void> _sendHurry() async {
    if (_hurrySending) return;
    setState(() { _hurryErr = null; _hurrySending = true; });
    final d = await _post({
      'action': 'support',
      'name': _name.text.trim(),
      'contact': _hurryContact.text.trim(),
      'message': '${_en ? "B-box · speed up the build" : "B-box · ускорить сборку"}: ${_hurry.text.trim()}',
    });
    if (!mounted) return;
    setState(() {
      _hurrySending = false;
      if (d != null && d['ok'] == true) {
        _hurryDone = true;
        _hurry.clear();
      } else {
        _hurryErr = (d?['error'] as String?) ??
            (_en ? 'Could not send, try again' : 'Не удалось отправить, попробуй ещё раз');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Stack(children: [
        Positioned.fill(child: ColoredBox(color: C.bg)),
        // то же свечение сверху, что и на пейволе — экран должен ощущаться частью приложения
        Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
          gradient: RadialGradient(center: const Alignment(0, -0.85), radius: 1.0,
            colors: [C.accent.withValues(alpha: C.light ? 0.16 : 0.18), C.accent.withValues(alpha: 0)])))),
        SafeArea(child: Align(alignment: Alignment.topCenter, child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 32), children: [
            Row(children: [
              Semantics(button: true, label: tr('Назад'), child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: Padding(padding: const EdgeInsets.all(6),
                  child: Icon(Icons.arrow_back, color: C.text, size: 22)))),
              const SizedBox(width: 8),
              Text('B-box', style: disp(20, w: FontWeight.w800)),
            ]),
            const SizedBox(height: 6),

            // ── герой: коробка, стоящая на углу и медленно вращающаяся ──
            const SizedBox(height: 250, child: BBoxScene()),
            const SizedBox(height: 10),

            Center(child: _kicker(tr('устройство для дома'))),
            const SizedBox(height: 8),
            Center(child: Text(tr('VPN для всего дома'),
              textAlign: TextAlign.center, style: disp(26, w: FontWeight.w800))),
            const SizedBox(height: 10),
            Center(child: Text(
              tr('Коробка становится вашим роутером: защищён каждый экран в доме — телевизор, приставка, колонка, ноутбук. Ничего не настраивая на каждом устройстве.'),
              textAlign: TextAlign.center, style: mono(13, c: C.muted))),
            const SizedBox(height: 18),

            // ── срок ──
            _card(strong: true, child: Row(children: [
              _gIcon(Icons.schedule),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_en ? 'On sale $kBBoxEtaEn' : 'В продаже $kBBoxEtaRu',
                  style: disp(15, w: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(tr('Сейчас идёт сборка и закупка материалов. Предзаказ ничего не списывает — это место в очереди и фиксация цены.'),
                  style: mono(12, c: C.muted)),
              ])),
            ])),
            const SizedBox(height: 14),

            // ── что внутри ──
            _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [_gIcon(Icons.inventory_2_outlined), const SizedBox(width: 12), _kicker(tr('что внутри'))]),
              const SizedBox(height: 12),
              _bullet(Icons.wifi, tr('Точка доступа'), tr('Раздаёт свой Wi-Fi: подключился — уже под защитой')),
              _bullet(Icons.dns_outlined, tr('Наш туннель внутри'), tr('Те же узлы, что и в приложении — стабильные в любых сетях')),
              _bullet(Icons.devices_other, tr('Сколько угодно устройств'), tr('Телевизор, приставка, колонка — лимит подписки не тратится')),
              _bullet(Icons.power_settings_new, tr('Включил и забыл'), tr('Обновляется сама, настройка — один раз с телефона')),
            ])),
            const SizedBox(height: 14),

            // ── цена ──
            _card(child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('цена'), style: mono(11, c: C.muted)),
                const SizedBox(height: 4),
                Text('15 000 ₽', style: disp(24, w: FontWeight.w800, c: C.accent)),
              ])),
              Expanded(child: Text(
                tr('Устройство покупается один раз. Подписка на VPN оплачивается отдельно, как обычно.'),
                style: mono(11.5, c: C.muted))),
            ])),
            const SizedBox(height: 20),

            // ── предзаказ ──
            if (_done)
              _card(strong: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.check_circle_outline, color: C.ok, size: 22),
                  const SizedBox(width: 10),
                  Expanded(child: Text(tr('Предзаказ принят'), style: disp(16, w: FontWeight.w700))),
                ]),
                const SizedBox(height: 8),
                Text(_en
                    ? 'We will get in touch before shipping — on sale $kBBoxEtaEn. Nothing has been charged.'
                    : 'Свяжемся перед отправкой — в продаже $kBBoxEtaRu. Ничего не списано.',
                  style: mono(12.5, c: C.muted)),
              ]))
            else
              _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [_gIcon(Icons.local_shipping_outlined), const SizedBox(width: 12), _kicker(tr('предзаказ'))]),
                const SizedBox(height: 12),
                _field(_name, tr('Имя')),
                const SizedBox(height: 10),
                _field(_phone, tr('Телефон'), keyboard: TextInputType.phone),
                const SizedBox(height: 10),
                _field(_city, tr('Город')),
                const SizedBox(height: 10),
                _field(_addr, tr('Адрес доставки')),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _field(_zip, tr('Индекс'), keyboard: TextInputType.number)),
                  const SizedBox(width: 10),
                  // количество: кнопками, а не полем — на телефоне так быстрее и без опечаток
                  Container(
                    decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      _qtyBtn(Icons.remove, () => setState(() => _qty = (_qty - 1).clamp(1, 99))),
                      SizedBox(width: 34, child: Text('$_qty', textAlign: TextAlign.center, style: disp(15, w: FontWeight.w700))),
                      _qtyBtn(Icons.add, () => setState(() => _qty = (_qty + 1).clamp(1, 99))),
                    ]),
                  ),
                ]),
                const SizedBox(height: 10),
                _field(_note, tr('Комментарий (не обязательно)'), lines: 2),
                if (_err != null) ...[
                  const SizedBox(height: 10),
                  Text(_err!, style: mono(12, c: C.danger)),
                ],
                const SizedBox(height: 14),
                _btn(_sending ? tr('Отправляю…') : tr('Оформить предзаказ'),
                  kind: 0, icon: Icons.check, onTap: _sending ? null : _order),
                const SizedBox(height: 8),
                Text(tr('Предоплаты нет. Заявка уходит менеджеру, он свяжется по указанному телефону.'),
                  style: mono(11, c: C.muted)),
              ])),
            const SizedBox(height: 14),

            // ── поторопить сборку ──
            _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [_gIcon(Icons.bolt), const SizedBox(width: 12), _kicker(tr('поторопить сборку'))]),
              const SizedBox(height: 10),
              Text(tr('Чем больше подтверждённых предзаказов, тем крупнее партия материалов и тем быстрее сборка. Напиши, если готов забрать раньше или можешь помочь с комплектующими.'),
                style: mono(12, c: C.muted)),
              const SizedBox(height: 12),
              if (_hurryDone)
                Row(children: [
                  Icon(Icons.check_circle_outline, color: C.ok, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tr('Отправлено ✓ — ответим на указанный контакт'), style: mono(12, c: C.muted))),
                ])
              else ...[
                _field(_hurryContact, tr('Почта или @ник — куда ответить')),
                const SizedBox(height: 10),
                _field(_hurry, tr('Что предлагаешь?'), lines: 3),
                if (_hurryErr != null) ...[
                  const SizedBox(height: 10),
                  Text(_hurryErr!, style: mono(12, c: C.danger)),
                ],
                const SizedBox(height: 12),
                _btn(_hurrySending ? tr('Отправляю…') : tr('Отправить'),
                  kind: 1, icon: Icons.send, onTap: _hurrySending ? null : () {
                    if (_hurry.text.trim().length < 2) {
                      setState(() => _hurryErr = tr('Напиши, что предлагаешь'));
                      return;
                    }
                    if (_hurryContact.text.trim().length < 3) {
                      setState(() => _hurryErr = tr('Укажи, куда ответить — почта или @ник'));
                      return;
                    }
                    _sendHurry();
                  }),
              ],
            ])),
          ]),
        ))),
      ]),
    );
  }

  // ── мелкие строители: держим стиль ровно таким же, как в остальном приложении ──
  Widget _bullet(IconData ic, String title, String sub) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ic, size: 18, color: C.accent),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: disp(14, w: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(sub, style: mono(11.5, c: C.muted)),
          ])),
        ]),
      );

  Widget _qtyBtn(IconData ic, VoidCallback onTap) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(12), child: Icon(ic, size: 16, color: C.accent)),
      );

  Widget _field(TextEditingController c, String hint, {int lines = 1, TextInputType? keyboard}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(10)),
        child: TextField(
          controller: c,
          maxLines: lines,
          keyboardType: keyboard,
          style: mono(13, c: C.text),
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: hint,
            hintStyle: mono(12.5, c: C.muted),
          ),
        ),
      );

  // _card/_btn/_kicker/_gIcon живут в widgets.dart как методы ShellState. Экран отдельный, поэтому
  // повторяем их здесь тонкими обёртками — иначе пришлось бы тащить сюда весь ShellState.
  Widget _card({required Widget child, bool strong = false}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: strong ? C.accent.withValues(alpha: 0.08) : C.fill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: strong ? C.accent.withValues(alpha: 0.35) : C.line),
        ),
        child: child,
      );

  Widget _kicker(String t) => Text('// $t', style: mono(12, c: C.accent, w: FontWeight.w600));

  Widget _gIcon(IconData ic) => Container(width: 42, height: 42, alignment: Alignment.center,
      decoration: BoxDecoration(color: C.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Icon(ic, size: 20, color: C.accent));

  Widget _btn(String label, {int kind = 0, IconData? icon, VoidCallback? onTap}) {
    final solid = kind == 0;
    return Opacity(
      opacity: onTap == null ? 0.6 : 1,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: solid ? accentGrad : null,
            color: solid ? null : C.fill,
            borderRadius: BorderRadius.circular(12),
            border: solid ? null : Border.all(color: C.line),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: solid ? const Color(0xFF100A04) : C.text),
              const SizedBox(width: 8),
            ],
            Text(label, style: disp(15, w: FontWeight.w700, c: solid ? const Color(0xFF100A04) : C.text)),
          ]),
        ),
      ),
    );
  }
}

// ============================ СЦЕНА: КОРОБКА В ВОЗДУХЕ ============================
// Куб висит в пространстве, СТОИТ НА УГЛУ и медленно поворачивается вокруг вертикали; в центре —
// шестерёнка с буквой B, как на кнопке подключения. Рисуем сами, а не картинкой: экран должен
// перекрашиваться под выбранную тему (включая секретный «Фосфор»), а картинка этого не умеет.
class BBoxScene extends StatefulWidget {
  const BBoxScene({super.key});
  @override
  State<BBoxScene> createState() => BBoxSceneState();
}

class BBoxSceneState extends State<BBoxScene> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    // Полный оборот за 16 секунд: достаточно, чтобы разглядеть форму, и не мельтешит.
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 16))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Уважаем системное «уменьшить движение»: без анимации показываем ту же сцену статично.
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => CustomPaint(
        painter: BBoxPainter(reduce ? 0.12 : _c.value, C.accent, C.accentSoft, C.text),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class BBoxPainter extends CustomPainter {
  /// 0..1 — фаза оборота.
  final double t;
  final Color acc, accSoft, ink;
  BBoxPainter(this.t, this.acc, this.accSoft, this.ink);

  // ── маленькая 3D-математика ──
  // Вращение вокруг произвольной оси (формула Родрига). Нужна дважды: сам оборот куба вокруг его
  // же диагонали и постоянный наклон, который ставит эту диагональ вертикально — то есть куб на угол.
  static List<double> _rot(List<double> v, List<double> k, double a) {
    final c = math.cos(a), s = math.sin(a);
    final cross = [
      k[1] * v[2] - k[2] * v[1],
      k[2] * v[0] - k[0] * v[2],
      k[0] * v[1] - k[1] * v[0],
    ];
    final dot = k[0] * v[0] + k[1] * v[1] + k[2] * v[2];
    return [
      v[0] * c + cross[0] * s + k[0] * dot * (1 - c),
      v[1] * c + cross[1] * s + k[1] * dot * (1 - c),
      v[2] * c + cross[2] * s + k[2] * dot * (1 - c),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    // Размер подобран по РЕНДЕРУ, а не на глаз: при 0.30 куб с учётом диагонали (√3) и перспективы
    // вылезал за холст почти вдвое — фигура упиралась в края и читалась как плоское пятно.
    final r = math.min(size.width, size.height) * 0.20;

    // Диагональ куба — ось, вокруг которой он крутится; она же должна стоять вертикально.
    final d = 1 / math.sqrt(3);
    final diag = [d, d, d];
    // Ось наклона: поворачиваем диагональ до вертикали (0,1,0).
    // diag × (0,1,0) = (-dz, 0, dx). Знак важен: с обратным диагональ уезжала в (0.67,-0.33,0.67),
    // то есть куб висел «боком», а не стоял на углу. Проверено счётом: с этой осью диагональ
    // ложится ровно в (0,1,0), внизу оказывается РОВНО ОДНА вершина.
    final tilt = [-diag[2], 0.0, diag[0]];
    final tl = math.sqrt(tilt[0] * tilt[0] + tilt[1] * tilt[1] + tilt[2] * tilt[2]);
    final tiltAxis = tl == 0 ? [1.0, 0.0, 0.0] : [tilt[0] / tl, tilt[1] / tl, tilt[2] / tl];
    final tiltAngle = math.acos((diag[1]).clamp(-1.0, 1.0));

    // Лёгкое парение: куб покачивается по вертикали, тень под ним дышит в такт.
    final bob = math.sin(t * 2 * math.pi) * r * 0.06;

    List<double> world(List<double> p) {
      final spun = _rot(p, diag, t * 2 * math.pi);
      return _rot(spun, tiltAxis, tiltAngle);
    }

    Offset project(List<double> p) {
      const f = 8.0; // фокус: чем меньше, тем сильнее перспектива (и тем больше фигура на краях)
      final z = p[2];
      final k = f / (f - z);
      return Offset(cx + p[0] * r * k, cy - (p[1] * r * k) + bob);
    }

    // вершины единичного куба
    const verts = <List<double>>[
      [-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
      [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1],
    ];
    final w = [for (final v in verts) world(v)];
    final p2 = [for (final v in w) project(v)];

    // тень: она же «пол», от неё читается, что куб висит
    final shadowY = cy + r * 1.35;
    final shadowW = r * (1.15 - 0.06 * math.sin(t * 2 * math.pi));
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, shadowY), width: shadowW * 2, height: shadowW * 0.42),
      Paint()
        ..shader = RadialGradient(colors: [acc.withValues(alpha: 0.20), acc.withValues(alpha: 0)])
            .createShader(Rect.fromCenter(center: Offset(cx, shadowY), width: shadowW * 2, height: shadowW * 0.42))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // грани куба; рисуем от дальней к ближней (алгоритм художника)
    const faces = <List<int>>[
      [0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4],
      [2, 3, 7, 6], [1, 2, 6, 5], [0, 3, 7, 4],
    ];
    final order = [...List.generate(faces.length, (i) => i)];
    double depth(int i) => faces[i].map((j) => w[j][2]).reduce((a, b) => a + b) / 4;
    order.sort((a, b) => depth(a).compareTo(depth(b)));

    // Площадь проекции со знаком: у грани, повёрнутой к нам, обход по часовой стрелке даёт один
    // знак, у обратной — другой. Раньше рисовались ВСЕ шесть, полупрозрачные грани накладывались,
    // и на рендере куб выглядел плоским проволочным пятном вместо тела. Оставляем только лицевые.
    double area(List<int> f) {
      var a = 0.0;
      for (var k = 0; k < f.length; k++) {
        final p = p2[f[k]], q = p2[f[(k + 1) % f.length]];
        a += p.dx * q.dy - q.dx * p.dy;
      }
      return a / 2;
    }

    for (final i in order) {
      final f = faces[i];
      if (area(f) <= 0) continue;               // грань смотрит от нас — не рисуем
      final path = Path()..moveTo(p2[f[0]].dx, p2[f[0]].dy);
      for (var k = 1; k < f.length; k++) {
        path.lineTo(p2[f[k]].dx, p2[f[k]].dy);
      }
      path.close();
      // Ближние грани заметно светлее — объём должен читаться и на однотонном фоне.
      final dep = ((depth(i) + 1.7) / 3.4).clamp(0.0, 1.0);
      canvas.drawPath(path, Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [
            accSoft.withValues(alpha: 0.22 + 0.48 * dep),
            acc.withValues(alpha: 0.14 + 0.44 * dep),
          ],
        ).createShader(path.getBounds()));
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = accSoft.withValues(alpha: 0.55 + 0.40 * dep));
    }

    // ── шестерёнка с буквой B в центре грани, обращённой к нам ──
    final gr = r * 0.52;
    final gc = Offset(cx, cy + bob);
    final gp = Paint()
      ..shader = LinearGradient(colors: [accSoft, acc], begin: Alignment.topLeft, end: Alignment.bottomRight)
          .createShader(Rect.fromCircle(center: gc, radius: gr));
    for (int i = 0; i < 10; i++) {
      canvas.save();
      canvas.translate(gc.dx, gc.dy);
      canvas.rotate(i / 10 * 2 * math.pi + t * 2 * math.pi);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(0, -gr * 0.84), width: gr * 0.20, height: gr * 0.34),
          Radius.circular(gr * 0.05)),
        gp);
      canvas.restore();
    }
    canvas.drawCircle(gc, gr * 0.72, gp);
    canvas.drawCircle(gc, gr * 0.50, Paint()..color = const Color(0xFF0C0A14));
    canvas.drawCircle(gc, gr * 0.50, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = acc.withValues(alpha: 0.45));

    final tp = TextPainter(
      text: TextSpan(text: 'B', style: TextStyle(
        fontFamily: 'SpaceGrotesk', fontWeight: FontWeight.w800,
        fontSize: gr * 0.78, color: ink)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, gc - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(BBoxPainter old) => old.t != t || old.acc != acc || old.ink != ink;
}
