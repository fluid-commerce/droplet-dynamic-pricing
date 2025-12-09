# frozen_string_literal: true

class IntegrationSetting < ApplicationRecord
  belongs_to :company

  validates :company_id, presence: true
end
