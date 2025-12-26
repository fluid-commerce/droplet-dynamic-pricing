# frozen_string_literal: true

class CreateExigoAutoshipSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :exigo_autoship_snapshots do |t|
      t.references :company, null: false, foreign_key: true
      t.json :external_ids, null: false, default: []
      t.datetime :synced_at, null: false

      t.timestamps
    end

    add_index :exigo_autoship_snapshots, %i[company_id synced_at]
  end
end
