class Callbacks::BaseService
  PREFERRED_CUSTOMER_TYPE = "preferred_customer"

  # Cart states in which Fluid has already taken the shopper's money. The cart is
  # closed to modification, so a price write either bounces with 410 or lands on
  # an order that has already been charged, leaving the captured amount and the
  # order total disagreeing (CURRENT-3361).
  #
  # Deliberately a denylist of settled states rather than an allowlist of mutable
  # ones: a state we have not seen must fall through to "reprice" (Fluid's own 410
  # is the backstop) instead of silently switching pricing off on a live cart.
  SETTLED_CART_STATES = %w[ payment_authorized payment_captured ].freeze

  # Callback triggers that only fire once the order exists. There is no cart left
  # to price at that point, whatever state the payload reports.
  POST_ORDER_TRIGGERS = %w[ order_completion ].freeze

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

  # True when this callback must not write to the cart at all. Two independent
  # signals, because the incident needed both: the order_completion attach still
  # reported a mutable-looking cart on one payload, and the logout detach that
  # followed it reported payment_captured (CURRENT-3361).
  #
  # Note this keys off cart state, NOT the trigger: a logout while the shopper is
  # still building the cart is a legitimate reason to revert pricing, and must
  # keep working.
  def cart_settled?
    SETTLED_CART_STATES.include?(cart_state) ||
      POST_ORDER_TRIGGERS.include?(callback_trigger_source)
  end

  def callback_trigger_source
    callback_context["trigger_source"] || callback_context[:trigger_source]
  end

  def cart_state
    cart&.dig("state") || cart&.dig(:state)
  end

  # `context` is a top-level sibling of `cart` in the callback payload, not a cart
  # field. Indifferent to string/symbol keys for the same reason find_company is.
  def callback_context
    @callback_context ||= callback_params[:context] || callback_params["context"] || {}
  end

  # Last line of defence for the settled-cart guard. The callback services return
  # early on cart_settled?, but enforcing it at every write means a service that
  # forgets to (or a path added later) still cannot charge-then-reprice.
  def refuse_settled_write(what)
    return false unless cart_settled?

    Rails.logger.warn(
      "[DynamicPricing] Refusing to write #{what} to settled cart #{cart_token} " \
      "(state=#{cart_state.inspect}, trigger=#{callback_trigger_source.inspect})"
    )
    true
  end

  # Whether a preferred-status lookup could not be answered this request (Fluid or
  # Exigo errored). "Unknown" must not be read as "not preferred": the rollback
  # paths rewrite every line price, so a transient API failure would otherwise
  # cost the shopper their discount (CURRENT-3361).
  def preferred_lookup_failed?
    @preferred_lookup_failed == true
  end

  def note_preferred_lookup_failure!
    @preferred_lookup_failed = true
  end

  # Whether the subscriptions response carried the key we read, either shape.
  # An absent key means we cannot tell empty from unanswered.
  def subscriptions_response_usable?(response)
    return false unless response.respond_to?(:key?)

    response.key?("subscriptions") || response.key?(:subscriptions)
  end

  # How long one answer about a customer's standing subscriptions is reused.
  #
  # Core fires one cart_item callback per line, so an N-line add asks the same
  # two questions N times within a few seconds — each a round trip to Fluid or,
  # worse, a fresh SQL connection to Exigo, all inside the budget the shopper is
  # waiting on. A customer's subscriptions cannot change between the callbacks of
  # a single add, so the window only has to be wide enough to cover one burst.
  #
  # Deliberately short. The cart-side half of the rule
  # (has_another_subscription_in_cart?) is read from the payload and never
  # cached, so the case where the shopper's own action changes the answer — they
  # just added a subscription line — is still answered live.
  PREFERRED_LOOKUP_TTL = ENV.fetch("PREFERRED_LOOKUP_TTL_SECONDS", 30).to_i

  # Scoped to the company, and to the identity being asked about rather than to
  # the cart, so the two carts of one shopper share the answer too. Digested
  # because the identifier is an email on the Exigo path and cache keys live in a
  # table we own. nil disables caching for this lookup rather than risking a key
  # that could collide across companies.
  #
  # The identifier is digested VERBATIM. Normalising it here (strip/downcase)
  # would make the key stand for a different question than the one asked: the
  # Exigo query passes the raw string into `WHERE c.Email = ?`, where leading
  # whitespace is significant and the collation may be case-sensitive. A
  # normalised key would let " a@b.com" and "a@b.com" — which can genuinely get
  # different answers from Exigo — share one cached result.
  def preferred_lookup_key(kind, identifier)
    company_id = reporting_company_id
    return nil if company_id.blank? || identifier.blank?

    digest = Digest::SHA256.hexdigest(identifier.to_s)
    "dynamic_pricing:preferred:#{kind}:#{company_id}:#{digest}"
  end

  # nil means "nothing cached" — a cached `false` is a real answer and must be
  # returned as one. Cache trouble can never be the thing that breaks pricing, so
  # both helpers swallow and fall through to the live lookup.
  def read_preferred_lookup(key)
    # The TTL guard belongs on the read as well as the write, so setting
    # PREFERRED_LOOKUP_TTL_SECONDS=0 mid-incident takes effect at once instead of
    # stopping new writes while already-written entries keep being served.
    return nil if key.nil? || PREFERRED_LOOKUP_TTL <= 0

    Rails.cache.read(key)
  rescue StandardError => e
    Rails.logger.warn "[DynamicPricing] preferred-lookup cache read failed: #{e.message}"
    nil
  end

  def write_preferred_lookup(key, answer)
    return if key.nil? || PREFERRED_LOOKUP_TTL <= 0

    # Never freeze the answer taken at the moment it flips. order_completion is
    # ~39% of cart_customer_attached traffic and fires while the
    # subscription-start order is being finalised, so the lookup there can
    # legitimately say "no subscriptions" about a customer who is acquiring one
    # right now. Reads still hit the cache; only the write is skipped.
    return if cart_settled?

    Rails.cache.write(key, answer, expires_in: PREFERRED_LOOKUP_TTL.seconds)
  rescue StandardError => e
    Rails.logger.warn "[DynamicPricing] preferred-lookup cache write failed: #{e.message}"
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

  # :callback, not the default — the shopper's request is blocked on this one.
  # See Connections::Fluid for why a 30s per-call timeout inside a 20s callback
  # budget can only ever expire after Fluid has stopped listening.
  def initialize_fluid_client
    company = find_company
    raise CallbackError, "Company is blank" if company.blank?

    FluidClient.new(company.authentication_token, profile: :callback)
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
    return if refuse_settled_write("metadata")

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
    return if refuse_settled_write("volumes")

    # Constant for the whole request — resolve once, not per item.
    source = subscription_volume_source

    # Rescued per item, not around the loop: with a batched callback a
    # transient failure on an early item must not strand every later item's
    # volumes. Each failure is reported on its own.
    Array(items).each do |item|
      item_id = item["id"]
      variant_id = item_variant_id(item)
      next if item_id.blank? || variant_id.blank?

      base = variant_base_volumes(variant_id)
      next if base.nil?

      volumes = cart_item_volumes(base, mode, item["quantity"], source)

      fluid_client.carts.update_item_volumes(cart_token, item_id, volumes)
    rescue StandardError => e
      report_exception(e, message: "Failed to update volumes for item #{item_id} on cart #{cart_token}: #{e.message}")
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
    return if refuse_settled_write("prices")
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

  # The payload's own subscription price for one item. Zero-aware: a
  # bundle's "0.0" is a truthy String, so a plain `||` on the raw field would
  # stop there and write zero. The single home for this fallback chain — the
  # validation in update_item_to_subscription_price and the PATCH builder
  # below must never disagree about it.
  def subscription_payload_price(item)
    nonzero_price(item["subscription_price"]) ||
      bundle_group_base_price(item) ||
      item["price"]
  end

  # { id, price } per cart item at its subscription price, resolved from the cart's
  # country. Items country_safe_price refuses are dropped.
  def cart_items_with_subscription_price(items = cart_items)
    items.filter_map do |item|
      price = country_safe_price(item, subscription_payload_price(item), kind: :subscription)
      next if price.nil?

      { "id" => item["id"], "price" => price }
    end
  end

  # As above, at the non-subscription price.
  def cart_items_with_regular_price(items = cart_items)
    items.filter_map do |item|
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

  # Lines this droplet wrote: Fluid stamps price_locked on every price we set
  # (Commerce::Api::Carts::UpdateCartItemsPricesAction) and then skips them when it
  # reprices, so these are the only ones a country change can strand.
  def locked_cart_items
    cart_items.select do |item|
      metadata = item_metadata(item)
      (metadata["price_locked"] || metadata[:price_locked]) == true
    end
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

  # The price to write for `item` (STU2-3108). Echoing the payload let a price Fluid
  # had resolved against another country be written as an admin override and locked,
  # so the right price could never come back — a PH cart was charged the CAD figure,
  # 113.85 instead of 2,499.
  #
  # The payload still wins by default. Fluid resolves a price through more than the
  # variant_country columns — a percentage subscription plan computes off the retail
  # price, a wholesale rep reads the wholesale columns — so replacing its figure
  # outright would trade this bug for a wider one. The row is used only once the
  # payload is shown to belong to a country the cart is not in.
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

    foreign = foreign_priced_row(rows, payload_price)
    return payload_price.to_f if foreign.nil?

    field = price_field_for(kind)
    authoritative = row_field(variant_country_row(variant_id), field).to_f
    return authoritative if authoritative.positive?

    # The payload is another country's and the cart's own row has nothing to put in
    # its place — fee and adjustment SKUs sit at 0.0 everywhere.
    refuse_cross_country_price(item, variant_id, payload_price, foreign, field)
  end

  def price_field_for(kind)
    kind == :subscription ? "subscription_price" : "price"
  end

  # Every column a price can come from. Which one Fluid used depends on the cart and
  # the item — a rep moves it to the wholesale columns, an unsubscribable item
  # collapses subscription onto regular, a zero discount falls back to the base.
  PRICE_COLUMNS = %w[price subscription_price wholesale wholesale_subscription_price].freeze

  # A row for a country OTHER than the cart's matching `value` — and only when the
  # cart's own row cannot explain it. If the number is in your own country's row it
  # didn't come from elsewhere, whatever the other rows hold. Without that half, a US
  # cart handed its own `wholesale` was called foreign because AU shared the figure
  # (Oliabo cart 757644), dropping a correct write.
  #
  # Still a heuristic — two countries may share a price — and it fails toward a
  # skipped reprice and an alert, never a wrong charge.
  def foreign_priced_row(rows, value)
    amount = value.to_f
    return nil unless amount.positive?

    own, foreign = rows.partition { |row| row_field(row, "country_code") == cart_pricing_country }
    return nil if own.any? { |row| row_prices(row).any? { |p| same_money?(p, amount) } }

    foreign.find { |row| row_prices(row).any? { |p| same_money?(p, amount) } }
  end

  def row_prices(row)
    PRICE_COLUMNS.map { |column| row_field(row, column) }
  end

  def same_money?(one, two)
    return false if one.nil? || two.nil?

    one.to_f.round(2) == two.to_f.round(2)
  end

  # Drops the write either way; alerts only when the cart's country has an ACTIVE row.
  #
  # Fluid creates a row per company country, so one the variant isn't sold in still
  # exists — inactive, at 0.00 — and variant_country_row skips it, as Fluid does. With
  # no active row Fluid prices nothing and blocks the line at checkout: expected, and
  # nothing to action. An active row at 0.00 still alerts, since the variant IS sold
  # there and its price is missing.
  def refuse_cross_country_price(item, variant_id, payload_price, foreign, field)
    foreign_country = row_field(foreign, "country_code")
    own_row = variant_country_row(variant_id)
    expected = row_field(own_row, field)
    message = "[DynamicPricing] Refusing cross-country price for item #{item['id']} " \
              "(variant #{variant_id}) on cart #{cart_token}: payload price #{payload_price.to_f} " \
              "belongs to #{foreign_country} (#{row_field(foreign, 'currency_code')}), but the " \
              "cart's country is #{cart_pricing_country} whose #{field} is #{expected.inspect}"

    if own_row.nil?
      Rails.logger.info(
        "#{message} — not sold in #{cart_pricing_country}, so the line is unbuyable there " \
        "and Fluid blocks it at checkout. Expected, not reported."
      )
      return nil
    end

    Rails.logger.warn(message)
    report_exception(
      CrossCountryPriceError.new(message),
      item_id: item["id"],
      variant_id: variant_id,
      cart_country: cart_pricing_country,
      payload_price: payload_price,
      expected_price: expected,
      foreign_country: foreign_country
    )
    nil
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

  # Memoized per request (nil included): the login path reads this twice for the
  # same customer — once through is_preferred_customer?, then again in
  # sync_pcc_metafield when the first read said "not preferred" but a live
  # subscription said otherwise. That second read is a guaranteed duplicate on
  # exactly the path that reaches it.
  #
  # Caching a failure is safe here: note_preferred_lookup_failure! is sticky for
  # the request, so the "unknown, do not strip the discount" rule still holds for
  # every later reader.
  def get_customer_type_from_metafields(customer_id)
    @customer_type_from_metafields ||= {}
    return @customer_type_from_metafields[customer_id] if @customer_type_from_metafields.key?(customer_id)

    failed = false
    value =
      begin
        read_customer_type_metafield(customer_id)
      rescue StandardError
        # A customer with no customer_type metafield returns nil without raising,
        # so reaching this rescue means the lookup itself failed, not that the
        # answer is "retail".
        failed = true
        note_preferred_lookup_failure!
        nil
      end

    # Only an answer is memoized. A failed read has to stay retryable: memoizing
    # its nil would hand sync_pcc_metafield a "not preferred" it never verified,
    # and it would spend ensure_definition + PATCH (+ POST) correcting a value it
    # cannot actually see — 2-3 Fluid calls on the most budget-constrained path,
    # which the old code skipped whenever the second read came back preferred.
    @customer_type_from_metafields[customer_id] = value unless failed
    value
  end

  def read_customer_type_metafield(customer_id)
    metafield = fluid_client.metafields.get_by_key(
      resource_type: "customer",
      resource_id: customer_id,
      key: "customer_type"
    )
    metafield&.dig("value", "customer_type") || metafield&.dig(:value, :customer_type)
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
      exigo_preferred_by_email?(customer_email)
  end

  # The single cart item carried by item_added / item_updated callbacks.
  def cart_item
    @cart_item ||= callback_params[:cart_item]
  end

  # Every item this callback speaks for. A company on Fluid's
  # BATCH_CART_ITEM_CALLBACKS flag sends one cart_item_added per add
  # operation with the added items in cart_items (first element identical
  # to cart_item); everyone else sends cart_item alone.
  def callback_cart_items
    @callback_cart_items ||= callback_params[:cart_items].presence || [ cart_item ].compact
  end

  # Reprices the callback's cart item to its subscription price (falling back to
  # the regular price) and adjusts its volumes. Shared by CartItemAddedService
  # and CartItemUpdatedService so the two pricing paths cannot silently diverge.
  def update_item_to_subscription_price
    items = callback_cart_items
    raise CallbackError, "Item ID is required" if items.any? { |item| item["id"].blank? }

    raise CallbackError, "Item price is not present in cart item" if items.any? { |item|
 subscription_payload_price(item).blank? }

    # Items country_safe_price refuses are dropped, and already logged.
    # Volumes still go for every item: they come from the country-matched
    # row and self-skip without one.
    priced_items = cart_items_with_subscription_price(items)

    # Only the items the callback names — one PATCH for the whole batch.
    # Lines left behind in a previous country are CartCountryChangedService's,
    # which corrects the whole cart at once.
    update_cart_items_prices(priced_items) if priced_items.any?
    update_cart_items_volumes(items, mode: :subscription)
  end

  def has_active_subscriptions?(customer_id)
    key = preferred_lookup_key(:fluid_subscriptions, customer_id)
    cached = read_preferred_lookup(key)
    return cached unless cached.nil?

    response = fluid_client.subscriptions.get_by_customer(customer_id, status: "active")
    subscriptions = response["subscriptions"] || []
    answer = subscriptions.any?

    # A 200 is not the same as an answer. An empty body, a `{}`, an error object
    # served 200, or a change in response shape all collapse to `[].any? == false`
    # — and `false` is the value that unlocks the strip branch in
    # CustomerLoggedInService, which rewrites every line to retail. Caching that
    # would spread one degenerate response across every cart of this customer for
    # the whole window, so it is returned (as today) but never written.
    if subscriptions_response_usable?(response)
      write_preferred_lookup(key, answer)
    else
      Rails.logger.warn(
        "[DynamicPricing] subscriptions lookup for #{customer_id} answered without a " \
        "subscriptions key; not caching #{answer.inspect}"
      )
    end

    answer
  rescue StandardError => e
    Rails.logger.error "Error checking active subscriptions for customer #{customer_id}: #{e.message}"
    note_preferred_lookup_failure!
    false
  end

  # Which Exigo question is asked is per installation — an active autoship
  # (the default, and today's behavior everywhere) or the customer's
  # CustomerTypeID. See IntegrationSetting#exigo_preferred_signal.
  #
  # Keyed by signal, not by a shared :exigo_autoship: the two answer different
  # questions, so a company that flips the setting must not read back the other
  # signal's cached answer.
  def exigo_preferred_by_email?(email)
    return false unless exigo_integration_enabled?
    return false if email.blank?

    by_customer_type = exigo_integration_setting&.exigo_preferred_by_customer_type?
    key = preferred_lookup_key(by_customer_type ? :exigo_customer_type : :exigo_autoship, email)
    cached = read_preferred_lookup(key)
    return cached unless cached.nil?

    answer =
      if by_customer_type
        exigo_customer_type_matches?(email)
      else
        exigo_client.customer_has_active_autoship_by_email?(email)
      end

    # Both Exigo reads return a strict boolean, so unlike the Fluid lookup above
    # there is no "200 with no answer" shape to guard against.
    write_preferred_lookup(key, answer)
    answer
  rescue StandardError => e
    Rails.logger.error "Error checking Exigo preferred status for email #{email}: #{e.message}"
    note_preferred_lookup_failure!
    false
  end

  # to_s on both sides: Exigo hands back CustomerTypeID as an Integer, while
  # preferred_customer_type_id is a String everywhere it comes from (the JSONB
  # default is "2", and the admin form writes a text field). Comparing them raw
  # is 2 == "2" — false for every customer.
  def exigo_customer_type_matches?(email)
    customer_type = exigo_client.customer_type_by_email(email)
    return false if customer_type.nil?

    customer_type.to_s == exigo_integration_setting.preferred_customer_type_id.to_s
  end

  def exigo_integration_setting
    find_company&.integration_setting
  end

  def exigo_integration_enabled?
    company = find_company
    return false if company.blank?

    company.integration_setting&.exigo_enabled? || false
  end

  def exigo_client
    @exigo_client ||= initialize_exigo_client
  end

  # Exigo's own defaults (5s connect + 15s query) add up to the whole 20s budget
  # Fluid gives a callback, on a fresh SQL connection each time. The lookup on
  # this path is a single indexed COUNT, so it gets a fraction of that; failing
  # fast here costs a shopper the preferred check (which fails to "unknown", not
  # to "retail") instead of costing them the callback.
  # Exigo's own defaults (5s connect + 15s query) add up to the whole 20s budget
  # Fluid gives a callback, on a fresh TinyTds connection each time. Tightening
  # them belongs in its own change: nothing has measured how long that COUNT
  # actually takes from Cloud Run, and the callback-timing log this PR adds is
  # what will answer it.
  def initialize_exigo_client
    company = find_company
    raise CallbackError, "Company is blank" if company.blank?
    raise CallbackError, "Exigo integration not enabled" unless company.integration_setting&.exigo_enabled?

    ExigoClient.for_company(company)
  end

  def is_preferred_customer?(email)
    return false if email.blank?

    customer_id = cart_customer_id || get_customer_id_by_email(email)

    # The active-subscription override below is kept on BOTH sources on purpose.
    # It exists so the two callback paths cannot disagree and oscillate the cart
    # price (STU2-2531), and on the member-type path it is not redundant with
    # the member type: it is a behavioral signal rather than an assigned one, so
    # it catches a connector that has not caught up with a new autoship yet.
    if preferred_from_fluid_member_type?
      return true if fluid_member_preferred?(customer_id: customer_id, email: email)
      return true if customer_id.present? && has_active_subscriptions?(customer_id)

      # No Exigo fallback: the whole point of this source is that the
      # installation does not read Exigo.
      return false
    end

    if customer_id.present?
      customer_type = get_customer_type_from_metafields(customer_id)
      return true if customer_type == PREFERRED_CUSTOMER_TYPE

      return true if has_active_subscriptions?(customer_id)
    end

    exigo_preferred_by_email?(email)
  end

  def preferred_from_fluid_member_type?
    find_company&.integration_setting&.preferred_from_fluid_member_type? || false
  end

  # Resolves the Fluid member behind this cart and answers whether Fluid itself
  # calls them preferred. The customer id is members.legacy_customer_id, which
  # `find` matches on directly, so there is no mapping to keep; the email is the
  # fallback for a cart with no customer attached yet.
  #
  # Memoizes an answer but never a failure, for the same reason
  # get_customer_type_from_metafields does not: a failed read that memoized its
  # nil would hand the rest of the callback a "not preferred" it never verified.
  def fluid_member_preferred?(customer_id:, email:)
    identifier = customer_id.present? ? { legacy_customer_id: customer_id } : { email: email }
    return false if identifier.values.first.blank?

    @fluid_member_preferred ||= {}
    return @fluid_member_preferred[identifier] if @fluid_member_preferred.key?(identifier)

    answer = read_member_type_slug(identifier) == Fluid::Members::PREFERRED_SLUG
    @fluid_member_preferred[identifier] = answer
    answer
  rescue FluidClient::ResourceNotFoundError
    # No member matched. That is a real negative, the same way a customer with
    # no customer_type metafield is — not a lookup that failed.
    @fluid_member_preferred[identifier] = false
    false
  rescue StandardError => e
    Rails.logger.error "Failed to read Fluid member type for #{identifier.inspect}: #{e.message}"
    note_preferred_lookup_failure!
    false
  end

  def read_member_type_slug(identifier)
    response = fluid_members.find_by(**identifier)
    member = response["member"] || response[:member]
    member&.dig("member_type_slug") || member&.dig(:member_type_slug)
  end

  def fluid_members
    fluid_client.members
  end

  def update_pcc_metafield(fluid_customer_id, customer_type)
    return if fluid_customer_id.blank? || customer_type.blank?

    # Built before the first call, not between the two: ensure_definition can
    # itself raise ResourceNotFoundError (find_definition_by_key 404s and
    # metafields.rb re-raises anything that is not an "already exists"), and the
    # rescue below then reached `create` with json_value still nil — where
    # `value cannot be blank` made the fallback impossible and blamed the wrong
    # thing in the log.
    json_value = { "customer_type" => customer_type.to_s }

    fluid_client.metafields.ensure_definition(
      namespace: "custom",
      key: "customer_type",
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)",
      owner_resource: "Customer"
    )

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
        # The droplet is shared and Sentry scrubs cart_token as PII, so without this an
        # alert says nothing about which tenant raised it.
        company_id: reporting_company_id,
        cart_token: cart_token,
        cart_id: cart&.dig("id"),
        customer_id: cart_customer_id,
        callback: self.class.name,
      }.merge(context)
    )
  rescue StandardError => reporting_error
    Rails.logger.error "[Sentry] Failed to report exception: #{reporting_error.message}"
  end

  # From the payload, not find_company: reporting must never be the thing that raises,
  # and an unresolvable company is what a report may well be describing.
  def reporting_company_id
    cart&.dig("company", "id") || cart&.dig(:company, :id)
  end

  def calculate_cart_total
    cart_items.sum { |item| (item["price"].to_f || 0) * (item["quantity"].to_i || 1) }
  rescue StandardError
    0.0
  end
end
