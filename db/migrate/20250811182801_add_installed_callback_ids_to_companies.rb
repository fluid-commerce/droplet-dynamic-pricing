class AddInstalledCallbackIdsToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :installed_callback_ids, :jsonb, default: [] unless column_exists?(:companies, :installed_callback_ids)
  end
end
