# frozen_string_literal: true

class ExigoAutoshipSnapshot < ApplicationRecord
  belongs_to :company

  validates :external_ids, presence: true
  validates :synced_at, presence: true

  def self.latest_for_company(company)
    where(company: company).order(synced_at: :desc).first
  end
end
