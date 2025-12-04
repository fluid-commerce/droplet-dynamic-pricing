class Callbacks::VerifyEmailSuccessService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?
    raise CallbackError, "Missing email" if customer_email.blank?

    clean_cart_metadata_before_update

    customer_type_result = fetch_and_validate_customer_type(customer_email)

    return customer_type_result unless customer_type_result[:success] && customer_type_result[:customer_type]

    if customer_type_result[:customer_type] == PREFERRED_CUSTOMER_TYPE
      update_result = update_cart_metadata({ "price_type" => PREFERRED_CUSTOMER_TYPE })
      return update_result if update_result.is_a?(Hash) && update_result[:success] == false

      update_cart_items_prices(cart_items_with_subscription_price) if cart_items.any?
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end

private

  def clean_cart_metadata_before_update
    update_result = update_cart_metadata({ "price_type" => nil })
    return update_result if update_result.is_a?(Hash) && update_result[:success] == false
    update_cart_items_prices(cart_items_with_regular_price) if cart_items.any?
  end

  def fetch_and_validate_customer_type(email)
    customer_result = fetch_customer_by_email(email)

    return customer_result unless customer_result[:success]
    return success_with_message("Customer not found for #{email}") if customer_result[:data].blank?

    customer_data = customer_result[:data]
    customer_id = customer_data["id"] || customer_data[:id]

    return success_with_message("Customer ID missing for #{email}") if customer_id.blank?

    customer_type = get_customer_type_from_metafields(customer_id)
    return success_with_message("Customer type not set for #{email}") if customer_type.blank?

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
