class CustomerTypeTransaction < ApplicationRecord
  belongs_to :company

  validates :company_id, presence: true
  validates :new_type, presence: true
  validates :source, presence: true

  # Sources: 'sync_job', 'webhook', 'callback', 'manual'
  enum :source, {
    sync_job: "sync_job",
    webhook: "webhook",
    callback: "callback",
    manual: "manual",
  }, prefix: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_customer, ->(customer_id) { where(customer_id: customer_id) }
  scope :for_external_id, ->(external_id) { where(external_id: external_id) }
  scope :upgraded_to_preferred, -> { where(new_type: "preferred_customer") }
  scope :downgraded_to_retail, -> { where(new_type: "retail") }

  def upgraded?
    new_type == "preferred_customer"
  end

  def downgraded?
    new_type == "retail"
  end

  def type_changed?
    previous_type != new_type
  end
end
