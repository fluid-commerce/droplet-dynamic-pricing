class CreatePriceTypes < ActiveRecord::Migration[8.0]
  def change
    create_table :price_types do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end

    add_index :price_types, [:company_id, :name], unique: true
  end
end
