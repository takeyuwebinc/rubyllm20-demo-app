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

  test "marks the end of each cited span with the source's number, linking to it in the list" do
    marked = answer_with_citation_marks("返品できます。送料はお客様の負担です。", [ { "end_index" => 7 }, { "end_index" => 19 } ])

    assert_equal "返品できます。[1]送料はお客様の負担です。[2]", text_of(marked)
    marks = Nokogiri::HTML5.fragment(marked).css("sup[data-citation-mark] a")
    assert_equal [ "#citation-1", "#citation-2" ], marks.map { |mark| mark["href"] }
  end

  test "puts a mark in the middle of the answer, and at the very start" do
    assert_equal "返品[1]できます。", text_of(answer_with_citation_marks("返品できます。", [ { "end_index" => 2 } ]))
    assert_equal "[1]返品できます。", text_of(answer_with_citation_marks("返品できます。", [ { "end_index" => 0 } ]))
  end

  test "puts marks that end at the same place in the order of their numbers" do
    marked = answer_with_citation_marks("返品できます。", [ { "end_index" => 7 }, { "end_index" => 2 }, { "end_index" => 7 } ])

    assert_equal "返品[2]できます。[1][3]", text_of(marked)
  end

  test "leaves out the mark of a source with no place in the answer" do
    [ nil, -1, 8, "7", 7.0 ].each do |end_index|
      citation = { "end_index" => end_index }

      assert_equal "返品できます。", text_of(answer_with_citation_marks("返品できます。", [ citation ])), end_index.inspect
      assert_not citation_marked?(citation, "返品できます。"), end_index.inspect
    end
    assert citation_marked?({ "end_index" => 7 }, "返品できます。")
    assert citation_marked?({ "end_index" => 0 }, "返品できます。")
  end

  # end_index counts characters of the answer as it was recorded. Escaping
  # the answer before splitting it would move every mark after a <.
  test "escapes the answer without moving the marks after a <" do
    marked = answer_with_citation_marks("<b>返品</b>できます。", [ { "end_index" => 9 }, { "end_index" => 14 } ])

    assert_includes marked, "&lt;b&gt;返品&lt;/b&gt;<sup"
    assert_equal "<b>返品</b>[1]できます。[2]", text_of(marked)
    assert_empty Nokogiri::HTML5.fragment(marked).css("b")
  end

  private

  def text_of(html)
    Nokogiri::HTML5.fragment(html).text
  end
end
