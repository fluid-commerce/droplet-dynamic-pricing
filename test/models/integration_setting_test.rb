require "test_helper"

describe IntegrationSetting do
  fixtures(:companies)

  describe "#adjust_volumes_for_subscription?" do
    it "defaults to false when the setting is absent" do
      setting = companies(:acme).build_integration_setting(settings: {})

      _(setting.adjust_volumes_for_subscription?).must_equal false
    end

    it "is true when the setting is the boolean true" do
      setting = companies(:acme).build_integration_setting(
        settings: { "adjust_volumes_for_subscription" => true }
      )

      _(setting.adjust_volumes_for_subscription?).must_equal true
    end

    it "casts the string \"true\" to true" do
      setting = companies(:acme).build_integration_setting(
        settings: { "adjust_volumes_for_subscription" => "true" }
      )

      _(setting.adjust_volumes_for_subscription?).must_equal true
    end

    it "is false when the setting is the boolean false" do
      setting = companies(:acme).build_integration_setting(
        settings: { "adjust_volumes_for_subscription" => false }
      )

      _(setting.adjust_volumes_for_subscription?).must_equal false
    end
  end
end
