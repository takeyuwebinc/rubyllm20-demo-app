# Assertions on where parts of a screen come, by the order of the elements
# that mark them in the document. The order in the document is the order the
# parts are read in; it does not depend on the classes that lay them out.
module DocumentOrderAssertions
  def assert_before(earlier, later)
    first = css_select(earlier).first
    second = css_select(later).first
    assert first, "Expected an element matching #{earlier}"
    assert second, "Expected an element matching #{later}"
    assert_equal(-1, first <=> second, "Expected #{earlier} to come before #{later}")
  end
end
