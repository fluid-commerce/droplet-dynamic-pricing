require "test_helper"

# Characterization harness for the preferred-pricing decision (CURRENT-3361).
#
# This is NOT a spec of what pricing should do. It is a record of what it DOES
# today, across the whole input space the decision depends on. Its job is to make
# the next change reviewable: the predicate work has to stop trusting the stale
# customer_type metafield, and unlike the settled-cart guard that change can take
# a discount away from a live customer. Committing this golden file first means
# that PR shows up as a diff of decisions, where every moved line is either the
# leak we meant to close or a regression — instead of an unbounded "did anything
# else change?".
#
# Why a matrix and not more unit tests: the suite's hand-written doubles drift
# from reality silently. StubFluidClient never defined `subscriptions`, so two
# verify_email tests spent months exercising the lookup-failure path while
# claiming to exercise "customer has no subscriptions". This drives the REAL
# service classes over every combination instead.
#
# Deliberately out of scope: settled carts. Every row runs on a live cart
# (state=start, trigger=checkout_entry) because the settled-cart guard is already
# covered by its own tests, and folding it in would double the matrix to record
# a column of "writes nothing".
#
# Regenerate after an intentional change:
#   REGENERATE_GOLDEN=1 bin/rails test test/services/callbacks/pricing_decision_matrix_test.rb
class Callbacks::PricingDecisionMatrixTest < ActiveSupport::TestCase
  fixtures(:companies)

  GOLDEN = Rails.root.join("test/fixtures/files/pricing_decision_matrix.txt")

  # The axes the preferred/not-preferred decision actually reads.
  STAMPS      = [ nil, "preferred_customer", "wholesale" ].freeze
  BOOLS       = [ false, true ].freeze
  METAFIELDS  = [ nil, "preferred_customer" ].freeze
  EXIGO       = %i[ off autoship ].freeze

  SERVICES = %w[
    cart_item_added
    cart_item_updated
    customer_logged_in
    cart_customer_attached
    cart_customer_detached
    subscription_added
    subscription_removed
    verify_email_success
    cart_email_on_create
    cart_country_changed
  ].freeze

  EMAIL       = "shopper@example.com".freeze
  CUSTOMER_ID = 888
  VARIANT_ID  = 10
  TOKEN       = "ct_matrix".freeze

  def setup
    @company = companies(:acme)
    # Volumes on, so volume decisions are recorded too rather than silently absent.
    @company.create_integration_setting!(
      settings: { "adjust_volumes_for_subscription" => true }
    )
  end

  test "preferred-pricing decisions match the recorded golden master" do
    actual = render_matrix

    if ENV["REGENERATE_GOLDEN"]
      File.write(GOLDEN, actual)
      skip "golden regenerated at #{GOLDEN}"
    end

    assert GOLDEN.exist?, "missing golden file; run with REGENERATE_GOLDEN=1"
    assert_equal File.read(GOLDEN), actual, failure_message(File.read(GOLDEN), actual)
  end

private

  def failure_message(expected, actual)
    exp, act = expected.split("\n"), actual.split("\n")
    diffs = (0...[ exp.size, act.size ].max).filter_map do |i|
      next if exp[i] == act[i]
      "  - #{exp[i].inspect}\n  + #{act[i].inspect}"
    end
    "#{diffs.size} decision(s) changed. First 15:\n#{diffs.first(15).join("\n")}\n\n" \
      "Every line here is a pricing decision that moved. Justify each one, then " \
      "regenerate with REGENERATE_GOLDEN=1."
  end

  def render_matrix
    rows = []
    combos.each do |combo|
      SERVICES.each { |service| rows << row_for(service, combo) }
    end
    rows.join("\n") + "\n"
  end

  def combos
    STAMPS.product(BOOLS, BOOLS, METAFIELDS, BOOLS, EXIGO).map do |axes|
      stamp, sub_line, logged_in, metafield, active_sub, exigo = axes
      {
        stamp: stamp, sub_line: sub_line, logged_in: logged_in,
        metafield: metafield, active_sub: active_sub, exigo: exigo,
      }
    end
  end

  def row_for(service, combo)
    recorder = Recorder.new
    result = run_service(service, combo, recorder)
    "#{service.ljust(23)} #{key(combo)} -> #{recorder.summary} #{result_summary(result)}"
  end

  def key(combo)
    format(
      "stamp=%-18s sub_line=%-5s logged_in=%-5s metafield=%-18s active_sub=%-5s exigo=%-8s",
      combo[:stamp].inspect, combo[:sub_line], combo[:logged_in],
      combo[:metafield].inspect, combo[:active_sub], combo[:exigo]
    )
  end

  def result_summary(result)
    return "result=RAISED" if result == :raised

    parts = [ "success=#{result[:success]}" ]
    parts << "meta=#{result.dig(:metadata, 'price_type').inspect}" if result[:metadata]
    parts << "err=#{result[:error]}" if result[:error]
    "result=[#{parts.join(' ')}]"
  end

  def run_service(service, combo, recorder)
    klass = "Callbacks::#{service.camelize}Service".constantize
    svc = klass.new(params_for(service, combo))
    client = FakeClient.new(recorder: recorder, combo: combo)
    svc.define_singleton_method(:fluid_client) { client }
    svc.define_singleton_method(:exigo_integration_enabled?) { combo[:exigo] != :off }
    svc.define_singleton_method(:exigo_client) do
      ExigoStub.new(combo[:exigo] == :autoship)
    end

    events_before = CartPricingEvent.count
    result = svc.call
    recorder.note_event!(CartPricingEvent.order(:id).last) if CartPricingEvent.count > events_before
    result
  rescue StandardError => e
    recorder.note_raise!(e)
    :raised
  end

  # --- payload construction -------------------------------------------------

  def params_for(service, combo)
    base = { cart: cart_for(combo), context: { "trigger_source" => "checkout_entry" } }
    case service
    when "cart_item_added", "cart_item_updated"
      base.merge(cart_item: cart_for(combo)["items"].first)
    when "cart_customer_attached"
      base.merge(customer: { "id" => CUSTOMER_ID, "email" => EMAIL })
    else
      base
    end.with_indifferent_access
  end

  def cart_for(combo)
    {
      "id" => 731043,
      "cart_token" => TOKEN,
      # A live cart: the settled-cart guard has its own tests.
      "state" => "start",
      "country_code" => "US",
      "email" => EMAIL,
      "customer_id" => (CUSTOMER_ID if combo[:logged_in]),
      "metadata" => { "price_type" => combo[:stamp] },
      "company" => { "id" => @company.fluid_company_id },
      "items" => [
        {
          "id" => 1031966,
          "variant_id" => VARIANT_ID,
          "price" => "61.0",
          "subscription_price" => "55.0",
          "product" => { "price" => "61.0" },
          "quantity" => 1,
          "subscription" => combo[:sub_line],
          # price_locked so cart_country_changed has something to repair.
          "metadata" => { "price_locked" => true },
        },
      ],
    }
  end

  # --- fakes ----------------------------------------------------------------

  class Recorder
    def initialize
      @writes = []
      @event = nil
      @raised = nil
    end

    def record(kind, payload) = @writes << "#{kind}(#{payload})"
    def note_event!(event)
      @event = event && "#{event.event_type}/#{event.preferred_pricing_applied}"
    end
    def note_raise!(error) = @raised = error.class.name

    def summary
      parts = [ "writes=[#{@writes.join(' ')}]" ]
      parts << "event=#{@event}" if @event
      parts << "raised=#{@raised}" if @raised
      parts.join(" ")
    end
  end

  class ExigoStub
    def initialize(autoship) = @autoship = autoship
    def customer_has_active_autoship_by_email?(_email) = @autoship
  end

  class FakeCarts
    def initialize(recorder) = @recorder = recorder

    def update_items_prices(_token, items)
      @recorder.record("prices", items.map { |i| i["price"] }.join(","))
      { "success" => true }
    end

    def append_metadata(_token, metadata)
      @recorder.record("meta", metadata["price_type"].inspect)
      { "success" => true }
    end

    def update_item_volumes(_token, _item_id, volumes)
      @recorder.record("vol", "cv=#{volumes['cv']},qv=#{volumes['qv']}")
      { "success" => true }
    end
  end

  class FakeMetafields
    def initialize(recorder:, value:)
      @recorder = recorder
      @value = value
    end

    def get_by_key(resource_type:, resource_id:, key:, **)
      return nil if @value.nil?
      { "key" => key.to_s, "value" => { "customer_type" => @value } }
    end

    def ensure_definition(**) = { "success" => true }

    def update(**opts)
      @recorder.record("pcc", opts[:value]["customer_type"])
      { "success" => true }
    end

    def create(**opts)
      @recorder.record("pcc_create", opts[:value]["customer_type"])
      { "success" => true }
    end
  end

  class FakeSubscriptions
    def initialize(active) = @active = active

    def get_by_customer(_customer_id, **)
      { "subscriptions" => @active ? [ { "id" => 1, "status" => "active" } ] : [] }
    end
  end

  class FakeCustomers
    def get(**) = { "customers" => [ { "id" => CUSTOMER_ID, "email" => EMAIL } ] }
  end

  class FakeVariants
    ROWS = [ {
      "country_code" => "US", "cv" => 100, "qv" => 50,
      "price" => "61.0", "subscription_price" => "55.0",
    } ].freeze

    def get(variant_id) = { "variant" => { "id" => variant_id, "variant_countries" => ROWS } }
  end

  class FakeClient
    def initialize(recorder:, combo:)
      @carts = FakeCarts.new(recorder)
      @metafields = FakeMetafields.new(recorder: recorder, value: combo[:metafield])
      @subscriptions = FakeSubscriptions.new(combo[:active_sub])
      @customers = FakeCustomers.new
      @variants = FakeVariants.new
    end

    def carts = @carts
    def metafields = @metafields
    def subscriptions = @subscriptions
    def customers = @customers
    def variants = @variants
    def blank? = false
  end
end
