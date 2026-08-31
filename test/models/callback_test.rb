require "test_helper"

class CallbackTest < ActiveSupport::TestCase
  def setup
    @valid_callback = {
      name: "test_callback",
      description: "Test callback description",
      url: "https://example.com/callbacks/customer_logged_in",
      timeout_in_seconds: 10,
      active: true,
    }
  end

  test "should be valid with valid attributes" do
    callback = ::Callback.new(@valid_callback)
    assert callback.valid?
  end

  test "cannot be activated with a URL this droplet does not serve" do
    callback = ::Callback.new(@valid_callback.merge(url: "https://example.com/callbacks/verify_email_success"))

    assert_not callback.valid?
    assert_includes callback.errors[:url], "is not a callback URL this droplet serves, so Fluid's dispatch would fail"
  end

  test "cannot be activated with a URL that routes outside the callbacks namespace" do
    callback = ::Callback.new(@valid_callback.merge(url: "https://example.com/webhook"))

    assert_not callback.valid?
    assert_includes callback.errors[:url], "is not a callback URL this droplet serves, so Fluid's dispatch would fail"
  end

  test "strips surrounding whitespace from the URL before validating" do
    callback = ::Callback.new(@valid_callback.merge(url: " https://example.com/callbacks/customer_logged_in "))

    assert callback.valid?
    assert_equal "https://example.com/callbacks/customer_logged_in", callback.url
  end

  test "an inactive callback may keep a URL this droplet does not serve" do
    callback = ::Callback.new(
      @valid_callback.merge(active: false, url: "https://example.com/callbacks/verify_email_success"),
    )

    assert callback.valid?
  end

  test "serves? accepts a real callback route and rejects an unrouted one" do
    assert ::Callback.serves?("https://pricing.example.com/callbacks/cart_item_added")
    assert_not ::Callback.serves?("https://pricing.example.com/callbacks/verify_email_success")
    assert_not ::Callback.serves?("not a url at all")
  end

  test "serves? accepts every callbacks route this droplet draws" do
    callback_routes = Rails.application.routes.routes.select do |route|
      route.defaults[:controller].to_s.start_with?("callbacks/") && route.verb == "POST"
    end
    callback_paths = callback_routes.map { |route| route.path.spec.to_s.sub("(.:format)", "") }

    assert_operator callback_paths.size, :>=, 9
    callback_paths.each do |path|
      assert ::Callback.serves?("https://example.com#{path}"), "expected #{path} to be served"
    end
  end

  test "serves? rejects POST routes outside the callbacks namespace" do
    assert_not ::Callback.serves?("https://example.com/webhook")
    assert_not ::Callback.serves?("https://example.com/webhook/subscription_started")
    assert_not ::Callback.serves?("https://example.com/users/sign_in")
    assert_not ::Callback.serves?("https://example.com/price_types")
    assert_not ::Callback.serves?("https://example.com/admin/callbacks/sync")
  end

  test "serves? rejects a URL without an http scheme and host" do
    assert_not ::Callback.serves?("callbacks/cart_item_added")
    assert_not ::Callback.serves?("/callbacks/cart_item_added")
    assert_not ::Callback.serves?("ftp://example.com/callbacks/cart_item_added")
    assert_not ::Callback.serves?(nil)
  end

  test "serves? rejects a host other than the configured host_server" do
    Tasks::Settings.create_defaults
    Setting.host_server.update!(values: { base_url: "https://pricing.example.com" })

    assert ::Callback.serves?("https://pricing.example.com/callbacks/cart_item_added")
    assert_not ::Callback.serves?("https://elsewhere.example.com/callbacks/cart_item_added")
  end

  test "should require name" do
    callback = ::Callback.new(@valid_callback.except(:name))
    assert_not callback.valid?
    assert_includes callback.errors[:name], "can't be blank"
  end

  test "should require unique name" do
    ::Callback.create!(@valid_callback)
    callback = ::Callback.new(@valid_callback)
    assert_not callback.valid?
    assert_includes callback.errors[:name], "has already been taken"
  end

  test "should require description" do
    callback = ::Callback.new(@valid_callback.except(:description))
    assert_not callback.valid?
    assert_includes callback.errors[:description], "can't be blank"
  end

  test "should validate timeout_in_seconds range" do
    callback = ::Callback.new(@valid_callback.merge(timeout_in_seconds: 0))
    assert_not callback.valid?
    assert_includes callback.errors[:timeout_in_seconds], "must be greater than 0"

    callback = ::Callback.new(@valid_callback.merge(timeout_in_seconds: 21))
    assert_not callback.valid?
    assert_includes callback.errors[:timeout_in_seconds], "must be less than or equal to 20"
  end

  test "should not allow active without URL" do
    callback = ::Callback.new(@valid_callback.merge(url: nil))
    assert_not callback.valid?
    assert_includes callback.errors[:active], "cannot be enabled without a URL"
  end

  test "should not allow active without timeout" do
    callback = ::Callback.new(@valid_callback.merge(timeout_in_seconds: nil))
    assert_not callback.valid?
    assert_includes callback.errors[:active], "cannot be enabled without a timeout"
  end

  test "should not allow active with empty URL" do
    callback = ::Callback.new(@valid_callback.merge(url: ""))
    assert_not callback.valid?
    assert_includes callback.errors[:active], "cannot be enabled without a URL"
  end

  test "should allow inactive without URL and timeout" do
    callback = ::Callback.new(@valid_callback.merge(active: false, url: nil, timeout_in_seconds: nil))
    assert callback.valid?
  end

  test "should allow active with URL and timeout" do
    callback = ::Callback.new(@valid_callback)
    assert callback.valid?
  end

  test "active scope should return only active callbacks" do
    active_callback = ::Callback.create!(@valid_callback)
    inactive_callback = ::Callback.create!(@valid_callback.merge(name: "inactive", active: false))

    assert_includes ::Callback.active, active_callback
    assert_not_includes ::Callback.active, inactive_callback
  end
end
