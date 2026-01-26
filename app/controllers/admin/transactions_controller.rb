class Admin::TransactionsController < AdminController
  before_action :set_current_company

  def index
    @per_page = 50
    @page = (params[:page] || 1).to_i
    @offset = (@page - 1) * @per_page

    @transactions = @company.customer_type_transactions
      .recent
      .limit(@per_page)
      .offset(@offset)

    @total_count = @company.customer_type_transactions.count
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
      total_preferred: @company.customer_type_transactions.upgraded_to_preferred.count,
      total_retail: @company.customer_type_transactions.downgraded_to_retail.count,
    }
  end
end
