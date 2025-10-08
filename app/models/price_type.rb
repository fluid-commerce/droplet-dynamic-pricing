class PriceType < ApplicationRecord
  belongs_to :company

  validates :name, presence: true
  validates :name, uniqueness: { scope: :company_id, case_sensitive: false }
end
