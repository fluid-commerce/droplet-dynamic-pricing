class Company < ApplicationRecord
  has_many :events, dependent: :destroy
  has_many :price_types, dependent: :destroy
  has_many :customer_type_transactions, dependent: :destroy
  has_many :cart_pricing_events, dependent: :destroy

  has_one :integration_setting, dependent: :destroy

  validates :fluid_shop, :authentication_token, :name, :fluid_company_id, :company_droplet_uuid, presence: true
  validates :authentication_token, uniqueness: true

  scope :active, -> { where(active: true) }

  after_initialize :set_default_installed_callback_ids, if: :new_record?

private

  def set_default_installed_callback_ids
    self.installed_callback_ids ||= []
  end
end
