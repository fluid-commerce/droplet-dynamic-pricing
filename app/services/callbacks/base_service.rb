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

  # yoli-promos stamps cart.metadata.price_type = "wholesale" when its WHOLESALE
  # unlock code is applied (bp_wholesale_applied, STU2-2964). Dynamic pricing
  # must yield on that cart too — same reasoning as yield_to_enrollment_wholesale?
  # above, but keyed off the metadata stamp instead of enrollment shape, and NOT
  # gated behind the per-company toggle (any cart stamped this way is explicitly
  # under yoli-promos' wholesale pricing, not dynamic pricing's).
  #
  # Nil-safe and indifferent to string/symbol keys, since cart can be a plain
  # Hash (tests) or a HashWithIndifferentAccess (production).
  def price_type_wholesale?
    metadata = cart&.dig("metadata") || cart&.dig(:metadata) || {}
    (metadata["price_type"] || metadata[:price_type]) == "wholesale"
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
    # Memoized (including a nil result): a single callback resolves the company
    # several times (initialize_fluid_client, exigo_integration_enabled?,
    # adjust_volumes_for_subscription?, log_cart_pricing_event, report_exception)
    # and it is stable for the life of the request.
    return @company if defined?(@company)

    # Use the `cart` accessor (reads callback_params[:cart]) rather than
    # callback_params.dig("cart", ...) so this works whether the cart key is a
    # symbol (plain hash, e.g. in tests) or a string (HashWithIndifferentAccess
    # from the controller in production).
    company_data = cart&.dig("company")
    raise CallbackError, "Company data is blank" if company_data.blank?

    @company = Company.find_by(fluid_company_id: company_data["id"])
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
      variant_id = item_variant_id(item)
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

  # The variant's per-unit base CV/QV plus prices, falling back to the first country
  # entry. Resolves its own row rather than reusing variant_country_row: volumes are
  # STU2-2526's and stay exactly as that ticket left them.
  def variant_base_volumes(variant_id)
    rows = variant_country_rows(variant_id)
    return nil if rows.blank?

    match = rows.find { |row| row_field(row, "country_code") == cart_country } || rows.first
    return nil if match.nil?

    {
      cv: row_field(match, "cv").to_f,
      qv: row_field(match, "qv").to_f,
      pc_cv: row_field(match, "pc_cv"),
      pc_qv: row_field(match, "pc_qv"),
      price: row_field(match, "price"),
      subscription_price: row_field(match, "subscription_price"),
    }
  end

  def item_variant_id(item)
    item["variant_id"] || item.dig("variant", "id")
  end

  # The variant's active row for the cart's own country, mirroring
  # CartItem#variant_country_for_country_id: inactive means the company doesn't sell
  # it there, so there is no price to use. An absent flag counts as active — the live
  # endpoint always sends it, and reading a missing key as "not sold" would stop
  # pricing everything at once.
  def variant_country_row(variant_id)
    return nil if cart_pricing_country.blank?

    rows = variant_country_rows(variant_id)
    return nil if rows.blank?

    rows.find do |row|
      next false unless row_field(row, "country_code") == cart_pricing_country

      active = row_field(row, "active")
      active.nil? || active
    end
  end

  # Memoized per request (nil included) since items share variants and both the
  # volume and price paths need them. nil when the variant can't be fetched.
  def variant_country_rows(variant_id)
    @variant_country_rows ||= {}
    return @variant_country_rows[variant_id] if @variant_country_rows.key?(variant_id)

    response = fluid_client.variants.get(variant_id)
    variant = response&.dig("variant") || response&.dig(:variant)
    @variant_country_rows[variant_id] =
      variant&.dig("variant_countries") || variant&.dig(:variant_countries) || []
  rescue StandardError => e
    Rails.logger.error "Failed to fetch variant #{variant_id} country rows: #{e.message}"
    @variant_country_rows[variant_id] = nil
  end

  # Either key shape, keeping a present `false` distinct from an absent key.
  def row_field(row, key)
    return nil if row.nil?

    row[key].nil? ? row[key.to_sym] : row[key]
  end

  # The cart's OWN country, where its currency comes from — the only country a price
  # may be resolved against. Narrower than cart_country on purpose: taking a price
  # from ship_to while the currency comes from the cart IS the STU2-3108 bug.
  def cart_pricing_country
    cart&.dig("country_code") || cart&.dig(:country_code) || country_field_iso
  end

  # Volume resolution only (STU2-2526) — anything deciding a PRICE uses
  # cart_pricing_country.
  def cart_country
    cart_pricing_country ||
      cart&.dig("ship_to", "country_code") ||
      cart&.dig("shipping_address", "country_code")
  end

  def country_field_iso
    country = cart&.dig("country")
    return country if country.is_a?(String)

    (country["iso"] || country[:iso]) if country.is_a?(Hash)
  end

  def update_cart_items_prices(items_data)
    raise CallbackError, "Items data is blank" if items_data.nil?

    # Empty means every item was refused by country_safe_price, which already logged
    # why — a deliberate no-op, not a caller error.
    if items_data.empty?
      Rails.logger.info "[DynamicPricing] No items left to reprice on cart #{cart_token}"
      return
    end

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

  # { id, price } per cart item at its subscription price, resolved from the cart's
  # country. Items country_safe_price refuses are dropped.
  def cart_items_with_subscription_price
    cart_items.filter_map do |item|
      payload_price = nonzero_price(item["subscription_price"]) ||
                      bundle_group_base_price(item) ||
                      item["price"]
      price = country_safe_price(item, payload_price, kind: :subscription)
      next if price.nil?

      { "id" => item["id"], "price" => price }
    end
  end

  # As above, at the non-subscription price.
  def cart_items_with_regular_price
    cart_items.filter_map do |item|
      payload_price = nonzero_price(item.dig("product", "price")) ||
                      bundle_group_base_price(item) ||
                      item["price"]
      price = country_safe_price(item, payload_price, kind: :regular)
      next if price.nil?

      { "id" => item["id"], "price" => price }
    end
  end

  def item_metadata(item)
    item["metadata"] || item[:metadata] || {}
  end

  # Fluid's own bundle figure, already in the cart's currency. Deliberately not
  # zero-aware: "0.0" means the bundle really prices at zero, and the zero-price
  # guard then drops the write and leaves the line as Fluid left it.
  def bundle_group_base_price(item)
    metadata = item_metadata(item)
    (metadata["bundle_group_base_price"] || metadata[:bundle_group_base_price]).presence
  end

  # A bundle's price never comes from variant_country. Its master variant may well
  # carry priced rows while its lines price at 0.0, so reading the row would
  # overwrite Fluid's bundle total and lock it. Broader than Fluid's
  # ItemPricing#use_bundle_group_pricing?, which also asks whether the product has
  # bundle groups — the droplet can't see that, and guessing fails in the dangerous
  # direction.
  def bundle_priced?(item)
    metadata = item_metadata(item)
    metadata["is_bundle"] == true || metadata[:is_bundle] == true
  end

  # `value` unless blank or numerically zero, so a `||` chain keeps walking.
  def nonzero_price(value)
    return nil if value.blank?

    value.to_f.zero? ? nil : value
  end

  # The price to write for `item`, from the variant's row for the cart's own country
  # rather than the callback payload (STU2-3108). Echoing the payload let a price
  # Fluid had resolved against another country be written as an admin override and
  # locked, so the right price could never come back — a PH cart was charged the CAD
  # figure, 113.85 instead of 2,499.
  #
  # Float, or nil to skip the item entirely.
  def country_safe_price(item, payload_price, kind:)
    variant_id = item_variant_id(item)
    return payload_price.to_f if variant_id.blank?
    return payload_price.to_f if bundle_priced?(item)

    # Log-only for now: refusing is the safer end state, but it would also stop
    # repricing a guest cart with no address yet.
    if cart_pricing_country.blank?
      Rails.logger.warn(
        "[DynamicPricing] Cannot resolve the pricing country for item #{item['id']} " \
        "on cart #{cart_token} (variant #{variant_id}); forwarding the payload price " \
        "#{payload_price.inspect} unchecked"
      )
      return payload_price.to_f
    end

    # Lookup failed — fall through rather than block the reprice on a blip.
    rows = variant_country_rows(variant_id)
    return payload_price.to_f if rows.blank?

    field = price_field_for(kind)
    authoritative = row_field(variant_country_row(variant_id), field).to_f
    return authoritative if authoritative.positive?

    # No usable row price — fee and adjustment SKUs sit at 0.0 everywhere and still
    # need repricing, so the payload is all there is.
    payload_price.to_f
  end

  def price_field_for(kind)
    kind == :subscription ? "subscription_price" : "price"
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

    # Zero-aware, matching cart_items_with_subscription_price: a bundle's "0.0" is a
    # truthy String, so a plain `||` would stop there and write zero.
    payload_price = nonzero_price(cart_item["subscription_price"]) ||
                    bundle_group_base_price(cart_item) ||
                    cart_item["price"]
    raise CallbackError, "Item price is not present in cart item" if payload_price.blank?

    final_price = country_safe_price(cart_item, payload_price, kind: :subscription)

    # Refused, and already logged. Volumes still go: they come from the
    # country-matched row and self-skip without one.
    if final_price.nil?
      update_cart_items_volumes([ cart_item ], mode: :subscription)
      return
    end

    # Only the item the callback names. Lines left behind in a previous country are
    # CartCountryChangedService's, which corrects the whole cart at once.
    update_cart_items_prices([ { "id" => item_id, "price" => final_price } ])
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
