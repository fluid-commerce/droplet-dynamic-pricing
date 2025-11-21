class CallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    callback_name = params[:callback_name]

    company = find_company

    if company.blank? || !valid_auth_token?(company)
      render json: { error: "Unauthorized" }, status: :unauthorized
    end

    case callback_name
    when "verify_email_success"
      handle_verify_email_success
    when "cart_email_on_create"
      handle_cart_email_on_create
    when "item_added"
      handle_item_added
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

  def handle_verify_email_success
    email = callback_params[:email]
    customer = callback_params[:customer]

    Rails.logger.info "Processing verify_email_success for email: #{email}"
    Rails.logger.info "Customer data: #{customer.inspect}"

    if customer && customer.dig("metadata", "customer_type") == "preferred_customer"
      Rails.logger.info "Customer is preferred_customer, but no cart_id provided in verify_email_success"
    end

    render json: { success: true }
  end

  def handle_cart_email_on_create
    email = callback_params[:email]
    cart = callback_params[:cart]
    cart_id = cart&.dig("id")

    Rails.logger.info "Processing cart_email_on_create for email: #{email}, cart: #{cart_id}"

    customer = fetch_customer_by_email(email)

    if customer && customer.dig("metadata", "customer_type") == "preferred_customer"
      Rails.logger.info "Setting cart #{cart_id} to preferred_customer pricing"
      update_cart_metadata(cart_id, { "price_type" => "preferred_customer" })
    end

    render json: { success: true }
  end

  def handle_item_added
    cart = callback_params[:cart]
    cart_item = callback_params[:cart_item]
    cart_id = cart&.dig("id")
    item_id = cart_item&.dig("id")
    cart_metadata = cart&.dig("metadata") || {}

    Rails.logger.info "Processing item_added for cart: #{cart_id}, item: #{item_id}"
    Rails.logger.info "Cart metadata: #{cart_metadata}"

    if cart_metadata["price_type"] == "preferred_customer"
      Rails.logger.info "Applying subscription pricing to item #{item_id}"
      apply_subscription_pricing_to_item(cart_id, item_id, cart_item)
    end

    render json: { success: true }
  end

  def handle_subscription_added
    cart = callback_params[:cart]
    cart_item = callback_params[:cart_item]
    cart_id = cart&.dig("id")

    Rails.logger.info "Processing subscription_added for cart: #{cart_id}"
    Rails.logger.info "Subscription item added: #{cart_item&.dig('title')}"

    # When subscription is added, set the cart metadata to preferred_customer
    update_cart_metadata(cart_id, { "price_type" => "preferred_customer" })

    # Update all items in cart to subscription pricing
    update_all_cart_items_to_subscription_pricing(cart_id, cart)

    render json: { success: true }
  end

  def handle_subscription_removed
    cart = callback_params[:cart]
    cart_item = callback_params[:cart_item]
    cart_id = cart&.dig("id")

    Rails.logger.info "Processing subscription_removed for cart: #{cart_id}"
    Rails.logger.info "Subscription item removed: #{cart_item&.dig('title')}"

    # Reset cart metadata when subscription is removed
    update_cart_metadata(cart_id, { "price_type" => nil })

    # Update all items in cart to regular pricing
    update_all_cart_items_to_regular_pricing(cart_id, cart)

    render json: { success: true }
  end

  def fetch_customer_by_email(email)
    return nil if email.blank?

    client = FluidClient.new(current_company.authentication_token)
    response = client.customers.get(email: email)

    customers = response["customers"] || []
    customer = customers.first

    customer
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to fetch customer by email #{email}: #{e.message}"
    nil
  end

  def update_cart_metadata(cart_id, metadata)
    return if cart_id.blank?

    client = FluidClient.new(current_company.authentication_token)
    client.carts.update_metadata(cart_id, metadata)
    Rails.logger.info "Updated cart #{cart_id} metadata: #{metadata}"
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to update cart metadata for cart #{cart_id}: #{e.message}"
  end

  def apply_subscription_pricing_to_item(cart_id, item_id, cart_item = nil)
    return if cart_id.blank? || item_id.blank?

    client = FluidClient.new(current_company.authentication_token)

    # Build item data for subscription pricing
    item_data = [ {
      "id" => item_id,
      "price" => cart_item&.dig("subscription_price") || cart_item&.dig("price"),
      "subscription" => true,
    } ]

    client.carts.update_items_prices(cart_id, item_data)
    Rails.logger.info "Applied subscription pricing to item #{item_id} in cart #{cart_id}"
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to apply subscription pricing to item #{item_id}: #{e.message}"
  end

  def update_all_cart_items_to_subscription_pricing(cart_id, cart = nil)
    return if cart_id.blank?

    client = FluidClient.new(current_company.authentication_token)

    # Get cart items if not provided
    cart_items = cart&.dig("items") || client.carts.get_items(cart_id)

    # Build items data for subscription pricing
    items_data = client.carts.build_items_data_for_subscription_pricing(cart_items)

    client.carts.update_items_prices(cart_id, items_data)
    Rails.logger.info "Updated #{items_data.length} items in cart #{cart_id} to subscription pricing"
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to update cart items to subscription pricing for cart #{cart_id}: #{e.message}"
  end

  def update_all_cart_items_to_regular_pricing(cart_id, cart = nil)
    return if cart_id.blank?

    client = FluidClient.new(current_company.authentication_token)

    # Get cart items if not provided
    cart_items = cart&.dig("items") || client.carts.get_items(cart_id)

    # Build items data for regular pricing
    items_data = client.carts.build_items_data_for_regular_pricing(cart_items)

    client.carts.update_items_prices(cart_id, items_data)
    Rails.logger.info "Updated #{items_data.length} items in cart #{cart_id} to regular pricing"
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to update cart items to regular pricing for cart #{cart_id}: #{e.message}"
  end

  def valid_auth_token?(company)
    auth_header = request.headers["AUTH_TOKEN"] || request.headers["X-Auth-Token"] || request.env["HTTP_AUTH_TOKEN"]

    auth_header.present? && company.authentication_token == auth_header
  end

  def find_company
    Company.find_by(fluid_company_id: company_params[:fluid_company_id])
  end

  def callback_params
    params.permit!.to_h.with_indifferent_access
  end
end
