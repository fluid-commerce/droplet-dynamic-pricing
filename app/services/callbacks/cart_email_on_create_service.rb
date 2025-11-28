require "cgi"

class Callbacks::CartEmailOnCreateService < Callbacks::BaseService
  def call
    cart = @callback_params[:cart]
    return { success: true } if cart.blank?

    email = cart["email"]
    customer_id = cart["customer_id"]
    cart_token = cart["cart_token"]

    return { success: true } if email.blank? && customer_id.blank?
    customer_type = get_customer_type_from_metafields(email, customer_id)

    if customer_type == "preferred_customer"
      company = find_company
      return { success: true } if company.blank?

      cart_client = FluidClient.new(company.authentication_token)

      begin
        cart_client.carts.append_metadata(cart_token, { "price_type" => "preferred_customer" })
      rescue => e
        Rails.logger.error "Failed to update cart metadata: #{e.message}"
        return { success: true,
        message: "Cart not accessible, skipping updates", error: e.message, }
      end

      cart_items = cart["items"] || []
      if cart_items.any?
        cart_items.each do |item|
          item_data = [ {
            "id" => item["id"],
            "price" => item["subscription_price"] || item["price"],
          } ]
          begin
            payload = { "cart_items" => item_data }
            cart_client.patch("/api/carts/#{cart_token}/update_cart_items_prices", body: payload)
          rescue => e
            Rails.logger.error "Failed to update item #{item['id']}: #{e.message}"
          end
        end

        begin
          total_amount = calculate_total_amount(cart_items, true)
          payload = { "amount_total" => total_amount }
          cart_client.patch("/api/carts/#{cart_token}/update_totals", body: payload)
        rescue => e
          Rails.logger.error "Failed to update totals: #{e.message}"
        end
      end
    else
      Rails.logger.info "Customer is not preferred_customer (type: #{customer_type}), no action needed"
    end

    { success: true }
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
    customer_id = customer_data&.dig("id")

    customer_id
  rescue StandardError => e
    Rails.logger.error "Failed to get customer ID by email #{email}: #{e.message}"
    nil
  end

  def get_customer_by_email(email)
    company = find_company
    return nil if company.blank?

    client = FluidClient.new(company.authentication_token)
    return nil if client.blank?

    # Use search_query format like in the example
    escaped_email = CGI.escape(email.to_s)
    search_query = "search_query=#{escaped_email}"

    Rails.logger.info "Searching customer with query: #{search_query}"
    response = client.get("/api/customers?#{search_query}")
    customers = response["customers"] || []

    Rails.logger.info "Found #{customers.length} customers for email #{email}"
    customers.first
  rescue StandardError => e
    Rails.logger.error "Failed to get customer by email #{email}: #{e.message}"
    nil
  end
end
