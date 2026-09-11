require "test_helper"

# The callback-timing line reported one number: how long the whole callback
# took. Which of the dozen-odd outbound Fluid calls spent it was a deduction
# from silence — the 6.16s gap in the CURRENT-3248 trace had no log lines in
# it at all. This tally makes the HTTP share a read instead.
describe CallbackHttpTally do
  before { CallbackHttpTally.reset }

  it "starts empty" do
    assert_equal({ calls: 0, elapsed_ms: 0 }, CallbackHttpTally.summary)
  end

  it "counts each call and accumulates the time it spent" do
    CallbackHttpTally.record(0.150)
    CallbackHttpTally.record(0.250)

    assert_equal({ calls: 2, elapsed_ms: 400 }, CallbackHttpTally.summary)
  end
end

describe "FluidClient HTTP tally" do
  class StubConnection
    Response = Struct.new(:status, :body)

    def initialize
      @response = Response.new(200, { "ok" => true })
    end

    def get(*) = @response
    def patch(*) = @response
  end

  before { CallbackHttpTally.reset }

  def client_with_stub(profile:)
    client = FluidClient.new("token", profile: profile)
    client.instance_variable_set(:@connection, StubConnection.new)
    client
  end

  # The shopper is blocked on these, so they are the ones worth measuring.
  it "tallies a call made on the callback profile" do
    client_with_stub(profile: :callback).get("/api/anything")

    assert_equal 1, CallbackHttpTally.summary[:calls]
  end

  it "tallies writes too, not only reads" do
    client_with_stub(profile: :callback).patch("/api/anything", body: {})

    assert_equal 1, CallbackHttpTally.summary[:calls]
  end

  # Background work is not on anyone's critical path and would only pollute the
  # per-callback numbers.
  it "ignores calls made on the default profile" do
    client_with_stub(profile: :job).get("/api/anything")

    assert_equal 0, CallbackHttpTally.summary[:calls]
  end
end
