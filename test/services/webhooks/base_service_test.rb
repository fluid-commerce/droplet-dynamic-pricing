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

  # STU2-3242 scopes this to customers: "whose customer type is currently
  # Customer". The first cut only guarded against ALREADY being preferred, so a
  # rep who bought a subscription was rewritten from rep to preferred — and in
  # Fluid rep is tier_level 2 against preferred's 1, so that is a demotion, not
  # a no-op. Reported from production.
  test "does not promote a rep" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-rep", "member_type_slug" => "rep" })
    stub_customer_type_writes(service, members: members)

    service.send(:set_customer_preferred, 77)

    assert_empty members.updates, "a rep must keep its member type"
  end

  # Companies can define their own member types. Anything that is not the one
  # type below preferred is left alone rather than guessed at.
  test "does not promote a member type it does not recognize" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-x", "member_type_slug" => "distributor" })
    stub_customer_type_writes(service, members: members)

    service.send(:set_customer_preferred, 77)

    assert_empty members.updates
  end

  test "promotes a member whose type is customer" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-1", "member_type_slug" => "customer" })
    stub_customer_type_writes(service, members: members)

    service.send(:set_customer_preferred, 77)

    assert_equal [ %w[m-1 preferred] ], members.updates
  end

  # A member with no type assigned is below preferred the same way customer is.
  test "promotes a member with no member type" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-none", "member_type_slug" => nil })
    stub_customer_type_writes(service, members: members)

    service.send(:set_customer_preferred, 77)

    assert_equal [ %w[m-none preferred] ], members.updates
  end

  # The promotion log said "Promoted member X to preferred" without saying from
  # what, so the production report could not be triaged from the logs at all.
  test "the promotion log records the type it promoted from" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-1", "member_type_slug" => "customer" })
    stub_customer_type_writes(service, members: members)

    line = capture_log { service.send(:set_customer_preferred, 77) }

    assert_includes line, "from=customer"
  end

  test "the skip log records the type it refused to overwrite" do
    promotion_setting_for(@company)
    service = build_service
    members = FakePromotionMembersResource.new(member: { "id" => "m-rep", "member_type_slug" => "rep" })
    stub_customer_type_writes(service, members: members)

    line = capture_log { service.send(:set_customer_preferred, 77) }

    assert_includes line, "rep"
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

  def capture_log
    lines = []
    logger = Object.new
    logger.define_singleton_method(:info) { |msg| lines << msg.to_s }
    logger.define_singleton_method(:method_missing) { |*_a| nil }
    logger.define_singleton_method(:respond_to_missing?) { |*_a| true }

    original = Rails.logger
    Rails.logger = logger
    begin
      yield
    ensure
      Rails.logger = original
    end

    lines.find { |l| l.include?("member") } || ""
  end

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
