require "test_helper"

describe "Callback timeout budget" do
  BASE = "https://droplet.example.com"

  before do
    Tasks::Settings.create_defaults
    Callback.delete_all
    Setting.find_by(name: "host_server").update!(values: { "base_url" => BASE })
  end

  # Fluid abandons a sync callback at the registration's timeout_in_seconds.
  # The droplet's own worst case for ONE Fluid call is the retry ladder in
  # Connections::Fluid — 2 attempts at 5s plus 0.25s between them — so a
  # registration below that cannot be met no matter how fast the droplet is.
  it "derives the floor from the callback retry ladder" do
    expected = ((Connections::Fluid::CALLBACK_RETRIES + 1) * Connections::Fluid::CALLBACK_TIMEOUT) +
               (Connections::Fluid::CALLBACK_RETRIES * Connections::Fluid::CALLBACK_RETRY_INTERVAL)

    _(Callback::MINIMUM_TIMEOUT_IN_SECONDS).must_be :>=, expected.ceil
  end

  # TM3 was registered at 5s while the ladder can spend 10.25s on a single
  # call, so one slow Fluid read timed the whole callback out — 8543ms on a
  # cart_item_added that completed fine.
  it "defaults to a timeout the droplet can actually meet" do
    _(Callback::DEFAULT_TIMEOUT_IN_SECONDS).must_be :>=, Callback::MINIMUM_TIMEOUT_IN_SECONDS
  end

  it "matches the registration default the Fluid client already used" do
    _(Callback::DEFAULT_TIMEOUT_IN_SECONDS).must_equal 20
  end

  it "creates served rows with the meetable default" do
    Callback.ensure_served!

    _(Callback.pluck(:timeout_in_seconds).uniq).must_equal [ Callback::DEFAULT_TIMEOUT_IN_SECONDS ]
  end

  # The reason this overrules an operator value, unlike #92's rule for URLs and
  # the active flag: a timeout under the floor is not a tuning, it is a budget
  # the droplet cannot satisfy by construction.
  it "raises a timeout that is below the floor" do
    Callback.create!(
      name: "cart_item_added",
      description: "registered at the value that was timing out",
      url: "#{BASE}/callbacks/cart_item_added",
      timeout_in_seconds: 5,
      active: true
    )

    Callback.ensure_served!

    _(Callback.find_by(name: "cart_item_added").timeout_in_seconds)
      .must_equal Callback::DEFAULT_TIMEOUT_IN_SECONDS
  end

  # The floor is derived, so tuning the ladder up can push it past the 20s
  # ceiling Fluid's own validation allows — and then no valid timeout exists.
  # That is a misconfiguration of the HTTP budget, not of the registration, and
  # it has to be loud instead of silently writing a value that cannot work.
  it "reports when the HTTP budget cannot fit any allowed timeout" do
    messages = []
    logger = Object.new
    logger.define_singleton_method(:error) { |msg| messages << msg.to_s }
    logger.define_singleton_method(:method_missing) { |*_a| nil }
    logger.define_singleton_method(:respond_to_missing?) { |*_a| true }

    original = Rails.logger
    Rails.logger = logger
    begin
      Callback.stub_const_minimum(999) { Callback.ensure_served! }
    ensure
      Rails.logger = original
    end

    _(messages.join).must_match(/cannot fit/i)
  end

  it "still writes a saveable timeout when the budget does not fit" do
    Callback.stub_const_minimum(999) { Callback.ensure_served! }

    Callback.find_each do |callback|
      assert callback.valid?, "#{callback.name}: #{callback.errors.full_messages}"
    end
  end

  it "leaves a tuned timeout above the floor alone" do
    Callback.create!(
      name: "cart_item_updated",
      description: "deliberately tightened but satisfiable",
      url: "#{BASE}/callbacks/cart_item_updated",
      timeout_in_seconds: 15,
      active: true
    )

    Callback.ensure_served!

    _(Callback.find_by(name: "cart_item_updated").timeout_in_seconds).must_equal 15
  end
end
