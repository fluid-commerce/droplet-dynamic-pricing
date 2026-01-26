class Admin::CartPricingEventsController < AdminController
  before_action :set_current_company

  def index
    @per_page = 50
    @page = (params[:page] || 1).to_i
    @offset = (@page - 1) * @per_page

    @events = @company.cart_pricing_events
      .recent
      .limit(@per_page)
      .offset(@offset)

    @total_count = @company.cart_pricing_events.count
    @total_pages = (@total_count.to_f / @per_page).ceil

    @stats = calculate_stats
  end

private

  def set_current_company
    @company = Company.find_by(droplet_installation_uuid: @dri)

    unless @company
      redirect_to admin_dashboard_index_path, alert: "Company not found"
    end
  end

  def calculate_stats
    {
      preferred_applied_count: @company.cart_pricing_events.applied_preferred.count,
      total_events: @company.cart_pricing_events.count,
    }
  end
end
