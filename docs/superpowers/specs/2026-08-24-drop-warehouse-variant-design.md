# Отказ от warehouse-варианта — v0.3.1

**Статус:** spec — ожидает плана реализации
**Причина:** Trimble отклонил подачу v0.2.0 в Extension Warehouse. Формулировка ревьюера: сторонние MCP-серверы в каталог не публикуются в принципе — «we are not publishing any externally developed MCP servers in the extension warehouse». Это не список исправимых замечаний, а закрытая дверь: команда SketchUp намерена выпускать собственные MCP-решения и отвечать за их безопасность сама.
**Следствие:** вся инфраструктура двух сборок, созданная в v0.2.0 ради каталога, обслуживает несуществующий канал дистрибуции. Плагин распространяется только через GitHub Releases.

## 1. Что стало мёртвым, а что осталось полезным

v0.2.0 закрывала шесть замечаний первого ревью. После отказа они распадаются на две группы.

| Что было сделано в v0.2.0 | Ради чего | Судьба |
|---|---|---|
| `package.rb --variant=warehouse\|github`, генерация `core/build_profile.rb`, два `.rbz` | различить каталожную и github-сборку по дефолту `eval_ruby` | **удаляется** — канал один |
| `extension.json` (`product_id`, `name`, `version`) | форма подачи в Extension Warehouse | **удаляется** — в `.rbz` файл никогда не попадал (`package.rb` исключает его намеренно, иначе сервис подписи ругается «Extra files found»), а читал его только каталог |
| `docs/release.md` §7 + «Warehouse vs GitHub release» | инструкция по подаче | **удаляется** |
| Гейт `eval_ruby`: pref, `-32010`, чекбокс, блокирующее подтверждение | требование ревьюера | **остаётся**, дефолт меняется на `true` |
| Ренейм `SU_MCP` → `MCPforSketchUp`, `su_mcp/` → `mcp_for_sketchup/`, «MCP Server for SketchUp» | требование ревьюера | **остаётся** — имена лучше прежних, откат стоил бы 50 файлов churn'а и сброса настроек у всех установок |
| Title Case в `start_operation`, `WARN` по умолчанию, префикс `[MCPforSU]`, log-to-file, silent rescue → DEBUG | замечания ревьюера | **остаётся** — самостоятельные улучшения, к каталогу не привязаны |

## 2. Принятые решения

1. **Одна сборка.** `package.rb` производит `mcp_for_sketchup_v<VERSION>.rbz` без суффикса варианта.
2. **`eval_ruby` включён по умолчанию.** Тумблер в Settings остаётся, чтобы выключить eval можно было без переустановки плагина.
3. **Чистка `config.rb` до конца.** Sentinel-`nil` и обращение к `BuildProfile` существовали ровно ради различения двух сборок; вместе с вариантами уходят и они.
4. **Версия 0.3.1.** Патч: контракт провода, набор инструментов и их семантика не меняются.
5. **`MIN_*` остаются `0.3.0`.** Клиент 0.3.1 обязан разговаривать с уже установленным плагином 0.3.0 — включая warehouse-сборку, где eval выключен.

## 3. Изменения по подсистемам

### 3.1 Сборка — `mcp_for_sketchup/package.rb`

Удаляется:

- разбор `--variant`, константы `VARIANT` и `EVAL_DEFAULT`, проверка допустимых значений;
- генерация `mcp_for_sketchup/core/build_profile.rb` и её очистка в `ensure`;
- обе post-build проверки `build_profile.rb` внутри архива.

Остаётся:

- `begin/ensure` вокруг staging и zip — защита от частичного `.rbz` при обрыве сборки;
- post-build проверка лоадера: display-имя `'MCP Server for SketchUp'` и `ext.version`;
- `rescue`, удаляющий не прошедший проверку артефакт, чтобы его не подхватил релизный glob.

`OUTPUT_NAME` становится `"#{EXTENSION_NAME}_v#{VERSION}.rbz"`.

Флаг исчезает без надгробия: `ARGV` скрипт больше не читает, поэтому `--variant=warehouse` из старой истории команд молча проигнорируется и даст обычный артефакт. Проверку-заглушку не добавляем — она бы навсегда закрепила в коде имя удалённой сущности ради одного маловероятного сценария, а документация, где флаг упоминался, переписывается в этой же работе.

Из `.gitignore` уходит строка `mcp_for_sketchup/mcp_for_sketchup/core/build_profile.rb`.

### 3.2 Загрузка — `mcp_for_sketchup/mcp_for_sketchup/main.rb`

Удаляется условный `Sketchup.require(build_profile_path)` вместе с комментарием про запасной warehouse-дефолт. `LOAD_ORDER` не меняется.

### 3.3 Конфиг — `core/config.rb`

Три точечные правки.

**`DEFAULTS`.** Sentinel уступает место обычному значению:

```ruby
eval_enabled:   true,
```

**`load_from_defaults!`.** Ветка `raw_eval.nil? ? nil : ...` схлопывается:

```ruby
raw_eval = reader.read_default(SECTION, "eval_enabled", DEFAULTS[:eval_enabled])
...
self.eval_enabled = coerce_bool_pref(:eval_enabled, raw_eval, default: false)
```

**`eval_enabled?`.** Весь блок с `Core.const_defined?(:BuildProfile, false)` и строгой сверкой `== true` заменяется на:

```ruby
def self.eval_enabled?
  return @eval_enabled unless @eval_enabled.nil?
  DEFAULTS[:eval_enabled]
end
```

`nil` теперь возникает только до вызова `load_from_defaults!` — на раннем старте и в юнит-тестах, которые значение не задают.

**Асимметрия обработки pref'а — сознательная.** Отсутствующий pref открывает гейт (`read_default` вернёт дефолт `true`), а присутствующий, но не-boolean — закрывает (`coerce_bool_pref` вернёт `false` и напишет WARN). Правило читается так: «пользователь не высказался» ⇒ дефолт; «в prefs лежит мусор» ⇒ не открываем исполнение произвольного кода на основании испорченного значения. Ветка `coerce_bool_pref` уже написана, так что асимметрия не стоит ни строки, а выход из неё — одна понятная строка в тексте ошибки `-32010`.

Fail-closed откат в `update!` (review F1) остаётся без изменений: он охраняет целостность сессии при неудачной записи, а не различает варианты сборки.

### 3.4 Гейт eval — без изменений

Логика не трогается нигде (правки комментариев перечислены в §3.9):

- `handlers/eval.rb` — код `-32010`, `EVAL_DISABLED_MESSAGE`, проверка перед `eval`;
- `ui/settings_dialog.rb` — чекбокс и блокирующее `confirm_eval_enable` при переходе off→on;
- `ui/settings.html` — предупреждение и его эскалация при биндинге на `0.0.0.0` с включённым eval;
- `src/sketchup_mcp/tools.py` и `compat.py::EVAL_DISABLED_CODE` — маршрут `-32010` в текст для LLM;
- `examples/smoke_check.py` — пропуск eval-шагов при `-32010`. При новом дефолте он не срабатывает, но остаётся рабочим для пользователя, выключившего eval.

Маршрут `-32010` нужен и после смены дефолта: `MIN_RUBY` остаётся `0.3.0`, значит клиент 0.3.1 законно разговаривает с установленным плагином 0.3.0-warehouse, где eval выключен.

Следствие нового дефолта: на свежей установке чекбокс приходит отмеченным, и блокирующее предупреждение не показывается — оно срабатывает только на переходе off→on. Риск проговаривается в README и в предупреждении диалога при wildcard-биндинге.

### 3.5 Тесты

| Файл | Действие |
|---|---|
| `test/test_build_profile_fixture.rb` | удалить целиком — фикстура покрывала fall-through в `BuildProfile` |
| `test/test_extension_json.rb` | удалить вместе с `mcp_for_sketchup/extension.json` |
| `test/test_package_default_variant.rb` | переписать в `test/test_package_output.rb` |
| `test/test_version_triple.rb` | переименовать в `test/test_version_pair.rb`, оставить сверку `package.rb VERSION` ↔ `Compat::SERVER_VERSION` |
| `test/test_config.rb` | переписать блок eval-дефолтов |
| `test/test_settings_dialog.rb` | убрать `remove_const(:BuildProfile)` из `setup` и поправить комментарий про «safe warehouse default» |
| `test/test_dispatch_post_handshake.rb` | тесты гейта оставить; там, где закрытый гейт раньше получался сам собой, задать `Config.eval_enabled = false` явно |
| `test/test_operation_names.rb` | пины исходного текста не трогать |

`test_package_output.rb` проверяет на реальном запуске `package.rb`:

- собран ровно один `mcp_for_sketchup_v*.rbz`, без суффикса варианта;
- в архиве лежит лоадер с верным display-именем и версией;
- в архиве **нет** `mcp_for_sketchup/core/build_profile.rb`;
- в корне архива **нет** `extension.json`.

`test_config.rb` — конкретные правки:

- `test_defaults_include_eval_enabled_nil` → `test_defaults_include_eval_enabled_true`;
- `test_eval_enabled_question_mark_when_build_profile_absent_returns_false` → тест «pref не задан ⇒ `eval_enabled?` истинно»;
- новый тест: не-boolean pref ⇒ `eval_enabled?` ложно и в лог уходит WARN;
- блок BuildProfile-фикстуры (строгая сверка `== true`, ~строки 355–410) удаляется;
- тесты явных `true` / `false` в pref остаются как есть.

### 3.6 Python

- `src/sketchup_mcp/compat.py` — `_msg_ruby_too_old` и `_msg_ruby_missing` называют `mcp_for_sketchup_v{MAX_RUBY}.rbz`; хвост «(or the -github variant for eval_ruby)» уходит.
- `src/sketchup_mcp/prompts.py` — заголовок §8 теряет «(warehouse build)», текст «в Extension Warehouse-сборке eval_ruby выключен по умолчанию» превращается в «eval_ruby может быть выключен в настройках плагина». Инструкция «передать сообщение пользователю дословно» остаётся.
- `src/sketchup_mcp/tools.py` — из docstring `eval_ruby` уходит фраза про Extension Warehouse; описание маршрута `-32010` остаётся.

### 3.7 Версии — 0.3.1 в шести местах

`extension.json` исчезает, поэтому канонических точек бампа становится шесть:

1. `pyproject.toml` — `version`
2. `src/sketchup_mcp/__init__.py` — `__version__`
3. `src/sketchup_mcp/compat.py` — `MAX_RUBY`
4. `mcp_for_sketchup/package.rb` — `VERSION`
5. `mcp_for_sketchup/mcp_for_sketchup.rb` — `ext.version`
6. `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` — `SERVER_VERSION` и `MAX_PYTHON`

`MIN_RUBY` и `MIN_PYTHON` остаются `0.3.0`. После бампа — `uv lock`.

### 3.8 Документация

**`README.md`.** Секция «Distribution variants» удаляется целиком вместе с таблицей вариантов и примером сообщения о выключенном eval. На её место — короткий абзац в «Configuration» о том, что `eval_ruby` включён по умолчанию и выключается в Settings. Из команды сборки в Quickstart уходит `--variant`; в таблице инструментов строка «Escape hatch» теряет ссылку на удалённую секцию. Абзац «Per-call review» про подтверждение каждого вызова в MCP-клиенте остаётся — он описывает основной слой защиты.

**`CLAUDE.md`.** Пункт «Build variants & eval gate» переписывается в «eval gate»: описание `BuildProfile` и двух `.rbz` уходит, трёхслойная модель защиты сокращается до двух реальных слоёв — тумблер с подтверждением и per-call review в клиенте. Правятся команда сборки в «Development Commands» и строка «Enable Ruby evaluation» в таблице настроек.

**`docs/release.md`.** Удаляются §7 «Extension Warehouse submission» со всеми шаблонами (описание, тест-инструкции, релиз-ноты, стратегия скриншотов) и секция «Warehouse vs GitHub release» — примерно 220 строк из 346. Правятся: §0 теряет проверку `product_id`; §1 перечисляет шесть мест вместо семи; §3 содержит одну команду сборки; §6 прикладывает к релизу один `.rbz`.

Само-подпись через сервис подписи Trimble **остаётся**: она нужна для распространения вне каталога и к отказу отношения не имеет.

Добавляется короткая заметка о том, что Extension Warehouse закрыт для сторонних MCP-серверов по политике Trimble — чтобы через год не потратить ещё два месяца на повторную подачу.

**`docs/sketchup-ruby-cookbook.md`.** Вводное примечание про warehouse-вариант переписывается в примечание про настройку.

`NOTICE` и `LICENSE` не трогаются.

### 3.9 Комментарии со ссылками на warehouse-ревью

Шесть комментариев объясняют код через отклонённую подачу в каталог. Логика за ними остаётся, объяснение переписывается на самодостаточное — иначе комментарий отсылает к контексту, которого больше нет.

| Файл:строка | Текущая формулировка |
|---|---|
| `core/logger.rb:9` | «Required by warehouse reviewer note 2.» |
| `ui/settings_dialog.rb:220` | «…convention (warehouse reject note).» |
| `test/test_operation_names.rb:3` | «The reviewer's warehouse rejection (note 1)…» |
| `test/test_logger.rb:174` | «…the very clutter warehouse reject #2 was about» |
| `test/test_settings_dialog.rb:95` | «…safe warehouse default of `false`» |
| `test/test_dispatch_post_handshake.rb:130` | «--- eval_ruby gate (warehouse compliance) ---» |

## 4. За рамками

- **Откат ренейма.** Имена `MCPforSketchUp` / `mcp_for_sketchup` остаются.
- **Отказ от гейта eval.** Тумблер остаётся; меняется только его дефолт.
- **Удаление Title Case-меток, DEBUG-логов вместо silent rescue, дефолта `WARN`, префикса `[MCPforSU]`, log-to-file.** Всё это остаётся.
- **Миграция prefs.** Пользователь, который явно выключил eval на 0.2.0 или 0.3.0, сохранит его выключенным после апгрейда. Это корректное поведение; кода миграции не будет.
- **`.venv.broken-task8/`** в рабочем дереве — мусор от прошлой сессии, к этой работе отношения не имеет.

## 5. Риски

**Свежая установка получает открытое исполнение произвольного Ruby, ни разу не показав предупреждения.** Осознанная цена решения: аудитория плагина — разработчики, ставящие его с GitHub именно ради MCP, а каждый вызов `eval_ruby` всё равно проходит подтверждение в MCP-клиенте. Предупреждение в диалоге при биндинге на `0.0.0.0` остаётся и эскалируется, когда eval включён.

**Апгрейд поверх warehouse-установки выглядит как баг.** Пользователь с явным `eval_enabled=false` в prefs после установки 0.3.1 обнаружит eval по-прежнему выключенным. Упомянуть в релиз-нотах.

**Расхождение документации с последним опубликованным релизом.** До выпуска 0.3.1 на GitHub Releases лежат артефакты с суффиксами `-github` и `-warehouse`, а документация описывает имя без суффикса. Расхождение исчезает с публикацией 0.3.1.

**`test_package_output.rb` запускает реальную сборку** и требует установленного `rubyzip`, как и удаляемый предшественник. Требование к окружению тестов не меняется.

## 6. Критерии приёмки

1. `ruby test/run_all.rb` зелёный.
2. `uv run pytest tests/ -q` зелёный.
3. `(cd mcp_for_sketchup && ruby package.rb)` производит ровно один `mcp_for_sketchup_v0.3.1.rbz`; внутри архива нет ни `core/build_profile.rb`, ни `extension.json`.
4. `git grep -in warehouse -- ':!docs/superpowers/*'` находит только историческую заметку в `docs/release.md`.
5. `git grep -in 'buildprofile\|build_profile\|--variant' -- ':!docs/superpowers/*'` не находит ничего.
6. Файла `mcp_for_sketchup/extension.json` не существует.
7. Живая проверка на SketchUp: свежая установка `.rbz`, `Start Server`, вызов `eval_ruby` из MCP-клиента проходит без захода в Settings. Затем снять галочку «Enable Ruby evaluation» — следующий вызов возвращает текст `-32010`.
8. `examples/smoke_check.py` проходит полностью, без пропуска eval-шагов.

## 7. Следующий шаг

Передать в `superpowers:writing-plans` для декомпозиции. Предлагаемый порядок задач:

1. Удалить `extension.json` и `test_extension_json.rb`, сократить `test_version_triple.rb` до `test_version_pair.rb`.
2. Вычистить варианты из `package.rb`, поправить `.gitignore`, переписать тест сборки.
3. Убрать хук `build_profile` из `main.rb`.
4. Схлопнуть eval-дефолт в `config.rb` и переписать соответствующие тесты.
5. Поправить тексты на Python-стороне (`compat.py`, `prompts.py`, `tools.py`).
6. Бампнуть версию до 0.3.1 в шести местах, `uv lock`.
7. Переписать `README.md`, `CLAUDE.md`, `docs/release.md`, `docs/sketchup-ruby-cookbook.md`.
8. Переписать шесть комментариев из §3.9.
9. Прогнать критерии приёмки §6, включая живую проверку на SketchUp.
