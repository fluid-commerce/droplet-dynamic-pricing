require "cgi"

class Callbacks::CartEmailOnCreateService < Callbacks::BaseService
  def call
    cart = @callback_params[:cart]
    return log_and_return("Cart data is missing", success: false) if cart.blank?

    email, customer_id, cart_token = extract_cart_details(cart)
    return log_and_return("Both email and customer_id are missing") if email.blank? && customer_id.blank?

    customer_type_result = fetch_and_validate_customer_type(email, customer_id)
    return customer_type_result unless customer_type_result[:success] && customer_type_result[:customer_type]

    customer_type = customer_type_result[:customer_type]

    if customer_type == PREFERRED_CUSTOMER_TYPE
      update_cart_metadata(cart_token, { "price_type" => PREFERRED_CUSTOMER_TYPE })
      log_and_return("Customer type is preferred_customer, cart metadata updated", success: true)
    else
      log_and_return("Customer type is '#{customer_type}', no special pricing needed", success: true)
    end
  end

private

  def extract_cart_details(cart)
    email = cart["email"]
    customer_id = cart["customer_id"]
    cart_token = cart["cart_token"]
    [ email, customer_id, cart_token ]
  end

  def fetch_and_validate_customer_type(email, customer_id)
    customer_type = get_customer_type_from_metafields(email, customer_id)
    return customer_type if customer_type[:success] == false

    if customer_type[:data].blank?
      return log_and_return("Customer type not found for email: #{email}, customer_id: #{customer_id}")
    end

    { success: true, customer_type: customer_type[:data] }
  end

  def get_customer_type_from_metafields(email, customer_id)
    client = fluid_client
    return log_and_return("FluidClient initialization failed", success: false) if client.blank?

    resource_id = customer_id || get_customer_id_by_email(email)
    return log_and_return("Customer ID not found", error: "customer_id_not_found") if resource_id.blank?

    metafields_response = client.metafields.get(resource_type: "customer", resource_id: resource_id, page: 1,
per_page: 100)
    metafields = metafields_response["metafields"] || []
    customer_type_metafield = metafields.find { |m| m["key"] == "customer_type" }

    if customer_type_metafield && customer_type_metafield["value"].is_a?(Hash)
      customer_type_value = customer_type_metafield["value"]["customer_type"]
      { success: true, data: customer_type_value }
    else
      { success: true, data: nil }
    end
  rescue StandardError => e
    Rails.logger.error "Failed to get customer type from metafields: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: "metafields_lookup_failed", message: "Unable to fetch customer metafields" }
  end

  def get_customer_id_by_email(email)
    return nil if email.blank?

    customer_data = fetch_customer_by_email(email)
    return nil if customer_data[:success] == false || customer_data[:data].blank?

    customer_data[:data]&.dig("id")
  end

  def fetch_customer_by_email(email)
    client = fluid_client
    return { success: false, error: "FluidClient initialization failed" } if client.blank?

    escaped_email = CGI.escape(email.to_s)
    search_query = "search_query=#{escaped_email}"

    response = client.get("/api/customers?#{search_query}")
    customers = response["customers"] || []

    { success: true, data: customers.first }
  rescue StandardError => e
    Rails.logger.error "Failed to get customer by email #{email}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    log_and_return("Failed to get customer by email #{email}: #{e.message}", success: false)
  end
end
