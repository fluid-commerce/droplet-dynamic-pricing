class CallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    callback_name = params[:callback_name]

    company = find_company
    Rails.logger.info "Found company: #{company.inspect}"

    if company.blank?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    case callback_name
    when "subscription_added"
      handle_subscription_added
    when "subscription_removed"
      handle_subscription_removed
    else
      render json: { success: false, error: "Unknown callback: #{callback_name}" }, status: :bad_request
    end
  rescue StandardError => e
    Rails.logger.error "Callback error for #{callback_name}: #{e.message}"
    render json: { success: false, error: e.message }, status: :internal_server_error
  end

private

  def handle_subscription_added
    cart = callback_params[:cart]

    return render json: { success: true } if cart.blank?

    cart_token = cart["cart_token"]
    cart_items = cart["items"] || []

    update_cart_metadata(cart_token, { "price_type" => "preferred_customer" })

    if cart_items.any?
      items_data = build_subscription_items_data(cart_items)
      update_cart_items_prices(cart_token, items_data)
    end

    render json: { success: true }
  end

  def handle_subscription_removed
    cart = callback_params[:cart]

    return render json: { success: true } if cart.blank?

    cart_token = cart["cart_token"]
    cart_items = cart["items"] || []

    update_cart_metadata(cart_token, { "price_type" => nil })

    if cart_items.any?
      items_data = build_regular_items_data(cart_items)
      update_cart_items_prices(cart_token, items_data)
    end

    render json: { success: true }
  end

  def find_company
    company_data = callback_params.dig("cart", "company") || callback_params.dig(:cart, :company)

    if company_data.present?
      company = Company.find_by(fluid_company_id: company_data["id"])

      company
    end
  rescue StandardError => e
    Rails.logger.error "Error finding company: #{e.message}"
    nil
  end

  def update_cart_metadata(cart_token, metadata)
    return if cart_token.blank?

    company = find_company
    return if company.blank?

    client = FluidClient.new(company.authentication_token)
    client.carts.update_metadata(cart_token, metadata)
  rescue StandardError => e
    Rails.logger.error "Failed to update cart metadata for cart #{cart_token}: #{e.message}"
  end

  def update_cart_items_prices(cart_token, items_data)
    return if cart_token.blank? || items_data.blank?

    company = find_company
    return if company.blank?

    client = FluidClient.new(company.authentication_token)

    payload = { "cart_items" => items_data }

    response = client.class.patch("/api/carts/#{cart_token}/update_cart_items_prices",
                                 body: payload.to_json,
                                 headers: {
                                   "Authorization" => "Bearer #{company.authentication_token}",
                                   "Content-Type" => "application/json",
                                 })

    response
  rescue StandardError => e
    Rails.logger.error "Failed to update cart items prices for cart #{cart_token}: #{e.message}"
  end

  def build_subscription_items_data(cart_items)
    cart_items.map do |item|
      {
        "id" => item["id"],
        "price" => item["subscription_price"] || item["price"],
      }
    end
  end

  def build_regular_items_data(cart_items)
    cart_items.map do |item|
      {
        "id" => item["id"],
        "price" => item.dig("product", "price") || item["price"],
      }
    end
  end

  def callback_params
    params.permit!.to_h.with_indifferent_access
  end
end
