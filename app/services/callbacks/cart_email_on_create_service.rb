require "cgi"

class Callbacks::CartEmailOnCreateService < Callbacks::BaseService
  def call
    cart = @callback_params[:cart]
    return { success: true } if cart.blank?

    email = cart["email"]
    customer_id = cart["customer_id"]

    return { success: true } if email.blank? && customer_id.blank?

    customer_type = get_customer_type_from_metafields(email, customer_id)

    if customer_type == "preferred_customer"
      { success: true, metadata: { "price_type" => "preferred_customer" } }
    else
      { success: true }
    end
  end

private

  def get_customer_type_from_metafields(email, customer_id)
    company = find_company
    return nil if company.blank?

    client = FluidClient.new(company.authentication_token)
    return nil if client.blank?

    resource_id = customer_id || get_customer_id_by_email(email)
    return nil if resource_id.blank?

    metafields_response = client.metafields.get(resource_type: "customer", resource_id: resource_id, page: 1,
per_page: 100)
    metafields = metafields_response["metafields"] || []
    customer_type_metafield = metafields.find { |m| m["key"] == "customer_type" }

    if customer_type_metafield && customer_type_metafield["value"].is_a?(Hash)
      customer_type_metafield["value"]["customer_type"]
    else
      nil
    end
  rescue StandardError => e
    Rails.logger.error "Failed to get customer type from metafields: #{e.message}"
    nil
  end

  def get_customer_id_by_email(email)
    return nil if email.blank?

    customer_data = get_customer_by_email(email)
    customer_data&.dig("id")
  rescue StandardError => e
    Rails.logger.error "Failed to get customer ID by email #{email}: #{e.message}"
    nil
  end

  def get_customer_by_email(email)
    company = find_company
    return nil if company.blank?

    client = FluidClient.new(company.authentication_token)
    return nil if client.blank?

    escaped_email = CGI.escape(email.to_s)
    search_query = "search_query=#{escaped_email}"

    response = client.get("/api/customers?#{search_query}")
    customers = response["customers"] || []

    customers.first
  rescue StandardError => e
    Rails.logger.error "Failed to get customer by email #{email}: #{e.message}"
    nil
  end
end
