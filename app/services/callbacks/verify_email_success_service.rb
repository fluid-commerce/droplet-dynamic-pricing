class Callbacks::VerifyEmailSuccessService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?
    raise CallbackError, "Missing email" if customer_email.blank?

    clean_cart_metadata_before_update

    state_after_cleaning = cart.dig("metadata", "price_type")

    customer_type_result = fetch_and_validate_customer_type(customer_email)

    return customer_type_result unless customer_type_result[:success] && customer_type_result[:customer_type]

    final_is_preferred = customer_type_result[:customer_type] == PREFERRED_CUSTOMER_TYPE

    if final_is_preferred
      update_result = update_cart_metadata({ "price_type" => PREFERRED_CUSTOMER_TYPE })
      return update_result if update_result.is_a?(Hash) && update_result[:success] == false

      update_cart_items_prices(cart_items_with_subscription_price) if cart_items.any?
    end

    state_changed = (state_after_cleaning == PREFERRED_CUSTOMER_TYPE) != final_is_preferred
    if state_changed
      log_cart_pricing_event(
        event_type: "item_updated",
        preferred_applied: final_is_preferred,
        additional_data: { callback: "verify_email_success", email: customer_email }
      )
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end

private

  def clean_cart_metadata_before_update
    return if cart.dig("metadata", "price_type").nil?

    if has_another_subscription_in_cart?
      return
    end

    customer_data = fetch_customer_by_email(customer_email)
    unless customer_data[:success]
      clean_cart_metadata
      return
    end

    if customer_data[:data].blank?
      if has_exigo_autoship_by_email?(customer_email)
        return
      end
      clean_cart_metadata
      return
    end

    customer_id = customer_data[:data]["id"] || customer_data[:data][:id]
    if customer_id.blank?
      clean_cart_metadata
      return
    end

    if has_subscriptions?(customer_id)
      return
    end

    if has_exigo_autoship_by_email?(customer_email)
      return
    end

    clean_cart_metadata
  end

  def clean_cart_metadata
    update_result = update_cart_metadata({ "price_type" => nil })
    return if update_result.is_a?(Hash) && update_result[:success] == false

    update_cart_items_prices(cart_items_with_regular_price) if cart_items.any?
  end

  def fetch_and_validate_customer_type(email)
    customer_result = fetch_customer_by_email(email)

    return customer_result unless customer_result[:success]

    if customer_result[:data].blank?
      if has_exigo_autoship_by_email?(email)
        return { success: true, customer_type: PREFERRED_CUSTOMER_TYPE }
      end
      return success_with_message("Customer not found for #{email}")
    end

    customer_data = customer_result[:data]
    customer_id = customer_data["id"] || customer_data[:id]

    return success_with_message("Customer ID missing for #{email}") if customer_id.blank?

    customer_type = get_customer_type_from_metafields(customer_id)

    if customer_type.blank?
      if has_active_subscriptions?(customer_id) || has_exigo_autoship_by_email?(email)
        return { success: true, customer_type: PREFERRED_CUSTOMER_TYPE }
      end
      return success_with_message("Customer type not set for #{email}")
    end

    { success: true, customer_type: customer_type }
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

  def update_cart_metadata(metadata)
    Rails.logger.info "Updating cart metadata: #{metadata}"

    fluid_client.carts.append_metadata(cart_token, metadata)
  rescue CallbackError => e
    handle_callback_error(e)
  end

  def success_with_message(msg)
    { success: true, message: msg }
  end
end
