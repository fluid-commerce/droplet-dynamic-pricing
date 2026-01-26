# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_01_26_194025) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "callbacks", force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.string "url"
    t.integer "timeout_in_seconds"
    t.boolean "active"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "cart_pricing_events", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.integer "cart_id"
    t.string "email"
    t.string "event_type"
    t.boolean "preferred_pricing_applied", default: false
    t.integer "items_count"
    t.decimal "cart_total", precision: 10, scale: 2
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cart_id"], name: "index_cart_pricing_events_on_cart_id"
    t.index ["company_id", "created_at"], name: "index_cart_pricing_events_on_company_id_and_created_at"
    t.index ["company_id"], name: "index_cart_pricing_events_on_company_id"
    t.index ["email"], name: "index_cart_pricing_events_on_email"
  end

  create_table "companies", force: :cascade do |t|
    t.string "fluid_shop", null: false
    t.string "authentication_token", null: false
    t.string "name", null: false
    t.jsonb "settings", default: {}
    t.string "webhook_verification_token"
    t.bigint "fluid_company_id", null: false
    t.string "service_company_id"
    t.string "company_droplet_uuid"
    t.boolean "active", default: false
    t.datetime "uninstalled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "droplet_installation_uuid"
    t.jsonb "installed_callback_ids", default: []
    t.index ["active"], name: "index_companies_on_active"
    t.index ["authentication_token"], name: "index_companies_on_authentication_token", unique: true
    t.index ["company_droplet_uuid"], name: "index_companies_on_company_droplet_uuid"
    t.index ["fluid_company_id"], name: "index_companies_on_fluid_company_id"
    t.index ["fluid_shop"], name: "index_companies_on_fluid_shop"
  end

  create_table "customer_type_transactions", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.integer "customer_id"
    t.string "external_id"
    t.string "previous_type"
    t.string "new_type"
    t.string "source"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "created_at"], name: "index_customer_type_transactions_on_company_id_and_created_at"
    t.index ["company_id"], name: "index_customer_type_transactions_on_company_id"
    t.index ["customer_id"], name: "index_customer_type_transactions_on_customer_id"
    t.index ["external_id"], name: "index_customer_type_transactions_on_external_id"
  end

  create_table "events", force: :cascade do |t|
    t.string "identifier"
    t.string "name"
    t.jsonb "payload", default: {}
    t.datetime "timestamp"
    t.integer "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "company_id", null: false
    t.index ["company_id"], name: "index_events_on_company_id"
    t.index ["identifier"], name: "index_events_on_identifier"
    t.index ["name"], name: "index_events_on_name"
  end

  create_table "exigo_autoship_snapshots", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.json "external_ids", default: [], null: false
    t.datetime "synced_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "synced_at"], name: "index_exigo_autoship_snapshots_on_company_id_and_synced_at"
    t.index ["company_id"], name: "index_exigo_autoship_snapshots_on_company_id"
  end

  create_table "integration_settings", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.boolean "enabled", default: false
    t.jsonb "settings", default: {}
    t.jsonb "credentials", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_integration_settings_on_company_id"
  end

  create_table "price_types", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "name"], name: "index_price_types_on_company_id_and_name", unique: true
    t.index ["company_id"], name: "index_price_types_on_company_id"
  end

  create_table "settings", force: :cascade do |t|
    t.string "name", null: false
    t.string "description"
    t.jsonb "values", default: {}
    t.jsonb "schema", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_settings_on_name", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "permission_sets", default: [], array: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "webhooks", force: :cascade do |t|
    t.string "resource"
    t.string "event"
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "cart_pricing_events", "companies"
  add_foreign_key "customer_type_transactions", "companies"
  add_foreign_key "events", "companies"
  add_foreign_key "exigo_autoship_snapshots", "companies"
  add_foreign_key "integration_settings", "companies"
  add_foreign_key "price_types", "companies"
end
