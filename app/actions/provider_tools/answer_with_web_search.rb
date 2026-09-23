module ProviderTools
  # Answers a question with what the model finds on the web, and lists the
  # searches it ran and the sources it cited.
  #
  # The search runs on the provider's side, within the one request: the app
  # asks once and gets back the answer together with the searches and the
  # citations. There is no search tool of the app's own to write or call.
  class AnswerWithWebSearch < ApplicationAction
    INSTRUCTIONS = <<~TEXT
      あなたは、家電と日用品を扱う架空の EC サイトのサポートデスクの担当者です。
      質問に答える前に、最新の情報を Web 検索で確かめてください。
      日本語で簡潔に回答し、根拠にした情報の出典を示してください。
    TEXT

    def initialize(question:, model:)
      @question = question
      @model = model
    end

    def perform
      chat = RubyLLM.chat(model: @model)
                    .with_instructions(INSTRUCTIONS)
                    .with_provider_tools(:web_search)
      response = chat.ask(@question)

      {
        "answer" => response.content,
        "model" => response.model,
        "searches" => response.server_tool_calls.map { |call| search(call) },
        "citations" => response.citations.map { |citation| source(citation) }
      }
    end

    private

    # OpenAI reports each step as a web_search_call item, and RubyLLM keeps the
    # item's action as the call's input: a search with its queries, a page it
    # opened, or a search within a page. The action's keys are strings in a
    # response and symbols once RubyLLM rebuilds the call from a Hash, as it
    # does for a recorded chat.
    #
    # The action is read rather than the call's raw item, because it is the
    # value RubyLLM normalizes across providers; the raw item follows OpenAI's
    # own shape.
    def search(call)
      action = call.input.is_a?(Hash) ? call.input.transform_keys(&:to_s) : {}
      {
        "type" => call.type,
        "action" => action["type"],
        # OpenAI documents queries, but its items have also carried a single
        # query; either way the searched words are kept.
        "queries" => Array(action["queries"]).presence || Array(action["query"]),
        "url" => action["url"]
      }
    end

    # Each citation points to the span of the answer (text, start_index,
    # end_index) that the page at url supports.
    def source(citation)
      {
        "url" => citation.url,
        "title" => citation.title,
        "text" => citation.text,
        "start_index" => citation.start_index,
        "end_index" => citation.end_index
      }
    end
  end
end
