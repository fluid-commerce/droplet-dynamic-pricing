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

  test "set_customer_preferred does not touch the member type by default" do
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-1", "member_type_slug" => "customer" })
    stub_customer_type_writes(service, members: members)

    service.send(:set_customer_preferred, 77)

    assert_empty members.updates, "promotion is opt-in"
  end

  test "set_customer_preferred promotes the member type when the toggle is on" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-1", "member_type_slug" => "customer" })
    stub_customer_type_writes(service, members: members)

    service.send(:set_customer_preferred, 77)

    assert_equal [ { legacy_customer_id: 77 } ], members.lookups
    assert_equal [ %w[m-1 preferred] ], members.updates
  end

  test "promotion is idempotent when the member is already preferred" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-1", "member_type_slug" => "preferred" })
    stub_customer_type_writes(service, members: members)

    service.send(:set_customer_preferred, 77)

    assert_empty members.updates, "already preferred, nothing to write"
  end

  # set_customer_type returns early when the metafield already says preferred.
  # The promotion must not sit behind that guard: seeding member types through
  # the droplet is exactly the case where the metafield is already right and
  # the member type is not.
  test "promotion still fires when the metafield already says preferred" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-1", "member_type_slug" => "customer" })
    stub_customer_type_writes(service, members: members, current_type: "preferred_customer")

    service.send(:set_customer_preferred, 77)

    assert_equal [ %w[m-1 preferred] ], members.updates
  end

  # A member that cannot be resolved or written must not take the webhook down —
  # the metafield write is the path that still has to happen.
  test "a failed promotion does not break the rest of set_customer_preferred" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(raises: FluidClient::ResourceNotFoundError)
    written = stub_customer_type_writes(service, members: members)

    service.send(:set_customer_preferred, 77)

    assert_equal [ [ 77, "preferred_customer" ] ], written
  end

  test "should_remain_preferred? is true outright when preferred is permanent" do
    promotion_setting_for(@company)
    service = build_service
    asked = []
    service.define_singleton_method(:has_other_active_subscriptions?) { |_id, _ex| asked << :subscriptions; false }
    service.define_singleton_method(:customer_external_id) { |_id| asked << :exigo; nil }

    assert service.send(:should_remain_preferred?, 77, 1)
    assert_empty asked, "no live signal can change an answer that is permanent"
  end

  test "should_remain_preferred? still consults the live signals by default" do
    service = build_service
    asked = []
    service.define_singleton_method(:has_other_active_subscriptions?) { |_id, _ex| asked << :subscriptions; false }
    service.define_singleton_method(:customer_external_id) { |_id| "ext-77" }
    service.define_singleton_method(:has_exigo_autoship?) { |_ext| asked << :exigo; false }

    refute service.send(:should_remain_preferred?, 77, 1)
    assert_equal %i[subscriptions exigo], asked
  end

private

  def build_service
    Webhooks::BaseService.new({ "subscription" => { "id" => 1 } }, @company)
  end

  def promotion_setting_for(company)
    company.create_integration_setting!(
      settings: { "promote_member_type_on_first_subscription" => "1" }
    )
  end

  # Silences everything set_customer_type does downstream and returns the list
  # of (customer_id, type) pairs it tried to write.
  def stub_customer_type_writes(service, members:, current_type: nil)
    written = []
    service.define_singleton_method(:fluid_members) { members }
    service.define_singleton_method(:customer_external_id) { |_id| "ext-77" }
    service.define_singleton_method(:get_current_customer_type) { |_id| current_type }
    service.define_singleton_method(:update_customer_type) { |id, type| written << [ id, type ] }
    service.define_singleton_method(:update_customer_metadata) { |_id, _type| nil }
    service.define_singleton_method(:update_exigo_customer_type) { |_ext, _type| nil }
    service.define_singleton_method(:log_transaction) { |**_args| nil }
    written
  end
end

# Records member lookups and member-type writes separately, so idempotence is
# assertable apart from resolution.
class FakePromotionMembersResource
  attr_reader :lookups, :updates

  def initialize(member: nil, raises: nil)
    @member = member
    @raises = raises
    @lookups = []
    @updates = []
  end

  def find_by(**identifier)
    @lookups << identifier
    raise @raises, "boom" if @raises

    { "member" => @member }
  end

  def update_member_type(member_id, slug)
    @updates << [ member_id, slug ]
    { "member" => { "id" => member_id } }
  end
end
