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

  describe "#promote_member_type_on_first_subscription?" do
    it "is false when the setting is absent" do
      setting = companies(:acme).build_integration_setting(settings: {})

      refute setting.promote_member_type_on_first_subscription?
    end

    it "is true when the toggle is on" do
      setting = companies(:acme).build_integration_setting(
        settings: { "promote_member_type_on_first_subscription" => "1" }
      )

      assert setting.promote_member_type_on_first_subscription?
    end

    it "is false when the toggle is explicitly off" do
      setting = companies(:acme).build_integration_setting(
        settings: { "promote_member_type_on_first_subscription" => "0" }
      )

      refute setting.promote_member_type_on_first_subscription?
    end
  end

  describe "#preferred_source" do
    it "defaults to \"exigo\" when the setting is absent" do
      setting = companies(:acme).build_integration_setting(settings: {})

      _(setting.preferred_source).must_equal "exigo"
    end

    it "returns the configured source when set" do
      setting = companies(:acme).build_integration_setting(
        settings: { "preferred_source" => "fluid_member_type" }
      )

      _(setting.preferred_source).must_equal "fluid_member_type"
    end
  end

  describe "#preferred_from_fluid_member_type?" do
    it "is false when the setting is absent" do
      setting = companies(:acme).build_integration_setting(settings: {})

      refute setting.preferred_from_fluid_member_type?
    end

    it "is true only for the fluid_member_type source" do
      setting = companies(:acme).build_integration_setting(
        settings: { "preferred_source" => "fluid_member_type" }
      )

      assert setting.preferred_from_fluid_member_type?
    end

    # An unrecognized source must not quietly stop a company reading Exigo.
    it "is false for an unrecognized source" do
      setting = companies(:acme).build_integration_setting(
        settings: { "preferred_source" => "fluid" }
      )

      refute setting.preferred_from_fluid_member_type?
    end
  end

  describe "#exigo_preferred_signal" do
    it "defaults to \"autoships\" when the setting is absent" do
      setting = companies(:acme).build_integration_setting(settings: {})

      _(setting.exigo_preferred_signal).must_equal "autoships"
    end

    it "returns the configured signal when set" do
      setting = companies(:acme).build_integration_setting(
        settings: { "exigo_preferred_signal" => "customer_type" }
      )

      _(setting.exigo_preferred_signal).must_equal "customer_type"
    end
  end

  describe "#exigo_preferred_by_customer_type?" do
    it "is false when the setting is absent" do
      setting = companies(:acme).build_integration_setting(settings: {})

      refute setting.exigo_preferred_by_customer_type?
    end

    it "is true only for the customer_type signal" do
      setting = companies(:acme).build_integration_setting(
        settings: { "exigo_preferred_signal" => "customer_type" }
      )

      assert setting.exigo_preferred_by_customer_type?
    end

    # A typo in the JSONB must not silently flip a company off today's behavior.
    it "is false for an unrecognized signal" do
      setting = companies(:acme).build_integration_setting(
        settings: { "exigo_preferred_signal" => "customertype" }
      )

      refute setting.exigo_preferred_by_customer_type?
    end
  end

  describe "#subscription_volume_source" do
    it "defaults to \"price_ratio\" when the setting is absent" do
      setting = companies(:acme).build_integration_setting(settings: {})

      _(setting.subscription_volume_source).must_equal "price_ratio"
    end

    it "returns the configured source when set" do
      setting = companies(:acme).build_integration_setting(
        settings: { "subscription_volume_source" => "preferred_customer" }
      )

      _(setting.subscription_volume_source).must_equal "preferred_customer"
    end
  end
end
