require "test_helper"

class CallbackSyncServiceTest < ActiveSupport::TestCase
  def setup
    @service = CallbackSyncService.new
    @mock_client = Minitest::Mock.new
    @service.instance_variable_set(:@client, @mock_client)
    ::Callback.destroy_all
  end

  test "syncs callbacks successfully" do
    mock_definitions = {
      "definitions" => [
        {
          "name" => "test_callback",
          "description" => "Test callback description",
        },
      ],
    }

    @mock_client.expect :callback_definitions, mock_callback_definitions(mock_definitions)

    result = @service.sync

    assert result[:success]
    assert_equal "Successfully synced 1 callbacks", result[:message]
    assert_equal 1, ::Callback.count
    assert_equal "test_callback", ::Callback.first.name
    assert_not ::Callback.first.active
  end

  test "syncs real callback definitions" do
    mock_definitions = {
      "definitions" => [
        {
          "name" => "apply_subscription_order_discount",
          "description" => "Apply discounts to subscription orders",
        },
        {
          "name" => "redirect_cart_payment",
          "description" => "Get the redirect_url for a Payment Droplet",
        },
      ],
      "meta" => {
        "request_id" => "ae9c88f3-c2a5-4b4f-b0c4-b287910729ff",
        "timestamp" => "2025-07-29T20:52:09Z",
      },
    }

    @mock_client.expect :callback_definitions, mock_callback_definitions(mock_definitions)

    result = @service.sync

    assert result[:success]
    assert_equal "Successfully synced 2 callbacks", result[:message]
    assert_equal 2, ::Callback.count

    discount_callback = ::Callback.find_by(name: "apply_subscription_order_discount")
    assert discount_callback
    assert_equal "Apply discounts to subscription orders", discount_callback.description
    assert_not discount_callback.active

    payment_callback = ::Callback.find_by(name: "redirect_cart_payment")
    assert payment_callback
    assert_equal "Get the redirect_url for a Payment Droplet", payment_callback.description
    assert_not payment_callback.active
  end

  test "updates existing callbacks" do
    existing_callback = ::Callback.create!(
      name: "test_callback",
      description: "Old description",
      url: "https://example.com/callbacks/customer_logged_in",
      timeout_in_seconds: 10,
      active: true
    )

    mock_definitions = {
      "definitions" => [
        {
          "name" => "test_callback",
          "description" => "Updated description",
        },
      ],
    }

    @mock_client.expect :callback_definitions, mock_callback_definitions(mock_definitions)

    result = @service.sync

    assert result[:success]
    existing_callback.reload
    assert_equal "Updated description", existing_callback.description
    # Was assert_not: the sync used to reassign active: false on every row it
    # touched, so importing Fluid's catalogue switched off every callback an
    # install had turned on. Only NEW rows arrive inactive now.
    assert existing_callback.active
  end

  test "handles empty definitions" do
    @mock_client.expect :callback_definitions, mock_callback_definitions({ "definitions" => [] })

    result = @service.sync

    assert_not result[:success]
    assert_equal "No callback definitions found", result[:message]
  end

  test "handles nil definitions" do
    @mock_client.expect :callback_definitions, mock_callback_definitions(nil)

    result = @service.sync

    assert_not result[:success]
    assert_equal "No callback definitions found", result[:message]
  end

  test "handles response without definitions key" do
    @mock_client.expect :callback_definitions,
mock_callback_definitions({ "meta" => { "timestamp" => "2025-07-29T20:52:09Z" } })

    result = @service.sync

    assert_not result[:success]
    assert_equal "No callback definitions found", result[:message]
  end

  test "handles client errors" do
    @mock_client.expect :callback_definitions, -> { raise "API Error" }

    result = @service.sync

    assert_not result[:success]
    assert_includes result[:message], "Sync failed: undefined method 'get' for an instance of Proc"
  end

  test "handles individual callback save errors gracefully" do
    mock_definitions = {
      "definitions" => [
        {
          "name" => "valid_callback",
          "description" => "Valid callback",
        },
        {
          "name" => "invalid_callback",
          "description" => nil, # This will cause validation error
        },
      ],
    }

    @mock_client.expect :callback_definitions, mock_callback_definitions(mock_definitions)

    result = @service.sync

    # Should still succeed overall, but only create the valid callback
    assert result[:success]
    assert_equal "Successfully synced 2 callbacks", result[:message]
    assert_equal 1, ::Callback.count
    assert_equal "valid_callback", ::Callback.first.name
  end

  test "preserves existing callback attributes not in sync" do
    existing_callback = ::Callback.create!(
      name: "test_callback",
      description: "Old description",
      url: "https://example.com/callbacks/customer_logged_in",
      timeout_in_seconds: 10,
      active: true
    )

    mock_definitions = {
      "definitions" => [
        {
          "name" => "test_callback",
          "description" => "Updated description",
        },
      ],
    }

    @mock_client.expect :callback_definitions, mock_callback_definitions(mock_definitions)

    result = @service.sync

    assert result[:success]
    existing_callback.reload
    assert_equal "Updated description", existing_callback.description
    assert_equal "https://example.com/callbacks/customer_logged_in", existing_callback.url
    assert_equal 10, existing_callback.timeout_in_seconds
    # The active flag is one of the attributes this example's name promises to
    # preserve; it used to be the one exception.
    assert existing_callback.active
  end

  test "uses fluid api key for authentication" do
    service = CallbackSyncService.new
    client = service.instance_variable_get(:@client)

    assert_equal Setting.fluid_api.api_key, client.instance_variable_get(:@auth_token)
  end

private

  def mock_callback_definitions(response)
    mock_definitions = Minitest::Mock.new
    mock_definitions.expect :get, response
    mock_definitions
  end

  test "imports a callback Fluid offers but this droplet has no row for as inactive" do
    definitions = { "definitions" => [ { "name" => "update_cart_tax", "description" => "Tax" } ] }
    @mock_client.expect(:callback_definitions, Object.new.tap { |r| r.define_singleton_method(:get) { definitions } })

    @service.sync

    refute ::Callback.find_by(name: "update_cart_tax").active,
      "a definition this droplet has no handler for must not arrive switched on"
  end
end
