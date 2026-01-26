class CreateCartPricingEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :cart_pricing_events do |t|
      t.references :company, null: false, foreign_key: true
      t.integer :cart_id
      t.string :email
      t.string :event_type
      t.boolean :preferred_pricing_applied, default: false
      t.integer :items_count
      t.decimal :cart_total, precision: 10, scale: 2
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :cart_pricing_events, %i[company_id created_at]
    add_index :cart_pricing_events, :cart_id
    add_index :cart_pricing_events, :email
  end
end
