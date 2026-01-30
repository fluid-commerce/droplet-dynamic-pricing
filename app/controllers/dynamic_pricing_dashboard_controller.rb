class DynamicPricingDashboardController < ApplicationController
  skip_before_action :verify_authenticity_token
  layout "public_dashboard"
  before_action :set_current_company

  def index
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
