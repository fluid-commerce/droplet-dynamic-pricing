# frozen_string_literal: true

class ExigoAutoshipSnapshot < ApplicationRecord
  belongs_to :company

  validate :external_ids_not_nil

  def external_ids_not_nil
    errors.add(:external_ids, "can't be nil") if external_ids.nil?
  end
  validates :synced_at, presence: true

  scope :latest_for_company, ->(company) { where(company: company).order(synced_at: :desc).first }
end
