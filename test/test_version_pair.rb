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
