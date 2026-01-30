class CreateCustomerTypeTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :customer_type_transactions do |t|
      t.references :company, null: false, foreign_key: true
      t.integer :customer_id
      t.string :external_id
      t.string :previous_type
      t.string :new_type
      t.string :source
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :customer_type_transactions, %i[company_id created_at]
    add_index :customer_type_transactions, :external_id
    add_index :customer_type_transactions, :customer_id
  end
end
