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

---

### Task 1: Убрать `extension.json` и сократить тройку версий до пары

`extension.json` читал только Extension Warehouse. В `.rbz` он никогда не попадал: `package.rb` намеренно его не кладёт, потому что сервис подписи Trimble отвергает любые лишние файлы в корне архива с «Extra files found». После отказа каталога файл не читает никто, а он остаётся седьмой точкой бампа версии, которую можно забыть.

**Files:**
- Delete: `mcp_for_sketchup/extension.json`
- Delete: `test/test_extension_json.rb`
- Delete: `test/test_version_triple.rb`
- Create: `test/test_version_pair.rb`

**Interfaces:**
- Consumes: ничего.
- Produces: `test/test_version_pair.rb` с классом `TestVersionPair` и единственным тестом `test_package_rb_version_matches_server_version`. Task 5 полагается на него как на страховку от рассинхрона `package.rb VERSION` и `Compat::SERVER_VERSION`.

- [ ] **Step 1: Удалить `extension.json`**

```bash
git rm mcp_for_sketchup/extension.json
```

- [ ] **Step 2: Убедиться, что тест это ловит**

Run: `ruby test/test_extension_json.rb`
Expected: FAIL — `Errno::ENOENT` на `File.read(EXT_JSON)` в обоих тестах. Это доказывает, что тест действительно сторожил файл, а не пустоту.

- [ ] **Step 3: Удалить тест-сторож**

```bash
git rm test/test_extension_json.rb
```

- [ ] **Step 4: Создать `test/test_version_pair.rb`**

```ruby
# test/test_version_pair.rb
# T-21: у релиза две Ruby-точки бампа версии — package.rb VERSION
# и Core::Compat::SERVER_VERSION. Handshake рапортует SERVER_VERSION,
# а package.rb на post-build-проверке сверяет свой VERSION с ext.version
# в загрузчике — разъезд пары даёт .rbz с противоречивой
# самоидентификацией. Python-сторона закрыта зеркальным
# tests/test_compat.py::test_python_version_matches_installed_metadata.
require "minitest/autorun"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"

class TestVersionPair < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def server_version
    MCPforSketchUp::Core::Compat::SERVER_VERSION
  end

  def test_package_rb_version_matches_server_version
    src = File.read(File.join(ROOT, "mcp_for_sketchup", "package.rb"))
    m = src.match(/^VERSION = '([^']+)'/)
    refute_nil m, "package.rb: строка VERSION = '...' не найдена"
    assert_equal server_version, m[1],
      "package.rb VERSION (#{m[1]}) != Compat::SERVER_VERSION (#{server_version})"
  end
end
```

- [ ] **Step 5: Удалить старый файл тройки**

```bash
git rm test/test_version_triple.rb
```

- [ ] **Step 6: Прогнать новый тест**

Run: `ruby test/test_version_pair.rb`
Expected: PASS — `1 runs, 2 assertions, 0 failures, 0 errors`.

- [ ] **Step 7: Прогнать всю Ruby-сюиту**

Run: `ruby test/run_all.rb`
Expected: `0 failures, 0 errors, 0 skips`. Число runs падает с 425 до 422 (минус два теста `TestExtensionJson`, минус один из `TestVersionTriple`).

- [ ] **Step 8: Коммит**

```bash
git add -A mcp_for_sketchup/extension.json test/test_extension_json.rb \
          test/test_version_triple.rb test/test_version_pair.rb
git commit -m "chore: drop extension.json, the Extension Warehouse metadata file

It never shipped inside the .rbz — package.rb excludes it because the
Trimble signing service rejects extra files at archive root — and the
catalogue that read it will not publish this extension. Removing it
takes the release from seven version-bump points down to six."
```

---

### Task 2: Убрать вариант сборки из `package.rb`, `.gitignore` и `main.rb`

`--variant` управлял единственным битом — `EVAL_ENABLED_BY_DEFAULT` в генерируемом `core/build_profile.rb`. Оба варианта больше не нужны, поэтому уходят и флаг, и генератор, и его потребитель в `main.rb`, и строка в `.gitignore`.

Новый тест сборки проверяет то, что действительно важно и не проверялось напрямую: **в корне архива лежат ровно загрузчик и одноимённая папка**. Это тот самый инвариант, из-за которого `extension.json` не паковался, — теперь он выражен положительно и заодно закрывает отсутствие любых удалённых файлов, не называя их по имени.

**Files:**
- Modify: `mcp_for_sketchup/package.rb` (переписывается целиком)
- Modify: `mcp_for_sketchup/mcp_for_sketchup/main.rb:46-52`
- Modify: `.gitignore` (последняя строка)
- Create: `test/test_package_output.rb`
- Delete: `test/test_package_default_variant.rb`

**Interfaces:**
- Consumes: `VERSION = '0.3.0'` в `package.rb` — Task 5 бампнёт её до `0.3.1`.
- Produces: `package.rb` без чтения `ARGV`; артефакт `mcp_for_sketchup_v<VERSION>.rbz`. Task 5, 7 и 8 ссылаются на это имя.

- [ ] **Step 1: Написать падающий тест `test/test_package_output.rb`**

```ruby
# test/test_package_output.rb
# Контракт единственного артефакта: package.rb собирает ровно один .rbz,
# имя которого не несёт суффикса сборки, а в корне архива лежат только
# загрузчик и одноимённая папка — сервис подписи Trimble отвергает всё
# остальное в корне с «Extra files found».
require "minitest/autorun"
require "zip"

class TestPackageOutput < Minitest::Test
  PKG_DIR = File.expand_path("../mcp_for_sketchup", __dir__)

  def test_package_rb_emits_one_unsuffixed_rbz_with_a_correct_loader
    Dir.chdir(PKG_DIR) do
      # Чистим прежние артефакты, чтобы проверять именно этот прогон.
      Dir.glob("mcp_for_sketchup_v*.rbz").each { |f| File.delete(f) }
      ok = system({ "RUBYOPT" => nil }, "ruby", "package.rb",
                  out: File::NULL, err: File::NULL)
      assert ok, "package.rb exited non-zero"

      files = Dir.glob("mcp_for_sketchup_v*.rbz")
      assert_equal 1, files.length,
        "package.rb must emit exactly one .rbz; got #{files.inspect}"
      assert_match(/\Amcp_for_sketchup_v\d+\.\d+\.\d+\.rbz\z/, files.first,
        "artifact must be named mcp_for_sketchup_v<X.Y.Z>.rbz; got #{files.first.inspect}")

      Zip::File.open(files.first) do |zf|
        roots = zf.entries.map { |e| e.name.split("/").first }.uniq.sort
        assert_equal ["mcp_for_sketchup", "mcp_for_sketchup.rb"], roots,
          "archive root must hold only the loader and its same-named folder; got #{roots.inspect}"

        loader = zf.find_entry("mcp_for_sketchup.rb")
        refute_nil loader, "loader mcp_for_sketchup.rb missing from #{files.first}"
        body = loader.get_input_stream.read
        assert_includes body, "'MCP Server for SketchUp'",
          "loader must declare the display name"
        assert_match(/ext\.version\s*=\s*'\d+\.\d+\.\d+'/, body,
          "loader must declare an X.Y.Z version")
      end

      Dir.glob("mcp_for_sketchup_v*.rbz").each { |f| File.delete(f) }
    end
  end
end
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `ruby test/test_package_output.rb`
Expected: FAIL на `assert_match(/\Amcp_for_sketchup_v\d+\.\d+\.\d+\.rbz\z/, ...)` — текущий `package.rb` собирает `mcp_for_sketchup_v0.3.0-warehouse.rbz`.

- [ ] **Step 3: Переписать `mcp_for_sketchup/package.rb` целиком**

```ruby
#!/usr/bin/env ruby
require 'zip'
require 'fileutils'

EXTENSION_NAME = 'mcp_for_sketchup'
VERSION = '0.3.0'

OUTPUT_NAME = "#{EXTENSION_NAME}_v#{VERSION}.rbz"

temp_dir = "#{EXTENSION_NAME}_temp"
begin
  # 1. Prepare a temp staging directory.
  FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
  FileUtils.mkdir_p(temp_dir)

  # .rbz must contain exactly one root .rb (the loader) + a same-named
  # directory (the extension subfolder); the Trimble signing service rejects
  # anything else at root with "Extra files found." The loader declares all
  # extension metadata via Sketchup::Extension.new, so nothing else is needed.
  # Guarded at test time by test/test_package_output.rb.
  FileUtils.cp_r(EXTENSION_NAME, temp_dir)
  FileUtils.cp("#{EXTENSION_NAME}.rb", temp_dir)

  # 2. Zip everything into the .rbz file. Wrap the zip in begin/rescue so a
  # crash MID-archive (disk full, I/O error) can't leave a partial/corrupt
  # .rbz: the outer `ensure` below cleans temp_dir but NOT OUTPUT_NAME, and a
  # leftover partial artifact could be shipped by a release glob
  # (gh release upload mcp_for_sketchup/*.rbz). rm_f only ever targets THIS
  # build's partial output — the rm below already removed any prior .rbz.
  FileUtils.rm(OUTPUT_NAME) if File.exist?(OUTPUT_NAME)
  begin
    Zip::File.open(OUTPUT_NAME, create: true) do |zipfile|
      Dir["#{temp_dir}/**/**"].each do |file|
        next if File.directory?(file)
        puts "Adding: #{file}"
        zipfile.add(file.sub("#{temp_dir}/", ''), file)
      end
    end
  rescue
    FileUtils.rm_f(OUTPUT_NAME)
    raise
  end
ensure
  # 3. Clean up — always runs, even on failure.
  FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
end

# 4. Post-build verification. What ships and carries the extension identity is
# the LOADER: a name or version regression there yields an .rbz that
# misidentifies itself in SketchUp's Extension Manager.
#
# A failed assertion here deletes OUTPUT_NAME before re-raising: the .rbz is
# complete but FAILED verification, so it must not survive for a release glob
# (e.g. `gh release upload mcp_for_sketchup/*.rbz`) to pick up.
begin
  Zip::File.open(OUTPUT_NAME) do |zf|
    loader = zf.find_entry("#{EXTENSION_NAME}.rb")
    raise "post-build: loader #{EXTENSION_NAME}.rb missing from #{OUTPUT_NAME}" unless loader
    loader_body = loader.get_input_stream.read
    unless loader_body.include?("'MCP Server for SketchUp'")
      raise "post-build: loader display name mismatch — expected 'MCP Server for SketchUp' in #{OUTPUT_NAME}"
    end
    unless loader_body =~ /ext\.version\s*=\s*'#{Regexp.escape(VERSION)}'/
      raise "post-build: loader version mismatch — expected #{VERSION} in #{OUTPUT_NAME}"
    end
    puts "post-build verified: loader name + version OK"
  end
rescue
  FileUtils.rm_f(OUTPUT_NAME)
  raise
end

puts "Created #{OUTPUT_NAME}"
```

- [ ] **Step 4: Убедиться, что тест проходит**

Run: `ruby test/test_package_output.rb`
Expected: PASS — `1 runs, 7 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Убрать хук загрузки из `main.rb`**

Удалить целиком строки 46-52 — блок комментария и условный require:

```ruby
  # core/build_profile.rb is autogenerated by package.rb at .rbz pack time.
  # It declares MCPforSketchUp::Core::BuildProfile with VARIANT and
  # EVAL_ENABLED_BY_DEFAULT constants. Absent in source-tree dev runs and
  # in unit tests — Config.eval_enabled? then falls back to the safe
  # warehouse default (false). See Task 10 for the generator.
  build_profile_path = File.join(PLUGIN_ROOT, "core", "build_profile.rb")
  Sketchup.require(build_profile_path) if File.exist?(build_profile_path)
```

Строка `LOAD_ORDER.each { |path| Sketchup.require(File.join(PLUGIN_ROOT, path)) }` выше и `MCPforSketchUp::Core::Config.load_from_defaults!` ниже остаются на месте; между ними должна остаться одна пустая строка.

- [ ] **Step 6: Убрать строку из `.gitignore`**

Удалить последнюю строку файла:

```
mcp_for_sketchup/mcp_for_sketchup/core/build_profile.rb
```

- [ ] **Step 7: Удалить старый тест вариантов**

```bash
git rm test/test_package_default_variant.rb
```

- [ ] **Step 8: Прогнать всю Ruby-сюиту**

Run: `ruby test/run_all.rb`
Expected: `0 failures, 0 errors, 0 skips`. Число runs падает с 422 до 420 (три теста `TestPackageDefaultVariant` заменены одним).

- [ ] **Step 9: Коммит**

```bash
git add -A mcp_for_sketchup/package.rb mcp_for_sketchup/mcp_for_sketchup/main.rb \
          .gitignore test/test_package_output.rb test/test_package_default_variant.rb
git commit -m "build: collapse the dual-variant build into a single .rbz

The two variants differed in one baked constant that told the plugin
whether eval_ruby starts open. With the Extension Warehouse channel
closed there is one audience left, so the generated build_profile.rb,
the --variant flag and the loader hook that consumed it all go.

The replacement test asserts the invariant that actually matters and
was never checked directly: the archive root holds only the loader and
its same-named folder, which is what the signing service enforces."
```

---

### Task 3: Схлопнуть дефолт `eval_enabled` в `config.rb`

`Config.eval_enabled?` заглядывал в `Core::BuildProfile`, а `DEFAULTS[:eval_enabled]` был sentinel-`nil` именно для того, чтобы отличить «pref не задан» (⇒ спросить сборку) от явного `false`. Сборка теперь одна, спрашивать некого — дефолт становится обычным значением `true`.

Асимметрия остаётся сознательной: **отсутствующий pref открывает гейт, не-boolean закрывает.** Испорченное значение — не основание включать исполнение произвольного кода, а выход из ситуации стоит одной галочки.

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/config.rb` (три места: `DEFAULTS`, `load_from_defaults!`, `eval_enabled?`, плюс комментарий у `coerce_bool_pref`)
- Modify: `test/test_config.rb`
- Modify: `test/test_settings_dialog.rb`
- Modify: `test/test_dispatch_post_handshake.rb:130` (комментарий)
- Delete: `test/test_build_profile_fixture.rb`

**Interfaces:**
- Consumes: `coerce_bool_pref(key, value, default:)` — уже существует, сигнатура не меняется.
- Produces: `Config::DEFAULTS[:eval_enabled] == true`; `Config.eval_enabled?` возвращает `@eval_enabled`, а при `nil` — `DEFAULTS[:eval_enabled]`. Task 6 цитирует это в `CLAUDE.md`.

- [ ] **Step 1: Переписать три теста в `test/test_config.rb` под новое поведение**

Заменить `test_defaults_include_eval_enabled_nil` (и заголовок секции над ним) на:

```ruby
  # --- prefs introduced in v0.2.0 ---

  def test_defaults_include_eval_enabled_true
    # Единственная сборка ⇒ обычное значение вместо sentinel-nil. eval
    # поставляется открытым, пользователь выключает его в Settings.
    assert_equal true, C::DEFAULTS[:eval_enabled]
  end
```

Заменить `test_eval_enabled_question_mark_when_build_profile_absent_returns_false` на:

```ruby
  def test_eval_enabled_question_mark_when_pref_unset_returns_default
    # Отсутствующий pref ⇒ read_default отдаёт DEFAULTS[:eval_enabled],
    # то есть открытый гейт. Sentinel-nil больше не переживает загрузку.
    C.load_from_defaults!(StubReader.new)  # no eval_enabled key in reader
    assert_equal true, C.eval_enabled,
      "an absent pref must resolve to the DEFAULTS value, not a sentinel"
    assert C.eval_enabled?
  end
```

Заменить комментарий внутри `test_load_from_defaults_coerces_non_boolean_eval_enabled_to_false` (сам код теста не трогать) на:

```ruby
    # Security (codex 6th-review): a persisted eval_enabled that is NOT a native
    # boolean (tampered or legacy string "true"/"false", an integer, etc.) must
    # fail CLOSED. A present-but-invalid value is NOT «unset»: coerce_bool_pref
    # resolves it to `false` (default: false), never to the open DEFAULTS value —
    # a corrupt pref is no basis for enabling arbitrary code execution. A naive
    # `!!raw` would be worse still (the string "false" → true). (log_level ERROR
    # keeps the coercion WARN out of the shared test output when Logger is loaded.)
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `ruby test/test_config.rb`
Expected: FAIL — два падения:
- `test_defaults_include_eval_enabled_true`: `Expected: true / Actual: nil`
- `test_eval_enabled_question_mark_when_pref_unset_returns_default`: `Expected: true / Actual: nil`

- [ ] **Step 3: Поменять `DEFAULTS` в `core/config.rb`**

Строку

```ruby
        eval_enabled:   nil,  # sentinel — unset pref triggers BuildProfile fallback (spec §4.2 + iter-1 CRITICAL-1)
```

заменить на

```ruby
        eval_enabled:   true,
```

- [ ] **Step 4: Упростить чтение pref в `load_from_defaults!`**

Строку с комментарием

```ruby
        # Sentinel-nil: pass explicit nil so read_default returns nil when key is absent.
        # That distinguishes «pref unset» (falls back to BuildProfile) from explicit `false`.
        # See spec §4.2 + iter-1 CRITICAL-1.
        raw_eval  = reader.read_default(SECTION, "eval_enabled",  nil)
```

заменить на

```ruby
        raw_eval  = reader.read_default(SECTION, "eval_enabled",  DEFAULTS[:eval_enabled])
```

И блок присваивания

```ruby
        # Absent pref (raw_eval.nil?) stays the nil sentinel → BuildProfile
        # fallback. A present-but-non-boolean value (tampered/corrupt pref) is
        # NOT «unset»: it fails CLOSED to false (default: false), so the
        # arbitrary-code gate never falls through to a truthy build default —
        # the github variant bakes EVAL_ENABLED_BY_DEFAULT=true and would
        # otherwise silently RE-OPEN. coerce_bool_pref still never `!!`-coerces a
        # non-boolean truthy (iter-2 CONCERN-3 + codex 6th-review).
        self.eval_enabled  = raw_eval.nil? ? nil : coerce_bool_pref(:eval_enabled, raw_eval, default: false)
```

заменить на

```ruby
        # An absent pref arrives here as DEFAULTS[:eval_enabled] — the ordinary
        # opt-out model. A present-but-non-boolean value (tampered/corrupt pref)
        # is different: it fails CLOSED to `false` rather than resolving to the
        # open default, because an unreadable value is no basis for enabling
        # arbitrary code execution and the user recovers with one checkbox.
        # coerce_bool_pref never `!!`-coerces a non-boolean truthy such as the
        # string "false" (iter-2 CONCERN-3 + codex 6th-review).
        self.eval_enabled  = coerce_bool_pref(:eval_enabled, raw_eval, default: false)
```

- [ ] **Step 5: Упростить `eval_enabled?`**

Весь метод вместе с предшествующим комментарием

```ruby
      # eval_enabled? returns the effective gate state. If a runtime pref
      # has been read (eval_enabled != nil), use it. Otherwise, fall back to
      # the build-time default — present as Core::BuildProfile when the
      # plugin was built from package.rb; absent in tests / dev runs (the
      # safer warehouse default of `false` then applies).
      def self.eval_enabled?
        unless @eval_enabled.nil?
          return @eval_enabled
        end
        # iter-2 SUGGESTION-2: `const_defined?(:X, false)` skips inherited
        # constants (e.g. anything reachable through Object). Without the
        # `false` flag a stray top-level `BuildProfile` or
        # `EVAL_ENABLED_BY_DEFAULT` constant defined by some other plugin
        # in the shared Ruby namespace would mask our intent.
        if Core.const_defined?(:BuildProfile, false) &&
           Core::BuildProfile.const_defined?(:EVAL_ENABLED_BY_DEFAULT, false)
          # Strict identity check — the arbitrary-code gate must fail CLOSED.
          # `!!X` would be WRONG here: in Ruby `!!"false"` and `!!1` are both
          # `true`, so a build bug that baked a truthy non-boolean into
          # build_profile.rb would OPEN the gate. Only a literal `true` enables
          # eval; every other value (the string "false", an Integer, …) resolves
          # to false. Mirrors the strictness of the runtime-pref read path, which
          # rejects non-booleans in coerce_bool_pref instead of coercing them
          # truthy (codex 4th-review review).
          Core::BuildProfile::EVAL_ENABLED_BY_DEFAULT == true
        else
          false
        end
      end
```

заменить на

```ruby
      # eval_enabled? returns the effective gate state. A pref that has been
      # read wins; `nil` means load_from_defaults! has not run yet — early boot,
      # or a unit test that sets nothing — and the shipped default applies.
      def self.eval_enabled?
        return @eval_enabled unless @eval_enabled.nil?
        DEFAULTS[:eval_enabled]
      end
```

- [ ] **Step 6: Поправить комментарий у `coerce_bool_pref`**

Последнее предложение

```ruby
      # and emits a one-shot WARN naming the offending key + value. Keeps
      # the sentinel-nil path explicit at the call site — callers that
      # want nil-pass-through must check `value.nil?` themselves.
```

заменить на

```ruby
      # and emits a one-shot WARN naming the offending key + value.
```

- [ ] **Step 7: Убедиться, что остаётся ровно одно падение**

Run: `ruby test/test_config.rb`
Expected: FAIL — ровно одно падение, `test_eval_enabled_question_mark_build_profile_fails_closed_for_non_boolean`: при `@eval_enabled = nil` предикат теперь возвращает `DEFAULTS[:eval_enabled]` и игнорирует подставленную константу, поэтому вторая итерация таблицы (`baked=false ⇒ expected=false`) получает `true`.

Второй BuildProfile-тест, `test_non_boolean_eval_pref_fails_closed_even_when_build_default_is_true`, **проходит** — но вхолостую: он подставляет константу, которую больше никто не читает, а его `refute` выполняется благодаря `coerce_bool_pref`, что уже проверено соседним `test_load_from_defaults_coerces_non_boolean_eval_enabled_to_false`. Удаляется как мёртвая обвязка, а не как упавший тест.

- [ ] **Step 8: Удалить оба BuildProfile-теста из `test/test_config.rb`**

Удалить целиком методы `test_eval_enabled_question_mark_build_profile_fails_closed_for_non_boolean` и `test_non_boolean_eval_pref_fails_closed_even_when_build_default_is_true` вместе с их комментариями — они идут подряд и завершают класс. Закрывающий `end` класса оставить.

- [ ] **Step 9: Прогнать `test_config.rb`**

Run: `ruby test/test_config.rb`
Expected: PASS — `0 failures, 0 errors`.

- [ ] **Step 10: Удалить фикстуру `test/test_build_profile_fixture.rb`**

```bash
git rm test/test_build_profile_fixture.rb
```

- [ ] **Step 11: Починить `test/test_settings_dialog.rb`**

В `TestSettingsDialogLoadStatePayload#setup` удалить блок

```ruby
    # Order-independence: ensure no BuildProfile lingers from another test
    # file in the same run_all.rb process, so eval_enabled? falls through to
    # the safe warehouse default of `false`.
    if MCPforSketchUp::Core.const_defined?(:BuildProfile)
      MCPforSketchUp::Core.send(:remove_const, :BuildProfile)
    end
```

Тест `test_eval_enabled_is_effective_false_not_nil_when_unset` вместе с комментарием над классом заменить на:

```ruby
  # Предикатная гарантия (iter-1 CRITICAL-2): :eval_enabled в payload берётся
  # из `eval_enabled?`, а не из сырого аксессора — не прочитанный pref обязан
  # прийти в UI как эффективное булево, иначе чекбокс останется в
  # неопределённом состоянии.
  def test_eval_enabled_is_effective_default_not_nil_when_unset
    assert_nil MCPforSketchUp::Core::Config.eval_enabled,
               "precondition: raw accessor should be nil (nothing loaded yet)"

    payload = S.load_state_payload
    assert_equal MCPforSketchUp::Core::Config::DEFAULTS[:eval_enabled],
                 payload[:eval_enabled],
                 "must be the effective default (eval_enabled?), not the raw nil accessor"
    refute_nil payload[:eval_enabled]
  end
```

Комментарий над самим классом (строки 88-90, «…so a sentinel-nil unset pref resolves to the effective `false`…») заменить на:

```ruby
# guarantee (iter-1 CRITICAL-2): :eval_enabled is sourced from the
# `eval_enabled?` predicate, NOT the raw accessor — so an unread pref
# resolves to the effective default, never leaking `nil` to the UI.
```

- [ ] **Step 12: Поправить заголовок секции в `test/test_dispatch_post_handshake.rb`**

Строку 130

```ruby
  # --- eval_ruby gate (warehouse compliance) ---
```

заменить на

```ruby
  # --- eval_ruby gate ---
```

Сами тесты не трогать: все они уже задают состояние гейта явно — `test_eval_ruby_returns_32010_when_disabled` через `saved_eval`, остальные через хелпер `with_eval_enabled`.

- [ ] **Step 13: Прогнать всю Ruby-сюиту**

Run: `ruby test/run_all.rb`
Expected: `0 failures, 0 errors, 0 skips`. Число runs падает с 420 до 416 (минус два BuildProfile-теста из `test_config.rb`, минус два из `test_build_profile_fixture.rb`).

- [ ] **Step 14: Коммит**

```bash
git add -A mcp_for_sketchup/mcp_for_sketchup/core/config.rb test/test_config.rb \
          test/test_settings_dialog.rb test/test_dispatch_post_handshake.rb \
          test/test_build_profile_fixture.rb
git commit -m "feat: ship eval_ruby enabled, drop the build-time gate default

The sentinel-nil default and the BuildProfile lookup behind it existed
to tell two builds apart. One build remains, so eval_enabled becomes an
ordinary DEFAULTS entry that ships true and is turned off in Settings.

A non-boolean pref still fails closed: a corrupt value is no basis for
enabling arbitrary code execution, and the user recovers with one
checkbox."
```

---

### Task 4: Убрать упоминания каталога из Python-текстов

Три места на Python-стороне называют пользователю несуществующий вариант сборки: сообщения о несовместимости версий советуют переустановить `-warehouse.rbz`, MCP-промпт объясняет гейт через «Extension Warehouse build», docstring инструмента — так же. Всё это видит LLM и через неё пользователь.

**Files:**
- Modify: `src/sketchup_mcp/compat.py` (`_msg_ruby_too_old`, `_msg_ruby_missing`)
- Modify: `src/sketchup_mcp/prompts.py` (§8)
- Modify: `src/sketchup_mcp/tools.py` (docstring `eval_ruby`)
- Test: `tests/test_compat.py` (`test_too_old_raises_with_reinstall_hint`, `test_none_raises_with_pre_dates_hint`)

**Interfaces:**
- Consumes: `MAX_RUBY` из `compat.py` — Task 5 бампнёт его до `0.3.1`, и имя `.rbz` в сообщениях подтянется само.
- Produces: ничего нового; сигнатуры не меняются.

- [ ] **Step 1: Ужесточить два существующих теста в `tests/test_compat.py`**

Оба теста уже проверяют, что подсказка содержит `.rbz`, но не какой именно. Новых тестов не добавляем — усиливаем имеющиеся.

В `test_too_old_raises_with_reinstall_hint` (диапазон подменён на `0.1.0..0.2.0`, поэтому имя предсказуемо) строку

```python
    assert ".rbz" in msg  # reinstall hint
```

заменить на

```python
    assert "mcp_for_sketchup_v0.2.0.rbz" in msg  # names the one artifact we ship
```

В `test_none_raises_with_pre_dates_hint` (диапазон не подменяется, поэтому берём константу) строку

```python
    assert ".rbz" in msg
```

заменить на

```python
    assert f"mcp_for_sketchup_v{compat.MAX_RUBY}.rbz" in msg
```

Проверять отсутствие старых суффиксов отдельным ассертом не нужно и вредно: он навсегда прописал бы мёртвые слова в дереве и сломал grep-критерий из Global Constraints. Положительного утверждения достаточно — имя с суффиксом ему не удовлетворяет.

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `uv run pytest tests/test_compat.py -q`
Expected: FAIL — два падения. Подсказки называют артефакт с суффиксом сборки, поэтому подстрока `mcp_for_sketchup_v0.2.0.rbz` (соответственно `mcp_for_sketchup_v0.3.0.rbz`) в них не находится.

- [ ] **Step 3: Переписать оба сообщения в `src/sketchup_mcp/compat.py`**

```python
def _msg_ruby_too_old(rv: str) -> str:
    return (
        f"SketchUp plugin v{rv} is too old for sketchup-mcp2 v{CLIENT_VERSION} "
        f"(requires v{MIN_RUBY}..v{MAX_RUBY}). "
        f"Reinstall mcp_for_sketchup_v{MAX_RUBY}.rbz from the GitHub release. "
        f"Call `get_version` to inspect handshake state."
    )
```

```python
def _msg_ruby_missing() -> str:
    return (
        f"SketchUp plugin pre-dates version-compat checking. "
        f"Reinstall mcp_for_sketchup_v{MAX_RUBY}.rbz from the GitHub release. "
        f"Call `get_version` to inspect handshake state."
    )
```

`_msg_ruby_too_new` не трогать — она про обновление Python-пакета и имени `.rbz` не содержит.

- [ ] **Step 4: Убедиться, что тест проходит**

Run: `uv run pytest tests/test_compat.py -v`
Expected: PASS — все тесты файла зелёные.

- [ ] **Step 5: Переписать §8 в `src/sketchup_mcp/prompts.py`**

Блок

```
# 8. eval_ruby gate (warehouse build)
In the Extension Warehouse build of the SketchUp extension, eval_ruby
is disabled by default. If a call to eval_ruby returns a string
starting with "eval_ruby is disabled.", that is not a failure: it is
```

заменить на

```
# 8. eval_ruby gate
eval_ruby ships enabled, but the user can close the gate in the
SketchUp extension's Settings. If a call to eval_ruby returns a string
starting with "eval_ruby is disabled.", that is not a failure: it is
```

Последнее предложение блока

```
Plugins → MCP Server → Settings...
```

заменить на

```
Plugins → MCP Server → Settings... — the checkbox is «Enable Ruby
evaluation».
```

Остальной текст §8 («Surface the full message to the user verbatim…») оставить как есть.

- [ ] **Step 6: Переписать docstring `eval_ruby` в `src/sketchup_mcp/tools.py`**

Абзац

```python
    Disabled by default in the Extension Warehouse build. If disabled, the
    SketchUp side returns JSON-RPC code -32010 with a user-facing message
    explaining how to enable it. This wrapper surfaces that message as a
    plain string so the LLM can repeat it to the user verbatim — without
    the `[code]` prefix that format_error would otherwise add.
```

заменить на

```python
    Enabled by default; the user can close the gate in the SketchUp
    extension's Settings. When closed, the SketchUp side returns JSON-RPC
    code -32010 with a user-facing message explaining how to re-enable it.
    This wrapper surfaces that message as a plain string so the LLM can
    repeat it to the user verbatim — without the `[code]` prefix that
    format_error would otherwise add.
```

- [ ] **Step 7: Прогнать всю Python-сюиту**

Run: `uv run pytest tests/ -q`
Expected: `177 passed` — новых тестов не добавлялось, два существующих стали строже.

- [ ] **Step 8: Коммит**

```bash
git add src/sketchup_mcp/compat.py src/sketchup_mcp/prompts.py \
        src/sketchup_mcp/tools.py tests/test_compat.py
git commit -m "docs: stop advertising build variants to the LLM and the user

The version-mismatch hints told users to reinstall a -warehouse .rbz
and mentioned a -github alternative; the modeling prompt and the
eval_ruby docstring explained the gate through a catalogue build that
will never exist. All three now describe the single artifact and the
Settings checkbox."
```

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
