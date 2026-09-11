require "test_helper"

# Every callback used to build its own Faraday connection, which builds its own
# NetHttpPersistent adapter, which builds its own Net::HTTP::Persistent pool. So
# `pool_size: 5` and `idle_timeout = 5` were never once exercised: the pool was
# discarded with the service object and the next callback paid TCP + TLS again,
# inside a budget Fluid caps at 5s for the busiest callbacks.
#
# Connections::Fluid.connection existed for exactly this ("Shared, cached
# connection ... no TLS handshakes, lower latency") and had no callers at all.
describe "Connections::Fluid.connection" do
  before do
    Tasks::Settings.create_defaults
    Connections::Fluid.reset_connections!
  end

  after { Connections::Fluid.reset_connections! }

  it "hands back the same connection so its pool survives the request" do
    first = Connections::Fluid.connection(profile: :callback)
    second = Connections::Fluid.connection(profile: :callback)

    assert_same first, second
  end

  it "keeps the profiles apart" do
    refute_same Connections::Fluid.connection(profile: :callback),
                Connections::Fluid.connection(profile: :job)
  end

  # Net::HTTP::Persistent is not safe to share across threads here: the adapter
  # writes the per-request timeout onto the persistent object and applies it at
  # checkout, so two Puma threads would read each other's settings. One pool per
  # thread keeps the reuse and drops the race — Puma's threads are long-lived,
  # which is what makes the pool worth having.
  it "gives each thread its own pool" do
    mine = Connections::Fluid.connection(profile: :callback)
    theirs = Thread.new { Connections::Fluid.connection(profile: :callback) }.value

    refute_same mine, theirs
  end
end

describe "FluidClient sharing one connection" do
  before do
    Tasks::Settings.create_defaults
    Connections::Fluid.reset_connections!
  end

  after { Connections::Fluid.reset_connections! }

  class RecordingConnection
    Response = Struct.new(:status, :body)
    attr_reader :auth_headers

    def initialize = @auth_headers = []

    def get(_path, _params = nil, headers = nil)
      @auth_headers << headers&.dig("Authorization")
      Response.new(200, {})
    end
  end

  # The token cannot live on a shared connection: it is per company, and the
  # droplet serves many. Baking it in would hand one company's cart to another
  # company's credentials.
  it "sends each company's own token on its own request" do
    shared = RecordingConnection.new

    Connections::Fluid.stub(:connection, ->(**) { shared }) do
      FluidClient.new("token-acme", profile: :callback).get("/api/x")
      FluidClient.new("token-other", profile: :callback).get("/api/x")
    end

    assert_equal [ "Bearer token-acme", "Bearer token-other" ], shared.auth_headers
  end
end
