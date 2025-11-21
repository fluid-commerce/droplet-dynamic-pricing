class CallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authenticate_callback_request

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
    cart_id = callback_params[:cart_id]

    Rails.logger.info "Processing verify_email_success for email: #{email}, cart: #{cart_id}"

    customer = fetch_customer_by_email(email)

    if customer && customer.dig("metadata", "customer_type") == "preferred_customer"
      update_cart_metadata(cart_id, { "price_type" => "preferred_customer" })
    end

    render json: { success: true }
  end

  def handle_cart_email_on_create
    email = callback_params[:email]
    cart_id = callback_params[:cart_id]

    Rails.logger.info "Processing cart_email_on_create for email: #{email}, cart: #{cart_id}"

    # Get customer by email and check if preferred_customer
    customer = fetch_customer_by_email(email)

    if customer && customer.dig("metadata", "customer_type") == "preferred_customer"
      update_cart_metadata(cart_id, { "price_type" => "preferred_customer" })
    end

    render json: { success: true }
  end

  def handle_item_added
    cart_id = callback_params[:cart_id]
    item_id = callback_params[:item_id]
    cart_metadata = callback_params.dig(:cart, :metadata) || {}

    Rails.logger.info "Processing item_added for cart: #{cart_id}, item: #{item_id}"

    # Check if cart has preferred_customer price_type
    if cart_metadata["price_type"] == "preferred_customer"
      apply_subscription_pricing_to_item(cart_id, item_id)
    end

    render json: { success: true }
  end

  def handle_subscription_added
    cart_id = callback_params[:cart_id]

    Rails.logger.info "Processing subscription_added for cart: #{cart_id}"

    update_cart_metadata(cart_id, { "price_type" => "preferred_customer" })

    update_all_cart_items_to_subscription_pricing(cart_id)

    render json: { success: true }
  end

  def handle_subscription_removed
    cart_id = callback_params[:cart_id]

    Rails.logger.info "Processing subscription_removed for cart: #{cart_id}"

    update_cart_metadata(cart_id, { "price_type" => nil })

    update_all_cart_items_to_regular_pricing(cart_id)

    render json: { success: true }
  end

  def fetch_customer_by_email(email)
    return nil if email.blank?

    client = FluidClient.new(current_company.authentication_token)
    # TODO: Implement customer lookup by email in FluidClient
    nil
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to fetch customer by email #{email}: #{e.message}"
    nil
  end

  def update_cart_metadata(cart_id, metadata)
    return if cart_id.blank?

    # TODO: Implement cart metadata update in FluidClient
    Rails.logger.info "Would update cart #{cart_id} metadata: #{metadata}"
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to update cart metadata for cart #{cart_id}: #{e.message}"
  end

  def apply_subscription_pricing_to_item(cart_id, item_id)
    return if cart_id.blank? || item_id.blank?

    # TODO: Implement single item price update
    Rails.logger.info "Would apply subscription pricing to item #{item_id} in cart #{cart_id}"
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to apply subscription pricing to item #{item_id}: #{e.message}"
  end

  def update_all_cart_items_to_subscription_pricing(cart_id)
    return if cart_id.blank?

    # TODO: Implement cart items price update using updatecartitemsprices endpoint
    Rails.logger.info "Would update all items in cart #{cart_id} to subscription pricing"
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to update cart items to subscription pricing for cart #{cart_id}: #{e.message}"
  end

  def update_all_cart_items_to_regular_pricing(cart_id)
    return if cart_id.blank?

    # TODO: Implement cart items price update using updatecartitemsprices endpoint
    Rails.logger.info "Would update all items in cart #{cart_id} to regular pricing"
  rescue FluidClient::Error => e
    Rails.logger.error "Failed to update cart items to regular pricing for cart #{cart_id}: #{e.message}"
  end

  def valid_auth_token?(company)
    # Check header auth token first, then fall back to params
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
