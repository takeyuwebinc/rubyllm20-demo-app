require "test_helper"

class RunsHelperTest < ActionView::TestCase
  test "links an http or https URL the model returned, in a new tab" do
    [ "https://www.caa.go.jp/policies/", "http://example.com/page?q=1", "HTTPS://EXAMPLE.COM/", "https://ja.wikipedia.org/wiki/特定商取引法" ].each do |url|
      link = Nokogiri::HTML5.fragment(model_url_link("出典", url)).at("a")

      assert link, url
      assert_equal url, link["href"]
      assert_equal "_blank", link["target"]
      assert_equal "noopener", link["rel"]
      assert_equal "出典", link.text
    end
  end

  test "shows any other URL as text, not as a link" do
    [
      "javascript:alert(1)", "JavaScript:alert(1)", " javascript:alert(1)", "java\tscript:alert(1)",
      "data:text/html,<script>alert(1)</script>", "mailto:help@example.com", "//example.com/", "/runs/1", "", nil
    ].each do |url|
      assert_equal "出典", model_url_link("出典", url), url.inspect
    end
  end

  test "escapes the text it shows instead of a link" do
    assert_equal "&lt;script&gt;alert(1)&lt;/script&gt;", model_url_link("<script>alert(1)</script>", "javascript:alert(1)")
  end
end
