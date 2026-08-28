# Drop the Warehouse Build Variant — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Убрать инфраструктуру двух сборок `.rbz`, созданную ради Extension Warehouse, который отказался публиковать сторонние MCP-серверы, и выпустить единственную сборку 0.3.1 с включённым по умолчанию `eval_ruby`.

**Architecture:** Работа состоит из удалений и правки текстов. Из `package.rb` уходит флаг `--variant` и генерация `core/build_profile.rb`; `Config.eval_enabled?` перестаёт заглядывать в `BuildProfile` и опирается на `DEFAULTS[:eval_enabled] = true`; `extension.json` исчезает вместе со своей точкой бампа версии. Сам гейт `eval_ruby` — pref, ошибка `-32010`, чекбокс в Settings, блокирующее подтверждение — остаётся нетронутым; меняется только его дефолт.

**Tech Stack:** Ruby (minitest, rubyzip), Python 3 (pytest, FastMCP, uv), SketchUp Ruby API.

**Spec:** `docs/superpowers/specs/2026-08-24-drop-warehouse-variant-design.md`

## Global Constraints

- **Версия релиза — `0.3.1`.** Бампается в шести местах (Task 5); `MIN_RUBY` и `MIN_PYTHON` остаются `0.3.0` — контракт провода не меняется.
- **Единственное имя артефакта — `mcp_for_sketchup_v<X.Y.Z>.rbz`.** Без суффикса варианта.
- **Дефолт гейта — `Config::DEFAULTS[:eval_enabled] = true`.** Отсутствующий pref открывает гейт; присутствующий, но не-boolean, закрывает его (`coerce_bool_pref(..., default: false)`).
- **Никаких автоформаттеров** по `mcp_for_sketchup/mcp_for_sketchup/handlers/**` и по `test/test_operation_names.rb`, `test/test_transform_absolute.rb`, `test/test_joints_frame_compensation.rb` — эти тесты пинят точный текст исходника вплоть до отступов.
- **Комментарии в проекте двуязычные.** Пишите на языке окружающего файла: `test_version_pair.rb` и `handlers/eval.rb` — по-русски, `core/config.rb` и `package.rb` — по-английски.
- **После работы этих grep'ов не должно остаться следов** (кроме одной исторической заметки в `docs/release.md`):
  - `git grep -in warehouse -- ':!docs/superpowers/*'`
  - `git grep -in 'buildprofile\|build_profile\|--variant' -- ':!docs/superpowers/*'`
- **Базовые счётчики тестов до работы:** Ruby — 425 runs / 1149 assertions; Python — 177 tests. Обе сюиты зелёные.
- **Тест сборки удаляет `.rbz` из `mcp_for_sketchup/`.** `ruby test/run_all.rb` вычищает `mcp_for_sketchup_v*.rbz` — это ожидаемое поведение, а не поломка.
- **Коммиты стейджат явные пути.** Никогда `git add -A .` и `git add .`: в рабочем дереве лежит неотслеживаемый и не покрытый `.gitignore` каталог `.venv.broken-task8/`, который широкий add затянет в коммит. И не перечисляйте в `git add` пути, уже удалённые через `git rm` — команда прервётся с `pathspec did not match any files`, а `git rm` эти удаления уже застейджил.

---

### Task 1: Убрать `extension.json` и сократить тройку версий до пары

✅ Done — see commit(s): `255d78b`, `2de1528` (fix round 1: header comment corrected to three version literals)

---

### Task 2: Убрать вариант сборки из `package.rb`, `.gitignore` и `main.rb`

✅ Done — see commit(s): `7854c95`

---

### Task 3: Схлопнуть дефолт `eval_enabled` в `config.rb`

✅ Done — see commit(s): `5e92ed3` (scope expanded during execution: also cleared five further `BuildProfile` references in `ui/settings_validator.rb`, `ui/settings_dialog.rb`, `test/test_settings_dialog.rb`, `test/test_config.rb`)

---

### Task 4: Убрать упоминания каталога из Python-текстов

✅ Done — see commit(s): `7b24091`

---

### Task 5: Бамп версии до 0.3.1

Шесть канонических мест. `MIN_RUBY` и `MIN_PYTHON` остаются `0.3.0`: набор инструментов, их параметры, формы ответов и протокол не меняются, поэтому клиент 0.3.1 обязан продолжать разговаривать с уже установленным плагином 0.3.0.

**Files:**
- Modify: `pyproject.toml:3`
- Modify: `src/sketchup_mcp/__init__.py:1`
- Modify: `src/sketchup_mcp/compat.py` (`MAX_RUBY`)
- Modify: `mcp_for_sketchup/package.rb` (`VERSION`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup.rb` (`ext.version`)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` (`SERVER_VERSION`, `MAX_PYTHON`)
- Modify: `uv.lock` (через `uv lock`)

**Interfaces:**
- Consumes: `test/test_version_pair.rb::test_package_rb_version_matches_server_version` (Task 1) и `test_package_output.rb` (Task 2) — оба ловят половинчатый бамп.
- Produces: артефакт `mcp_for_sketchup_v0.3.1.rbz`, на который ссылаются Tasks 7 и 8.

- [ ] **Step 1: Бампнуть Ruby-половину частично, чтобы увидеть красный**

В `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb`:

```ruby
      SERVER_VERSION = "0.3.1"
      MIN_PYTHON   = "0.3.0"
      MAX_PYTHON   = "0.3.1"
```

- [ ] **Step 2: Убедиться, что инварианты ловят рассинхрон**

Run: `ruby test/run_all.rb`
Expected: FAIL — `test_version_pair.rb` сообщает `package.rb VERSION (0.3.0) != Compat::SERVER_VERSION (0.3.1)`; `test_compat.rb::test_max_python_matches_server_version` остаётся зелёным, поскольку `MAX_PYTHON` бампнут вместе с `SERVER_VERSION`.

- [ ] **Step 3: Догнать остальные пять мест**

`mcp_for_sketchup/package.rb`:

```ruby
VERSION = '0.3.1'
```

`mcp_for_sketchup/mcp_for_sketchup.rb`:

```ruby
    ext.version     = '0.3.1'
```

`pyproject.toml`:

```toml
version = "0.3.1"
```

`src/sketchup_mcp/__init__.py`:

```python
__version__ = "0.3.1"
```

`src/sketchup_mcp/compat.py`:

```python
MIN_RUBY = "0.3.0"
MAX_RUBY = "0.3.1"
```

- [ ] **Step 4: Обновить комментарий политики MIN/MAX в `compat.py`**

Блок

```python
# Policy: MAX_* tracks the new release; MIN_* moves only on a release
# that breaks wire/handler contract with the previous counterpart.
# Currently MIN == MAX (exact-match handshake); 0.3.0 moved both floors on the
# batch-1+2 handler-contract break (absolute transform position, stricter
# validation, changed response shapes) — see docs/release.md.
```

заменить на

```python
# Policy: MAX_* tracks the new release; MIN_* moves only on a release
# that breaks wire/handler contract with the previous counterpart.
# 0.3.0 moved both floors on the batch-1+2 handler-contract break (absolute
# transform position, stricter validation, changed response shapes). 0.3.1 is
# packaging and copy only, so the floors stay at 0.3.0 and the supported range
# is 0.3.0..0.3.1 on both sides — see docs/release.md.
```

- [ ] **Step 5: Обновить `uv.lock`**

Run: `uv lock`
Expected: `uv.lock` меняется, в нём появляется `version = "0.3.1"` для `sketchup-mcp2`.

- [ ] **Step 6: Прогнать обе сюиты**

Run: `ruby test/run_all.rb && uv run pytest tests/ -q`
Expected: обе зелёные. Ruby — `0 failures, 0 errors`; Python — `177 passed`.

- [ ] **Step 7: Собрать `.rbz` и проверить имя**

```bash
(cd mcp_for_sketchup && ruby package.rb)
ls mcp_for_sketchup/*.rbz
```

Expected: ровно один файл `mcp_for_sketchup/mcp_for_sketchup_v0.3.1.rbz`, вывод скрипта заканчивается `post-build verified: loader name + version OK` и `Created mcp_for_sketchup_v0.3.1.rbz`.

- [ ] **Step 8: Коммит**

```bash
rm -f mcp_for_sketchup/*.rbz
git add pyproject.toml uv.lock src/sketchup_mcp/__init__.py src/sketchup_mcp/compat.py \
        mcp_for_sketchup/package.rb mcp_for_sketchup/mcp_for_sketchup.rb \
        mcp_for_sketchup/mcp_for_sketchup/core/compat.rb
git commit -m "chore: bump to v0.3.1

Packaging and copy only — the wire protocol, the tool set and every
response shape are untouched, so both MIN floors stay at 0.3.0 and a
0.3.1 client still talks to an installed 0.3.0 plugin."
```

---

### Task 6: Переписать README, CLAUDE.md, cookbook и комментарии, ссылающиеся на отказ

Пользовательская документация обещает выбор из двух сборок, которого нет. Плюс четыре комментария в коде и тестах объясняют существующие решения через замечания ревьюера — отсылка к контексту, которого больше нет.

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/sketchup-ruby-cookbook.md:9-15`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/logger.rb:9`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb:220`
- Modify: `test/test_operation_names.rb:2-6`
- Modify: `test/test_logger.rb:172-176`

**Interfaces:**
- Consumes: `Config::DEFAULTS[:eval_enabled] = true` (Task 3), имя артефакта `mcp_for_sketchup_v0.3.1.rbz` (Tasks 2, 5).
- Produces: ничего исполняемого.

- [ ] **Step 1: Удалить секцию «Distribution variants» из `README.md`**

Удалить целиком блок от заголовка `## Distribution variants` до конца абзаца «Per-call review» включительно — то есть всё между строкой `- **Ruby SketchUp extension** — runs a TCP server inside SketchUp and executes commands against the live model.` и заголовком `## Quickstart`. Между ними должна остаться одна пустая строка.

- [ ] **Step 2: Поправить команду сборки в Quickstart**

Абзац и блок

```markdown
Either grab the latest `.rbz` from GitHub Releases (or the Extension Warehouse) or build it from source. The build accepts `--variant=warehouse|github` (default: `warehouse`); see [Distribution variants](#distribution-variants):

```bash
gem install --user-install rubyzip
(cd mcp_for_sketchup && ruby package.rb --variant=warehouse)
# → mcp_for_sketchup/mcp_for_sketchup_v<version>-warehouse.rbz
# For the dev/power-user build with eval_ruby on by default:
(cd mcp_for_sketchup && ruby package.rb --variant=github)
# → mcp_for_sketchup/mcp_for_sketchup_v<version>-github.rbz
```
```

заменить на

```markdown
Either grab the latest `.rbz` from the [Releases page](https://github.com/zinin/sketchup-mcp2/releases) or build it from source:

```bash
gem install --user-install rubyzip
(cd mcp_for_sketchup && ruby package.rb)
# → mcp_for_sketchup/mcp_for_sketchup_v<version>.rbz
```
```

- [ ] **Step 3: Поправить строку «Escape hatch» в таблице инструментов**

```markdown
| **Escape hatch** | `eval_ruby` — arbitrary Ruby inside SketchUp for anything not covered above. **Disabled by default in the warehouse build** — see [Distribution variants](#distribution-variants). |
```

заменить на

```markdown
| **Escape hatch** | `eval_ruby` — arbitrary Ruby inside SketchUp for anything not covered above. Enabled by default; close the gate in the Settings dialog — see [Configuration](#ruby-side-settings-dialog-inside-sketchup). |
```

- [ ] **Step 4: Дописать абзац про гейт в раздел настроек Ruby-стороны**

В `### Ruby side (Settings dialog inside SketchUp)` после абзаца, начинающегося «The Ruby side logs at **`WARN` by default**…», и перед блоком `> **⚠ Security warning:**` вставить:

```markdown
`eval_ruby` — the arbitrary-Ruby escape hatch — is **enabled by default**. Uncheck **Enable Ruby evaluation** in the Settings dialog to close the gate; the setting persists across SketchUp restarts, and re-enabling it pops a blocking confirmation spelling out the risk (arbitrary Ruby ⇒ full filesystem / network / shell access). With the gate closed, a client's `eval_ruby` call comes back as a plain message telling the user how to re-open it.

**Per-call review.** Open gate or not, the exact Ruby a client sends stays visible in your MCP client — Claude Desktop and Claude Code display every tool call's arguments and let you approve or deny each one before it runs, so you can review each snippet case by case. (That per-call prompt is skipped only if you opt out of approvals, e.g. Claude Code's `--dangerously-skip-permissions`.)
```

- [ ] **Step 5: Проверить README на висячие ссылки**

Run: `grep -n 'distribution-variants\|Distribution variants\|--variant\|warehouse' README.md`
Expected: пусто.

- [ ] **Step 6: Переписать пункт про гейт в `CLAUDE.md`**

Пункт `- **Build variants & eval gate**: …` (со строки 34, целиком до строки перед `- **Version handshake (one-time on connect)**`) заменить на:

```markdown
- **eval gate**: `eval_ruby` is gated by the `eval_enabled` pref, which
  ships **on** (`Config::DEFAULTS[:eval_enabled] = true`) and is closed from
  `Plugins → MCP Server → Settings...`. An absent pref resolves to that
  default; a present-but-non-boolean pref fails **closed** — a corrupt value
  is no basis for enabling arbitrary code execution. Gate closed ⇒
  `handlers/eval.rb::eval_ruby` raises JSON-RPC `-32010`, which
  `tools.py::eval_ruby` turns into a user-facing message (no `[code]` prefix)
  so the LLM repeats it verbatim. Arbitrary-code risk is guarded in two
  layers: (1) a **blocking enable-time security confirm**
  (`ui/settings_dialog.rb::confirm_eval_enable` — warns it grants full
  filesystem/network/shell access), shown whenever the gate is re-opened
  after being closed; (2) **per-call review at the MCP client** — Claude
  Desktop / Claude Code show each `eval_ruby` call's code to approve or deny.
  The extension deliberately does NOT log or re-prompt the code — that would
  duplicate the client's permission UI and break autonomous
  (`--dangerously-skip-permissions`) operation.
```

- [ ] **Step 7: Поправить команду сборки в `CLAUDE.md`**

```bash
# Build .rbz extension package — defaults to warehouse variant
cd mcp_for_sketchup && ruby package.rb --variant=warehouse && cd ..
# For GitHub release (eval enabled by default):
cd mcp_for_sketchup && ruby package.rb --variant=github && cd ..
```

заменить на

```bash
# Build .rbz extension package
cd mcp_for_sketchup && ruby package.rb && cd ..
```

- [ ] **Step 8: Поправить строку таблицы настроек в `CLAUDE.md`**

```markdown
| Enable Ruby evaluation | **off** (warehouse) | Gates `eval_ruby`. Off by default in the warehouse `.rbz` (`BuildProfile::EVAL_ENABLED_BY_DEFAULT=false`), on in the github build. Turning it on pops a blocking security confirm (arbitrary code ⇒ full filesystem/network/shell). |
```

заменить на

```markdown
| Enable Ruby evaluation | **on** | Gates `eval_ruby`. Ships enabled; uncheck to close the gate. Re-enabling it pops a blocking security confirm (arbitrary code ⇒ full filesystem/network/shell). |
```

- [ ] **Step 9: Обновить счётчики тестов в `CLAUDE.md`**

Run: `ruby test/run_all.rb 2>&1 | tail -1 && uv run pytest tests/ -q 2>&1 | tail -1`

Подставить фактические числа в строки

```markdown
ruby test/run_all.rb           # Ruby (minitest; stdlib + rubyzip for the package test) — 425 runs / 1149 assertions
uv run pytest tests/ -q        # Python (pytest) — 177 tests
```

- [ ] **Step 10: Переписать вводное примечание в `docs/sketchup-ruby-cookbook.md`**

Блок

```markdown
> **eval_ruby gate.** Every recipe in this cookbook is delivered to
> SketchUp via the MCP `eval_ruby` tool. In the warehouse-variant build,
> `eval_ruby` is disabled by default — open `Plugins → MCP Server →
> Settings...` and check «Enable Ruby evaluation» (you will be asked to
> confirm a security warning). The GitHub-release variant ships with
> `eval_ruby` already enabled.
```

заменить на

```markdown
> **eval_ruby gate.** Every recipe in this cookbook is delivered to
> SketchUp via the MCP `eval_ruby` tool. It ships enabled; if the gate has
> been closed, calls come back as a message instead of running — open
> `Plugins → MCP Server → Settings...` and check «Enable Ruby evaluation»
> (you will be asked to confirm a security warning).
```

- [ ] **Step 11: Переписать четыре комментария, ссылающихся на ревью**

`mcp_for_sketchup/mcp_for_sketchup/core/logger.rb` — удалить строку 9:

```ruby
      # Required by warehouse reviewer note 2.
```

Две строки над ней уже объясняют смысл префикса.

`mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb:220`:

```ruby
          # convention (warehouse reject note).
```

заменить на

```ruby
          # convention.
```

`test/test_operation_names.rb` — строки 2-6:

```ruby
# Source-level guards against regressing the Undo-menu labels back to
# snake_case identifiers. The reviewer's warehouse rejection (note 1)
# requires Title Case strings here because they are user-visible in
# SketchUp's Edit → Undo / Redo menu. These tests parse the handler
# files directly to avoid stubbing the entire Sketchup::Model API.
```

заменить на

```ruby
# Source-level guards against regressing the Undo-menu labels back to
# snake_case identifiers. Title Case is required here because these
# strings are user-visible in SketchUp's Edit → Undo / Redo menu. These
# tests parse the handler files directly to avoid stubbing the entire
# Sketchup::Model API.
```

Пины ниже по файлу не трогать.

`test/test_logger.rb` — строки 172-176:

```ruby
    # The fallback notice must appear ONCE per failure episode, not once per
    # line — an unwritable log path under traffic must never flood the shared
    # Ruby console (the very clutter warehouse reject #2 was about). ConfigReset
    # in setup clears the one-shot flag, so the first failed write emits and the
    # rest are suppressed until a successful write re-arms it.
```

заменить на

```ruby
    # The fallback notice must appear ONCE per failure episode, not once per
    # line — an unwritable log path under traffic must never flood the Ruby
    # console every other extension shares. ConfigReset in setup clears the
    # one-shot flag, so the first failed write emits and the rest are
    # suppressed until a successful write re-arms it.
```

- [ ] **Step 12: Прогнать обе сюиты**

Run: `ruby test/run_all.rb && uv run pytest tests/ -q`
Expected: обе зелёные, счётчики совпадают с записанными в `CLAUDE.md` на шаге 9.

- [ ] **Step 13: Коммит**

```bash
git add README.md CLAUDE.md docs/sketchup-ruby-cookbook.md \
        mcp_for_sketchup/mcp_for_sketchup/core/logger.rb \
        mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb \
        test/test_operation_names.rb test/test_logger.rb
git commit -m "docs: describe one build instead of two

README promised a choice between a catalogue build and a GitHub build;
CLAUDE.md documented a BuildProfile constant that no longer exists. Four
comments explained live decisions through a rejected submission — the
decisions stand on their own, so the explanations now do too."
```

---

### Task 7: Вычистить процедуру подачи в каталог из `docs/release.md`

Из 346 строк примерно 220 обслуживают подачу в Extension Warehouse: пошаговая инструкция, значения полей формы, шаблоны описания и тест-инструкций, стратегия скриншотов, объяснение двух артефактов. Всё это уходит, а на его место встаёт одна заметка о том, почему канал закрыт — чтобы через год не потратить ещё два месяца на повторную попытку.

Само-подпись через сервис подписи Trimble остаётся: она нужна для распространения вне каталога.

**Files:**
- Modify: `docs/release.md`

**Interfaces:**
- Consumes: имя артефакта `mcp_for_sketchup_vX.Y.Z.rbz` (Task 2), шесть точек бампа (Tasks 1, 5).
- Produces: ничего исполняемого.

- [ ] **Step 1: Убрать проверку `product_id` из §0**

Удалить из `## 0. Pre-flight` блок

````markdown
```bash
# Confirm Trimble product_id matches the new identity (v0.2.0+).
grep '"product_id"' mcp_for_sketchup/extension.json
# Expected: "product_id": "MCP_FOR_SKETCHUP"
```
````

вместе с предшествующей пустой строкой.

- [ ] **Step 2: Сократить §1 до шести мест**

Заголовок

```markdown
## 1. Bump version in 7 places (must match)
```

заменить на

```markdown
## 1. Bump version in 6 places (must match)
```

и удалить пункт списка

```markdown
- `mcp_for_sketchup/extension.json` — `"version": "X.Y.Z"`
```

- [ ] **Step 3: Свести §3 к одной команде сборки**

Блок

```bash
(cd mcp_for_sketchup && ruby package.rb --variant=warehouse)  # → mcp_for_sketchup_vX.Y.Z-warehouse.rbz
(cd mcp_for_sketchup && ruby package.rb --variant=github)     # → mcp_for_sketchup_vX.Y.Z-github.rbz
```

заменить на

```bash
(cd mcp_for_sketchup && ruby package.rb)   # → mcp_for_sketchup_vX.Y.Z.rbz
```

- [ ] **Step 4: Переписать §6 под один артефакт**

Абзац

```markdown
Attach both `.rbz` variants (see [§3](#3-build-artifacts)) plus the Python wheel/sdist. The github variant attached here must already be self-signed via the Trimble signing service; the warehouse variant is the same unsigned build you submit to EW (EW signs its own copy after review):
```

заменить на

```markdown
Attach the `.rbz` (see [§3](#3-build-artifacts)) plus the Python wheel/sdist. The `.rbz` must already be self-signed via the [Trimble signing service](https://extensions.sketchup.com/developer/sign-extension) — SketchUp refuses to load an unsigned extension under its default loading policy:
```

и в блоке `gh release create` две строки

```
  mcp_for_sketchup/mcp_for_sketchup_vX.Y.Z-github.rbz \
  mcp_for_sketchup/mcp_for_sketchup_vX.Y.Z-warehouse.rbz
```

заменить на одну

```
  mcp_for_sketchup/mcp_for_sketchup_vX.Y.Z.rbz
```

- [ ] **Step 5: Удалить §7 целиком**

Удалить всё от заголовка `## 7. Extension Warehouse submission (optional, ~2–3 day review)` до строки, непосредственно предшествующей заголовку `## Notes`. Это включает подразделы «Build the warehouse `.rbz`», «EW form values», «Description template», «Testing Instructions template», «Release Notes template», «Screenshots» и «Submit and what happens next».

- [ ] **Step 6: Удалить секцию «Warehouse vs GitHub release» целиком**

Удалить всё от заголовка `## Warehouse vs GitHub release` до конца файла, включая подраздел «Submitting via Extension Warehouse (v0.2.0+)» и шаблон релиз-нот v0.2.0.

- [ ] **Step 7: Добавить историческую заметку в «Notes»**

В конец раздела `## Notes` (который после шага 5 становится последним разделом файла) добавить пункт:

```markdown
- **The Extension Warehouse is not a distribution channel for this project.** Trimble denied the v0.2.0 submission in August 2026 on policy grounds, not on fixable defects: they publish no externally developed MCP servers, reserving the catalogue for tools they build and secure themselves. Do not spend another two-month review cycle on it. GitHub Releases is the only channel — the `.rbz` still goes through the [Trimble signing service](https://extensions.sketchup.com/developer/sign-extension), which is a separate, self-serve flow with no review.
```

- [ ] **Step 8: Проверить, что ссылки внутри файла никуда не ведут в пустоту**

Run: `grep -n '](#' docs/release.md`
Expected: остаются только якоря на существующие заголовки. Ссылок вида `#7-extension-warehouse-submission…`, `#warehouse-vs-github-release` и `#3-build-artifacts` на удалённые секции быть не должно — последний якорь валиден, §3 остаётся.

- [ ] **Step 9: Проверить, что «warehouse» встречается ровно один раз**

Run: `grep -c -i warehouse docs/release.md`
Expected: `1` — только заметка из шага 7.

- [ ] **Step 10: Коммит**

```bash
git add docs/release.md
git commit -m "docs(release): drop the Extension Warehouse submission procedure

About 220 of 346 lines documented an intake form, its field values, the
description and testing-instruction templates, and a screenshot strategy
for a catalogue that will not accept this extension. One note replaces
them so the next release does not rediscover the policy the hard way.

Self-signing stays: it is a separate self-serve flow, and SketchUp needs
it to load the extension at all."
```

---

### Task 8: Финальная проверка

Прогон всех критериев приёмки из §6 спецификации плюс живая проверка на SketchUp, которую юнит-тесты закрыть не могут.

**Files:** ничего не меняется, кроме возможных исправлений найденных огрехов.

**Interfaces:**
- Consumes: результат Tasks 1-7.
- Produces: подтверждение готовности ветки к PR.

- [ ] **Step 1: Обе сюиты**

Run: `ruby test/run_all.rb && uv run pytest tests/ -q`
Expected: `0 failures, 0 errors, 0 skips` и `N passed` без падений.

- [ ] **Step 2: Сборка артефакта**

```bash
rm -f mcp_for_sketchup/*.rbz
(cd mcp_for_sketchup && ruby package.rb)
ls -1 mcp_for_sketchup/*.rbz
```

Expected: ровно один `mcp_for_sketchup/mcp_for_sketchup_v0.3.1.rbz`.

- [ ] **Step 3: Проверить содержимое архива**

```bash
python3 -c "
import zipfile
z = zipfile.ZipFile('mcp_for_sketchup/mcp_for_sketchup_v0.3.1.rbz')
names = z.namelist()
roots = sorted({n.split('/')[0] for n in names})
print('roots:', roots)
assert roots == ['mcp_for_sketchup', 'mcp_for_sketchup.rb'], roots
assert not [n for n in names if n.endswith('build_profile.rb')], 'stray generated file'
assert 'extension.json' not in names, 'extension.json must not ship'
print('OK —', len(names), 'entries')
"
```

Expected: `roots: ['mcp_for_sketchup', 'mcp_for_sketchup.rb']` и `OK — N entries` без AssertionError.

- [ ] **Step 4: Grep-критерии**

```bash
git grep -in warehouse -- ':!docs/superpowers/*'
git grep -in 'buildprofile\|build_profile\|--variant' -- ':!docs/superpowers/*'
test -e mcp_for_sketchup/extension.json && echo "FAIL: extension.json still exists" || echo "OK: extension.json gone"
```

Expected: первый grep — одна строка, заметка в `docs/release.md`; второй — пусто; третий — `OK: extension.json gone`.

- [ ] **Step 5: Живая проверка на SketchUp — открытый гейт**

Установить `mcp_for_sketchup_v0.3.1.rbz` через `Window → Extension Manager → Install Extension` в SketchUp, где плагин ещё не стоял (или предварительно удалив старый и сбросив настройки секции `MCPforSketchUp`), перезапустить SketchUp, затем `Plugins → MCP Server → Start Server`.

Вызвать `eval_ruby` с кодом `Sketchup.active_model.entities.length` из MCP-клиента.

Expected: возвращается число, а не сообщение о выключенном гейте. В `Plugins → MCP Server → Settings...` галочка **Enable Ruby evaluation** стоит, окно предупреждения при установке не показывалось.

- [ ] **Step 6: Живая проверка — закрытый гейт**

Снять галочку **Enable Ruby evaluation**, сохранить, повторить вызов `eval_ruby`.

Expected: клиент получает текст `eval_ruby is disabled. Open Plugins → MCP Server → Settings... and check 'Enable Ruby evaluation'. WARNING: …`. Вернуть галочку — всплывает блокирующее подтверждение с предупреждением о полном доступе к файловой системе, сети и shell; после подтверждения вызов снова работает.

- [ ] **Step 7: Живой smoke**

Run: `uv run python examples/smoke_check.py`
(для раздельной установки — с префиксом `SKETCHUP_MCP_HOST=<хост SketchUp>`)
Expected: все 25 шагов пройдены, в итоговом отчёте нет суффикса о пропущенных eval-шагах.

- [ ] **Step 8: Проверить чистоту дерева**

```bash
rm -f mcp_for_sketchup/*.rbz
git status --short
```

Expected: только неотслеживаемый `.venv.broken-task8/` (мусор прошлой сессии, к этой работе не относится) и, если он ещё не удалён, каталог `docs/superpowers/`.

- [ ] **Step 9: Убрать план и спецификацию перед PR**

Согласно правилам проекта документы `docs/superpowers/` не должны попадать в диф PR — они остаются доступны в истории ветки.

```bash
git rm -r docs/superpowers/
git commit -m "chore: remove internal plan/spec docs before PR

They stay reachable in this branch's history."
```

- [ ] **Step 10: Финальный прогон перед PR**

Run: `ruby test/run_all.rb && uv run pytest tests/ -q && git log --oneline master..HEAD`
Expected: обе сюиты зелёные; в логе восемь-девять коммитов этой работы.

---

## Self-Review

**Покрытие спецификации.** Каждый раздел §3 спецификации закрыт задачей: §3.1 и §3.2 — Task 2; §3.3 — Task 3; §3.4 не требует работы (проверяется в Tasks 3 и 8); §3.5 распределён между Tasks 1, 2, 3; §3.6 — Task 4; §3.7 — Task 5; §3.8 — Tasks 6 и 7; §3.9 — Tasks 3 и 6. Критерии §6 целиком прогоняются в Task 8.

**Два уточнения к спецификации, найденные при подготовке плана.**

1. §3.5 требовал в `test_dispatch_post_handshake.rb` «задать `Config.eval_enabled` явно там, где закрытый гейт раньше получался по умолчанию». Проверка исходника показала, что все eval-тесты в файле уже задают состояние явно — через `saved_eval` или хелпер `with_eval_enabled`. Правки логики не нужно, остаётся только комментарий (Task 3, Step 12).

2. §3.5 требовал от нового теста сборки утверждений «в архиве нет `build_profile.rb`» и «в корне нет `extension.json`». Именование удалённых сущностей конфликтует с grep-критериями §6 и по сути было бы надгробием. План заменяет обе проверки одной положительной и более сильной: **в корне архива лежат ровно `mcp_for_sketchup.rb` и `mcp_for_sketchup/`** (Task 2, Step 1). Это тот самый инвариант, ради которого `extension.json` не паковался, он закрывает любые лишние файлы, а не два поимённо, и не содержит мёртвых слов. Проверка «нет `build_profile.rb`» дополнительно выполняется вручную в Task 8, Step 3, где скрипт живёт вне репозитория.

3. §3.6 описывал правку сообщений в `compat.py` как чистую замену текста. На деле два существующих теста — `test_too_old_raises_with_reinstall_hint` и `test_none_raises_with_pre_dates_hint` — уже проверяют подсказку, но слабо (`assert ".rbz" in msg`). Task 4 не добавляет третий тест, а ужесточает эти два до точного имени артефакта: красный переход получается бесплатно, число тестов не растёт.

**Проверенная ложная тревога.** `test/test_compat.rb:86` и `tests/test_compat.py:75` жёстко зашивают `"0.3.0"` как «слишком новую» версию, что выглядит как поломка после бампа `MAX_*` до `0.3.1`. Оба теста подменяют диапазон на `0.1.0..0.2.0` (`with_range` в Ruby, `monkeypatch` в Python), поэтому реальные константы на них не влияют. Правок не требуется.

**Согласованность имён.** `test_version_pair.rb`/`TestVersionPair` (Task 1) → потребляется в Task 5, Step 2. `test_package_output.rb`/`TestPackageOutput` (Task 2) → упоминается в Task 5, Step 7. `Config::DEFAULTS[:eval_enabled]` (Task 3) → цитируется в Task 6, Step 6 и в Task 3, Step 11. `mcp_for_sketchup_v0.3.1.rbz` (Task 5) → Tasks 7 и 8. `coerce_bool_pref(key, value, default:)` — сигнатура не меняется ни в одной задаче.

**Порядок задач.** Task 5 обязан идти после Task 1 (нужен `test_version_pair.rb`) и после Task 2 (нужен новый `package.rb`). Task 6, Step 9 записывает финальные счётчики тестов, поэтому должен идти после всех удалений тестов (Tasks 1, 2, 3) и после Task 4, добавляющего один Python-тест.
