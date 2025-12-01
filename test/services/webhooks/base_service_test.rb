require "test_helper"

class Webhooks::BaseServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
  end

  test "initializes with webhook_params and company" do
    webhook_params = { "subscription" => { "id" => 123 } }
    service = Webhooks::BaseService.new(webhook_params, @company)
    _(service.instance_variable_get(:@webhook_params)).must_equal webhook_params
    _(service.instance_variable_get(:@company)).must_equal @company
  end
end
