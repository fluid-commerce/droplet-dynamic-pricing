class DynamicPricingDashboardController < ApplicationController
  ALLOWED_TABS = %w[cart_events transactions].freeze
  PER_PAGE = 10

  skip_before_action :verify_authenticity_token
  layout "public_dashboard"
  before_action :set_current_company

  def index
    @per_page   = PER_PAGE
    @page       = [ (params[:page] || 1).to_i, 1 ].max
    @offset     = (@page - 1) * @per_page
    @active_tab = ALLOWED_TABS.include?(params[:tab]) ? params[:tab] : "cart_events"

    if @active_tab == "cart_events"
      @cart_pricing_events = @company.cart_pricing_events.recent.limit(@per_page).offset(@offset)
      @transactions        = @company.customer_type_transactions.recent.limit(@per_page)
    else
      @cart_pricing_events = @company.cart_pricing_events.recent.limit(@per_page)
      @transactions        = @company.customer_type_transactions.recent.limit(@per_page).offset(@offset)
    end

    @cart_total_count = @company.cart_pricing_events.count
    @tx_total_count   = @company.customer_type_transactions.count

    @stats = calculate_stats
  end

private

  def set_current_company
    @company = Company.find_by(droplet_installation_uuid: @dri)

    unless @company
      render plain: "Company not found", status: :not_found
    end
  end

  def calculate_stats
    {
      # Customer Type Transactions stats
      total_preferred: @company.customer_type_transactions.upgraded_to_preferred.count,
      total_retail: @company.customer_type_transactions.downgraded_to_retail.count,

      # Cart Pricing Events stats
      preferred_pricing_applied: @company.cart_pricing_events.applied_preferred.count,
      total_cart_events: @company.cart_pricing_events.count,
    }
  end
end
