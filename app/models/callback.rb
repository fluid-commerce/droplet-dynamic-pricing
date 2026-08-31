# frozen_string_literal: true

class Callback < ApplicationRecord
  # Public: Whether this app has a POST route for the given callback URL.
  #
  # Asks the real router rather than matching a list, so adding a Callbacks::
  # route makes it enable-able with no change here.
  #
  # url - The String URL a Fluid registration would be pointed at.
  #
  # Returns a Boolean.
  def self.serves?(url)
    path = URI.parse(url).path
    return false if path.blank?

    Rails.application.routes.recognize_path(path, method: :post)
    true
  rescue URI::InvalidURIError, ActionController::RoutingError
    false
  end

  validates :name, presence: true, uniqueness: true
  validates :description, presence: true
  validates :timeout_in_seconds, numericality: { greater_than: 0, less_than_or_equal_to: 20, only_integer: true },
 allow_nil: true

  validate :validate_active_requirements

  scope :active, -> { where(active: true) }

private

  def validate_active_requirements
    return unless active?

    if url.blank?
      errors.add(:active, "cannot be enabled without a URL")
    end

    if timeout_in_seconds.blank?
      errors.add(:active, "cannot be enabled without a timeout")
    end

    validate_url_is_served
  end

  # Internal: Refuse to enable a callback this app cannot answer.
  #
  # CallbackSyncService imports EVERY definition Fluid offers, so the admin
  # list includes names this droplet has no handler for. Enabling one registered
  # a URL in Fluid that 404s on arrival, and Fluid alerted on every dispatch
  # until someone noticed — that is how TM3's verify_email_success registration
  # (Fluid reg 1410) came to exist.
  #
  # The route table is the authority rather than a hand-kept list of names,
  # because the name Fluid uses and the path this app serves are allowed to
  # differ: cart_customer_logged_in is answered at /callbacks/customer_logged_in.
  # So the URL is what gets checked, not the name.
  #
  # Returns nothing.
  def validate_url_is_served
    return if url.blank?
    return if self.class.serves?(url)

    errors.add(:url, "is not a path this droplet serves, so Fluid's callback would 404")
  end
end
