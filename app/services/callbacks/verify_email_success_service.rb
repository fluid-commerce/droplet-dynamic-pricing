class Callbacks::VerifyEmailSuccessService < Callbacks::BaseService
  def call
    email = @callback_params[:email] || @callback_params.dig("email")

    cart_token = @callback_params[:cart_token] ||
                 @callback_params.dig("cart_token") ||
                 @callback_params.dig(:cart, :cart_token) ||
                 @callback_params.dig("cart", "cart_token")

    return log_and_return("Missing email or cart_token", success: false) if email.blank? || cart_token.blank?

    customer_type_result = fetch_and_validate_customer_type(email)
    return customer_type_result unless customer_type_result[:success] && customer_type_result[:customer_type]

    customer_type = customer_type_result[:customer_type]

    if customer_type == PREFERRED_CUSTOMER_TYPE
      update_result = update_cart_metadata_by_cart_token(cart_token, { "price_type" => PREFERRED_CUSTOMER_TYPE })
      return update_result if update_result[:success] == false
    end

    log_and_return("Email verification successful for cart #{cart_token}, email #{email}", success: true)
  end

private

  def fetch_and_validate_customer_type(email)
    customer = fetch_customer_by_email(email)
    return customer if customer[:success] == false
    return log_and_return("Customer not found for email #{email}") if customer[:data].blank?

    customer_data = customer[:data]
    customer_id = customer_data["id"] || customer_data[:id]
    return log_and_return("Customer ID not found for email #{email}") if customer_id.blank?

    customer_type = get_customer_type_from_metafields(customer_id)
    return log_and_return("Customer type is not set for email #{email}",
message: "Customer type is not set") if customer_type.blank?

    { success: true, customer_type: customer_type }
  end

  def get_customer_type_from_metafields(customer_id)
    company = find_company
    return nil if company.blank?

    client = FluidClient.new(company.authentication_token)
    return nil if client.blank?

    metafield = client.metafields.get_by_key(
      resource_type: "customer",
      resource_id: customer_id,
      key: "customer_type"
    )

    return nil if metafield.blank?

    value = metafield["value"] || metafield[:value]
    return nil if value.blank?

    value["customer_type"] || value[:customer_type]
  rescue StandardError => e
    Rails.logger.error "Failed to get customer type from metafields for customer #{customer_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    nil
  end

  def fetch_customer_by_email(email)
    customer = get_customer_by_email(email)
    { success: true, data: customer }
  rescue StandardError => e
    Rails.logger.error "Failed to fetch customer for #{email}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: "customer_lookup_failed", message: "Unable to fetch customer data" }
  end

  def update_cart_metadata_by_cart_token(cart_token, metadata)
    update_cart_metadata(cart_token, metadata)
    { success: true }
  rescue StandardError => e
    Rails.logger.error "Failed to update cart metadata for cart #{cart_token}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: "cart_metadata_update_failed", message: "Unable to update cart metadata" }
  end
end
