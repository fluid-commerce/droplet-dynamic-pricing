class Callbacks::BaseService
  PREFERRED_CUSTOMER_TYPE = "preferred_customer"

  def initialize(callback_params)
    @callback_params = callback_params
  end

  def self.call(callback_params)
    new(callback_params).call
  end

  def call
    raise NotImplementedError, "Subclasses must implement call method"
  end

private

  attr_reader :callback_params

  def cart
    @cart ||= callback_params[:cart]
  end

  def customer_email
    @customer_email ||= cart&.dig("email")
  end

  def cart_customer_id
    @cart_customer_id ||= cart&.dig("customer_id")
  end

  def customer_logged_in?
    cart_customer_id.present?
  end

  def cart_token
    @cart_token ||= cart&.dig("cart_token")
  end

  def cart_items
    @cart_items ||= cart&.dig("items") || []
  end

  # BP enrollment carts are priced by the yoli-promos droplet (wholesale), which
  # takes precedence. Dynamic pricing must yield on those carts to avoid both
  # droplets fighting over the same items (STU2-2377).
  #
  # Only companies that actually run yoli-promos (i.e. Yoli) should yield — for
  # everyone else, yielding would strip preferred-customer pricing from
  # enrollment carts. So the skip is gated behind a per-company toggle
  # (Integration Settings), off by default.
  def yield_to_enrollment_wholesale?
    enrollment_cart? && company_yields_to_enrollment_wholesale?
  end

  def enrollment_cart?
    cart&.dig("type") == "enrollment" ||
      cart_items.any? { |item| item["enrollment_pack_id"].present? }
  end

  def company_yields_to_enrollment_wholesale?
    company = find_company
    return false if company.blank?

    company.integration_setting&.yield_to_enrollment_wholesale? || false
  rescue CallbackError
    false
  end

  def result_success
    { success: true }
  end

  def handle_callback_error(error)
    service_name = self.class.name.demodulize
    Rails.logger.error "[#{service_name}] #{error.message}"

    { success: false, message: error.message }
  end

  def fluid_client
    @fluid_client ||= initialize_fluid_client
  end

  def initialize_fluid_client
    company = find_company
    raise CallbackError, "Company is blank" if company.blank?

    FluidClient.new(company.authentication_token)
  end

  def find_company
    # Use the `cart` accessor (reads callback_params[:cart]) rather than
    # callback_params.dig("cart", ...) so this works whether the cart key is a
    # symbol (plain hash, e.g. in tests) or a string (HashWithIndifferentAccess
    # from the controller in production).
    company_data = cart&.dig("company")
    raise CallbackError, "Company data is blank" if company_data.blank?

    # Memoized: a single callback resolves the company several times
    # (initialize_fluid_client, exigo_integration_enabled?,
    # adjust_volumes_for_subscription?, log_cart_pricing_event) and it is stable
    # for the life of the request.
    @company ||= Company.find_by(fluid_company_id: company_data["id"])
  end

  def update_cart_metadata(metadata)
    fluid_client.carts.append_metadata(cart_token, metadata)
    Rails.logger.info "[DynamicPricing] Stamped cart #{cart_token} metadata: #{metadata.inspect}"
  rescue CallbackError => e
    handle_callback_error(e)
  end
  # NOTE: transient Fluid failures (FluidClient::Error/timeouts) intentionally
  # propagate to the service's outer rescue so the callback returns a non-success
  # result (HTTP 4xx) and Fluid retries; the outer rescue reports them to Sentry.

  # Whether this cart's company has opted into adjusting volumes (QV/CV) to
  # reflect subscription pricing (STU2-2526). Off by default so the shared
  # droplet doesn't touch volumes for Yoli (which manages them via yoli-promos).
  def adjust_volumes_for_subscription?
    company = find_company
    return false if company.blank?

    company.integration_setting&.adjust_volumes_for_subscription? || false
  rescue CallbackError
    false
  end

  # The company's configured source for subscription CV/QV: "price_ratio"
  # (default, retail volumes scaled by the subscription discount) or
  # "preferred_customer" (the catalog's pc_cv/pc_qv, written directly). Falls
  # back to the default when the company or setting can't be resolved.
  def subscription_volume_source
    company = find_company
    return IntegrationSetting::DEFAULT_SUBSCRIPTION_VOLUME_SOURCE if company.blank?

    company.integration_setting&.subscription_volume_source ||
      IntegrationSetting::DEFAULT_SUBSCRIPTION_VOLUME_SOURCE
  rescue CallbackError
    IntegrationSetting::DEFAULT_SUBSCRIPTION_VOLUME_SOURCE
  end

  # Adjusts each item's per-unit QV/CV to reflect subscription pricing,
  # proportionally to the variant's subscription discount (mirrors Fluid core's
  # volume-discount engine). No-op unless the company opted in.
  #
  #   mode: :subscription -> scale volumes by subscription_price / retail price
  #   mode: :regular      -> restore the variant's base volumes
  #
  # The ratio and the base CV/QV both come from the variant's variant_country
  # (the authoritative source that carries price, subscription_price, cv and qv
  # together) — NOT the cart item's price fields, which can be inconsistent.
  # Each item needs an "id" and a variant id (flat "variant_id" or nested
  # "variant" => { "id" }). Items without a resolvable variant are skipped
  # rather than zeroed out, so we never wipe real commission values on Fluid.
  def update_cart_items_volumes(items, mode: :subscription)
    return unless adjust_volumes_for_subscription?

    # Constant for the whole request — resolve once, not per item.
    source = subscription_volume_source

    Array(items).each do |item|
      item_id = item["id"]
      variant_id = item["variant_id"] || item.dig("variant", "id")
      next if item_id.blank? || variant_id.blank?

      base = variant_base_volumes(variant_id)
      next if base.nil?

      volumes = cart_item_volumes(base, mode, item["quantity"], source)

      fluid_client.carts.update_item_volumes(cart_token, item_id, volumes)
    end
  rescue StandardError => e
    report_exception(e, message: "Failed to update cart item volumes for cart #{cart_token}: #{e.message}")
  end

  # Per-unit CV/QV to write for a cart item, honoring the company's
  # subscription_volume_source. The default "price_ratio" source scales the
  # variant's retail volumes by the subscription discount. The
  # "preferred_customer" source instead writes the catalog's preferred-customer
  # volumes (pc_cv/pc_qv) directly, with no ratio scaling. When the catalog is
  # missing pc_cv/pc_qv, it writes the variant's RETAIL volumes as-is (and logs)
  # rather than the price_ratio result, so a catalog misconfig surfaces as
  # plainly unadjusted volumes instead of silently masquerading as a valid ratio
  # calc. Regular mode always restores the retail base volumes.
  def cart_item_volumes(base, mode, quantity, source)
    if mode == :subscription && source == IntegrationSetting::PREFERRED_CUSTOMER_VOLUME_SOURCE
      if preferred_customer_volumes?(base)
        cv, qv = base[:pc_cv], base[:pc_qv]
      else
        Rails.logger.warn(
          "[DynamicPricing] subscription_volume_source=preferred_customer but variant " \
          "is missing pc_cv/pc_qv; writing retail volumes for cart #{cart_token}"
        )
        cv, qv = base[:cv], base[:qv]
      end

      return {
        "cv" => scaled_unit_volume(cv, 1.0, quantity),
        "qv" => scaled_unit_volume(qv, 1.0, quantity),
      }
    end

    ratio = mode == :subscription ? subscription_value_ratio(base) : 1.0
    {
      "cv" => scaled_unit_volume(base[:cv], ratio, quantity),
      "qv" => scaled_unit_volume(base[:qv], ratio, quantity),
    }
  end

  # Whether the variant carries usable preferred-customer volumes. Blank/nil
  # pc_cv or pc_qv means the catalog didn't set them, so the caller must fall
  # back rather than write zeros.
  def preferred_customer_volumes?(base)
    base[:pc_cv].present? && base[:pc_qv].present?
  end

  # Fraction of base volume to keep under subscription pricing =
  # subscription_price / retail price, clamped to [0, 1]. Falls back to 1.0
  # (no reduction) when the variant's prices are missing or non-positive.
  def subscription_value_ratio(base)
    retail = base[:price].to_f
    subscription = base[:subscription_price].to_f
    return 1.0 if retail <= 0 || subscription <= 0

    (subscription / retail).clamp(0.0, 1.0)
  end

  # Per-unit volume scaled by `ratio`. Rounded on the line total (base * qty)
  # then divided back per unit, matching Fluid core's rounding.
  def scaled_unit_volume(base_unit, ratio, quantity)
    base_unit = base_unit.to_f
    qty = [ quantity.to_i, 1 ].max
    total = (base_unit * qty * ratio).round
    [ (total.to_f / qty).round, 0 ].max
  end

  # Fetches the variant's per-unit base CV/QV plus retail/subscription price for
  # the cart's country, falling back to the first country entry. Memoized per
  # request since several items can share a variant. Returns nil when the
  # variant can't be resolved.
  def variant_base_volumes(variant_id)
    @variant_base_volumes ||= {}
    return @variant_base_volumes[variant_id] if @variant_base_volumes.key?(variant_id)

    response = fluid_client.variants.get(variant_id)
    variant = response&.dig("variant") || response&.dig(:variant)
    countries = variant&.dig("variant_countries") || variant&.dig(:variant_countries) || []

    match = countries.find { |c| (c["country_code"] || c[:country_code]) == cart_country } || countries.first
    @variant_base_volumes[variant_id] =
      if match
        {
          cv: (match["cv"] || match[:cv]).to_f,
          qv: (match["qv"] || match[:qv]).to_f,
          pc_cv: match["pc_cv"] || match[:pc_cv],
          pc_qv: match["pc_qv"] || match[:pc_qv],
          price: (match["price"] || match[:price]),
          subscription_price: (match["subscription_price"] || match[:subscription_price]),
        }
      end
  rescue StandardError => e
    Rails.logger.error "Failed to fetch variant #{variant_id} volumes: #{e.message}"
    nil
  end

  # Fluid's cart payload exposes the country as an object (cart.country.iso) and
  # on the shipping target (ship_to/shipping_address.country_code) rather than a
  # flat cart.country_code. Accept all of these (STU2-2526).
  def cart_country
    cart&.dig("country_code") ||
      country_field_iso ||
      cart&.dig("ship_to", "country_code") ||
      cart&.dig("shipping_address", "country_code")
  end

  def country_field_iso
    country = cart&.dig("country")
    return country if country.is_a?(String)

    (country["iso"] || country[:iso]) if country.is_a?(Hash)
  end

  def update_cart_items_prices(items_data)
    raise CallbackError, "Items data is blank" if items_data.blank?

    safe_items = items_data.reject { |item| item["price"].to_f.zero? }
    if safe_items.size < items_data.size
      dropped = items_data - safe_items
      Rails.logger.warn(
        "[DynamicPricing] Refusing to set zero price for cart #{cart_token}, " \
        "dropped items: #{dropped.map { |i| i['id'] }.inspect}"
      )
    end
    return if safe_items.empty?

    fluid_client.carts.update_items_prices(cart_token, safe_items)
    Rails.logger.info "[DynamicPricing] Repriced #{safe_items.size} item(s) on cart #{cart_token}"
  rescue StandardError => e
    report_exception(e, message: "Failed to update cart items prices for cart #{cart_token}: #{e.message}")
  end

  # Returns { id, price } for each cart item using the subscription price.
  # For bundles, item.product.price may be 0 — fall back to item.price (the
  # cart's resolved price). Zero prices are filtered out by update_cart_items_prices.
  def cart_items_with_subscription_price
    cart_items.map do |item|
      {
        "id" => item["id"],
        "price" => item["subscription_price"].to_f.nonzero? || item["price"],
      }
    end
  end

  # Returns { id, price } for each cart item using the non-subscription price.
  # For bundles, item.product.price is often 0 (bundle parent has no base price)
  # so fall back to item.price, the cart's currently-resolved price. Zero prices
  # are filtered out by update_cart_items_prices to prevent $0 checkouts.
  def cart_items_with_regular_price
    cart_items.map do |item|
      {
        "id" => item["id"],
        "price" => item.dig("product", "price").to_f.nonzero? || item["price"],
      }
    end
  end

  def get_customer_id_by_email(email)
    return nil if email.blank?

    client = fluid_client
    response = client.customers.get(email: email)
    customers = response["customers"] || []

    customers.any? ? customers.first["id"] : nil
  rescue StandardError => e
    Rails.logger.error "Failed to get customer ID by email #{email}: #{e.message}"
    nil
  end

  def get_customer_type_from_metafields(customer_id)
    metafield = fluid_client.metafields.get_by_key(
      resource_type: "customer",
      resource_id: customer_id,
      key: "customer_type"
    )
    metafield&.dig("value", "customer_type") || metafield&.dig(:value, :customer_type)
  rescue StandardError
    nil
  end

  def fetch_customer_by_email(email)
    response = fluid_client.customers.get(email: email)
    customers = response["customers"] || []

    customer = customers.find { |c| c["email"]&.downcase == email.downcase }

    { success: true, data: customer }
  rescue StandardError
    { success: false, error: "customer_lookup_failed", message: "Unable to fetch customer data" }
  end

  def has_subscriptions?(customer_id)
    has_active = has_active_subscriptions?(customer_id)
    has_another = has_another_subscription_in_cart?

    has_active || has_another
  end

  def has_another_subscription_in_cart?
    active_subscription_count = cart_items.count { |item| item["subscription"] == true }

    active_subscription_count >= 1
  end

  # True when the incoming cart is already flagged for preferred pricing.
  # Cheap: reads the payload, no external calls.
  def cart_stamped_preferred?
    cart&.dig("metadata", "price_type") == PREFERRED_CUSTOMER_TYPE
  end

  # True when the cart should get preferred/subscription pricing even though it
  # is not stamped. The stamp lives in Fluid's cart metadata and can be missing
  # on a given callback (e.g. the cart was emptied after the attach/login that
  # stamped it, and attach/login does not re-fire on a re-add). So item_added /
  # item_updated cannot rely on the flag alone.
  #
  # Business rule: preferred iff the customer has an ACTIVE subscription OR the
  # cart carries a subscription line. We re-derive from the live subscription
  # source of truth rather than the cached (laggy) customer_type metafield.
  #
  # Order matters for cost: the in-cart check is free; the subscription lookups
  # hit external APIs and only run when the cart carries no subscription line.
  def cart_qualifies_for_preferred_pricing?
    has_another_subscription_in_cart? || customer_has_active_subscription?
  end

  # A live Fluid subscription, or an active Exigo autoship when the company runs
  # Exigo. The Fluid-subscriptions lookup needs a customer_id, so it is gated
  # behind a logged-in customer; the Exigo lookup is by email and works on guest
  # carts too (it self-guards on blank email / integration off).
  def customer_has_active_subscription?
    (customer_logged_in? && has_active_subscriptions?(cart_customer_id)) ||
      has_exigo_autoship_by_email?(customer_email)
  end

  # The single cart item carried by item_added / item_updated callbacks.
  def cart_item
    @cart_item ||= callback_params[:cart_item]
  end

  # Reprices the callback's cart item to its subscription price (falling back to
  # the regular price) and adjusts its volumes. Shared by CartItemAddedService
  # and CartItemUpdatedService so the two pricing paths cannot silently diverge.
  def update_item_to_subscription_price
    item_id = cart_item["id"]
    raise CallbackError, "Item ID is required" if item_id.blank?

    # Use the subscription price when it is a real (non-zero) amount, otherwise
    # fall back to the regular price. A zero subscription_price (e.g. bundle
    # parents) must NOT zero the item, or update_cart_items_prices drops it.
    final_price = cart_item["subscription_price"].to_f.nonzero? ? cart_item["subscription_price"] : cart_item["price"]

    raise CallbackError, "Item price is not present in cart item" if final_price.blank?

    item_data = [ {
      "id" => item_id,
      "price" => final_price,
    } ]

    update_cart_items_prices(item_data)
    update_cart_items_volumes([ cart_item ], mode: :subscription)
  end

  def has_active_subscriptions?(customer_id)
    response = fluid_client.subscriptions.get_by_customer(customer_id, status: "active")
    subscriptions = response["subscriptions"] || []
    subscriptions.any?
  rescue StandardError => e
    Rails.logger.error "Error checking active subscriptions for customer #{customer_id}: #{e.message}"
    false
  end

  def has_exigo_autoship_by_email?(email)
    return false unless exigo_integration_enabled?
    return false if email.blank?

    exigo_client.customer_has_active_autoship_by_email?(email)
  rescue StandardError => e
    Rails.logger.error "Error checking Exigo autoship for email #{email}: #{e.message}"
    false
  end

  def exigo_integration_enabled?
    company = find_company
    return false if company.blank?

    company.integration_setting&.exigo_enabled? || false
  end

  def exigo_client
    @exigo_client ||= initialize_exigo_client
  end

  def initialize_exigo_client
    company = find_company
    raise CallbackError, "Company is blank" if company.blank?
    raise CallbackError, "Exigo integration not enabled" unless company.integration_setting&.exigo_enabled?

    ExigoClient.for_company(company)
  end

  def is_preferred_customer?(email)
    return false if email.blank?

    customer_id = cart_customer_id || get_customer_id_by_email(email)
    if customer_id.present?
      customer_type = get_customer_type_from_metafields(customer_id)
      return true if customer_type == PREFERRED_CUSTOMER_TYPE

      # An active Fluid subscription makes a customer preferred regardless of the
      # (laggy) customer_type metafield — so login/attach agrees with the
      # subscription-based rule item_added/item_updated use and the two callback
      # paths can't disagree and oscillate the cart price (STU2-2531).
      return true if has_active_subscriptions?(customer_id)
    end

    has_exigo_autoship_by_email?(email)
  end

  def update_pcc_metafield(fluid_customer_id, customer_type)
    return if fluid_customer_id.blank? || customer_type.blank?

    fluid_client.metafields.ensure_definition(
      namespace: "custom",
      key: "customer_type",
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)",
      owner_resource: "Customer"
    )

    json_value = { "customer_type" => customer_type.to_s }

    fluid_client.metafields.update(
      resource_type: "customer",
      resource_id: fluid_customer_id.to_i,
      namespace: "custom",
      key: "customer_type",
      value: json_value,
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)"
    )
  rescue FluidClient::ResourceNotFoundError
    fluid_client.metafields.create(
      resource_type: "customer",
      resource_id: fluid_customer_id.to_i,
      namespace: "custom",
      key: "customer_type",
      value: json_value,
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)"
    )
  rescue StandardError => e
    Rails.logger.error "Failed to update PCC metafield for customer #{fluid_customer_id}: #{e.message}"
  end

  def success_with_message(msg)
    { success: true, message: msg }
  end

  # Builds a callback response that affirms the preferred_customer price_type on
  # the response channel Fluid applies back to the cart. Pair with
  # update_cart_metadata to also persist the slug for the next cart event. See
  # CartItemAddedService for why both channels are written.
  def preferred_pricing_response(message: nil)
    response = { success: true, metadata: { "price_type" => PREFERRED_CUSTOMER_TYPE } }
    response[:message] = message if message
    response
  end

  def log_cart_pricing_event(event_type:, preferred_applied:, additional_data: {})
    company = find_company
    return if company.blank?

    CartPricingEvent.create!(
      company: company,
      cart_id: cart&.dig("id"),
      email: cart&.dig("email"),
      event_type: event_type,
      preferred_pricing_applied: preferred_applied,
      items_count: cart_items.count,
      cart_total: calculate_cart_total,
      metadata: additional_data
    )
  rescue StandardError => e
    report_exception(e, message: "[CartPricingEvent] Failed to log event: #{e.message}")
  end

  # Logs an exception and reports it to Sentry with cart/customer context.
  # Callback services deliberately swallow most write failures so a single Fluid
  # hiccup never 500s the webhook; that silence is why bugs here went unnoticed.
  # This surfaces the swallowed failures in Sentry instead. Best-effort: it never
  # raises itself.
  def report_exception(exception, message: nil, **context)
    Rails.logger.error(message) if message
    return unless defined?(Sentry) && Sentry.respond_to?(:capture_exception)

    Sentry.capture_exception(
      exception,
      extra: {
        cart_token: cart_token,
        cart_id: cart&.dig("id"),
        customer_id: cart_customer_id,
        callback: self.class.name,
      }.merge(context)
    )
  rescue StandardError => reporting_error
    Rails.logger.error "[Sentry] Failed to report exception: #{reporting_error.message}"
  end

  def calculate_cart_total
    cart_items.sum { |item| (item["price"].to_f || 0) * (item["quantity"].to_i || 1) }
  rescue StandardError
    0.0
  end
end
