class CartPricingEvent < ApplicationRecord
  belongs_to :company

  validates :company_id, presence: true
  validates :cart_id, presence: true
  validates :event_type, presence: true

  # Event types: 'cart_created', 'item_added', 'item_updated'
  enum :event_type, {
    cart_created: "cart_created",
    item_added: "item_added",
    item_updated: "item_updated",
  }, prefix: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_cart, ->(cart_id) { where(cart_id: cart_id) }
  scope :applied_preferred, -> { where(preferred_pricing_applied: true) }

  def email_safe
    return nil if email.blank?
    email.gsub(/(?<=.{2}).(?=.*@)/, "*")
  end
end
