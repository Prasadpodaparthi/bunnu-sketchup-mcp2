# test/test_package_output.rb
# Контракт единственного артефакта: package.rb собирает ровно один .rbz,
# имя которого не несёт суффикса сборки, а в корне архива лежат только
# загрузчик и одноимённая папка — сервис подписи Trimble отвергает всё
# остальное в корне с «Extra files found».
require "minitest/autorun"
require "open3"
require "zip"

class TestPackageOutput < Minitest::Test
  PKG_DIR = File.expand_path("../mcp_for_sketchup", __dir__)

  def test_package_rb_emits_one_unsuffixed_rbz_with_a_correct_loader
    Dir.chdir(PKG_DIR) do
      # Чистим прежние артефакты, чтобы проверять именно этот прогон.
      Dir.glob("mcp_for_sketchup_v*.rbz").each { |f| File.delete(f) }
      # stderr захватываем, а не выбрасываем: post-build-проверки внутри
      # package.rb (загрузчик на месте, display-имя, версия) прерывают
      # сборку сообщением о том, какая именно не прошла. С err: File::NULL
      # любая из них выглядит как безликое «exited non-zero».
      _out, err, status = Open3.capture3({ "RUBYOPT" => nil }, "ruby", "package.rb")
      assert status.success?, "package.rb exited non-zero; stderr:\n#{err}"

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
