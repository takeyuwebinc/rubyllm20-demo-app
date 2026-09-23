module Demos
  # A representative scenario of a demo: one case where the feature helps,
  # runnable against a real provider once it has a handler.
  class Scenario < Data.define(
    :key, :demo_key, :name, :providers, :models, :inputs, :documents, :handler_name, :result_kind, :retryable
  )
    Input = Data.define(:name, :label, :default, :required)

    # A file the scenario hands its handler, such as a policy to cite. It is
    # kept under public/, path relative to it, so that a page can link to
    # the very file the handler is given.
    Document = Data.define(:name, :label, :path) do
      # public/ is served from the root.
      def url
        "/" + path.split("/").map { |segment| ERB::Util.url_encode(segment) }.join("/")
      end

      def absolute_path
        Rails.public_path.join(path)
      end

      def filename
        File.basename(path)
      end
    end

    # :runnable, :missing_config (with the providers that lack settings), or
    # :preparing (no handler yet).
    Availability = Data.define(:state, :missing_providers) do
      def runnable? = state == :runnable
      def missing_config? = state == :missing_config
      def preparing? = state == :preparing
    end

    # Work a handler left with a provider, read the same way whatever kind
    # of work it is. The status is :pending until the work ends, and then
    # :succeeded, :failed, or :cancelled. raw_status is the provider's own
    # word for it, and request_counts its tally, as the provider reported
    # them.
    RemoteState = Data.define(:kind, :id, :provider, :status, :raw_status, :request_counts) do
      def pending? = status == :pending
      def succeeded? = status == :succeeded
      def cancelled? = status == :cancelled
    end

    def demo
      Catalog.demo(demo_key)
    end

    def implemented?
      handler_name.present?
    end

    def handler
      handler_name&.constantize
    end

    # Tells whether the settings the providers need are present. Whether they
    # are valid, and whether Vertex AI's Application Default Credentials
    # exist, shows up only when a run fails.
    def availability(config = RubyLLM.config)
      return Availability.new(:preparing, []) unless implemented?

      missing = providers.reject { |provider| configured?(provider, config) }
      missing.any? ? Availability.new(:missing_config, missing) : Availability.new(:runnable, [])
    end

    # Values for this scenario's own inputs, taken as given. An input that
    # was not given at all gets its default.
    def input_values(given)
      inputs.to_h { |input| [ input.name, given.key?(input.name) ? given[input.name] : input.default ] }
    end

    def blank_required_inputs(values)
      inputs.select(&:required).map(&:name).select { |name| values[name].blank? }
    end

    # The handler's source file, relative to the app root. It is read on every
    # display, so the code shown is always the code that runs.
    def source_path
      path = Object.const_source_location(handler.name)&.first
      Pathname(path).relative_path_from(Rails.root).to_s if path
    end

    def source_code
      File.read(Rails.root.join(source_path))
    end

    # Calls the handler with each input, each model, and the path of each
    # document as a keyword, so the handler reads like ordinary RubyLLM code
    # with nothing of this app in it: it passes a path on without knowing
    # where the file lives.
    def perform(input)
      handler.perform(**input_values(input).symbolize_keys, **models.symbolize_keys, **document_paths)
    end

    # Records a person's decision on a tool call of the run's chat. Only a
    # handler that stops for approval has this.
    def decide(chat, tool_call_id, approved:)
      handler.decide(chat, tool_call_id, approved:)
    end

    # Continues the run's chat after a decision. Returns as perform does.
    def resume(chat)
      handler.resume(chat)
    end

    # Whether the work the handler leaves with the provider is checked on
    # by the job until it ends, as a batch is, rather than waited for.
    def checks_remote_job?
      handler.respond_to?(:check)
    end

    # Asks the handler how the work the run left with the provider is doing,
    # given the id the run keeps. Only a handler that checks on its work
    # has this.
    def check_remote_job(id)
      remote_state(handler.check(id))
    end

    # Collects the work the run left with the provider once it has ended,
    # given the id the run keeps. Returns as perform does. Only a handler
    # that checks on its work has this: one that waits for its work takes
    # the models as well, in resume_remote_job.
    def collect_remote_job(id)
      handler.resume(id)
    end

    # Reads the work a handler left with a provider, as RubyLLM returned it.
    # Each kind of RubyLLM's provider-side work tells how it is doing with
    # predicates of its own, so the reading is kept here, one per kind, and
    # the job that waits on the work reads only the RemoteState.
    def remote_state(work)
      case work
      when RubyLLM::Batch
        RemoteState.new(
          kind: "batch", id: work.id, provider: work.provider, status: batch_status(work),
          raw_status: work.raw_status, request_counts: work.request_counts
        )
      else
        raise ArgumentError, "No reading of #{work.class} as work left with a provider"
      end
    end

    # Waits for the work the handler left with the provider, given the id
    # the run keeps, with each model as a keyword as perform has them.
    # Returns as perform does. Only a handler that leaves work with the
    # provider has this.
    def resume_remote_job(id)
      handler.resume(id, **models.symbolize_keys)
    end

    private

    # OpenAI's expired batch reads as failed: it ended without finishing.
    def batch_status(batch)
      return :pending unless batch.complete?
      return :succeeded if batch.succeeded?
      return :cancelled if batch.cancelled?

      :failed
    end

    def document_paths
      documents.to_h { |document| [ document.name.to_sym, document.absolute_path ] }
    end

    # Only the names of the required settings are public in RubyLLM 2.0.0;
    # the provider's own configured? check is not. The names come from
    # RubyLLM so that this app does not keep a copy of them.
    def configured?(provider, config)
      provider_class = RubyLLM::Provider.providers[provider.to_sym]
      provider_class.present? &&
        provider_class.configuration_requirements.all? { |setting| config.public_send(setting).present? }
    end
  end
end
