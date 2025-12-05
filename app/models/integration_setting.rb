# frozen_string_literal: true

class IntegrationSetting < ApplicationRecord
  belongs_to :company

  encrypts :settings, deterministic: true
  encrypts :credentials, deterministic: true

  validates :company_id, presence: true
end
