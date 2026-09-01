# frozen_string_literal: true

class Callback < ApplicationRecord
  normalizes :url, with: ->(url) { url.strip }

  # Public: Fluid's callback definition name -> the path this droplet answers
  # it on. The two are allowed to differ, and do: Fluid dispatches
  # cart_customer_logged_in to /callbacks/customer_logged_in.
  #
  # This is the list an install registers. Before it existed, registration read
  # whatever rows happened to be active in the table, and the table was filled
  # by CallbackSyncService — which imports every definition Fluid offers as
  # inactive and leaves an operator to activate each one by hand. Anything
  # nobody clicked was simply never registered, which is how a droplet that has
  # answered cart_customer_attached and cart_customer_detached all along was
  # never sent either one.
  SERVED_PATHS = {
    "cart_country_changed"      => "/callbacks/cart_country_changed",
    "cart_customer_attached"    => "/callbacks/cart_customer_attached",
    "cart_customer_detached"    => "/callbacks/cart_customer_detached",
    "cart_customer_logged_in"   => "/callbacks/customer_logged_in",
    "cart_email_on_create"      => "/callbacks/cart_email_on_create",
    "cart_item_added"           => "/callbacks/cart_item_added",
    "cart_item_updated"         => "/callbacks/cart_item_updated",
    "cart_subscription_added"   => "/callbacks/subscription_added",
    "cart_subscription_removed" => "/callbacks/subscription_removed",
  }.freeze

  # Matches what the deployed registrations carry. Fluid abandons the callback
  # at this deadline, so it is the shopper's budget, not ours.
  DEFAULT_TIMEOUT_IN_SECONDS = 5

  # Public: Make sure this droplet has a row for every callback it answers, so
  # an install registers all of them rather than whatever someone remembered to
  # activate.
  #
  # A row with a URL was set up by somebody, so its active flag, URL and
  # timeout are left alone — an operator who tuned a timeout or deliberately
  # turned one off is not overruled by the next install.
  #
  # A row WITHOUT a URL was imported by CallbackSyncService, which writes only
  # the name and description and leaves everything else nil. That is the shape
  # every deployed environment is already in, so treating it as "already
  # exists" would configure nothing and register nothing.
  #
  # Returns nothing.
  def self.ensure_served!
    base_url = Setting.host_server&.values&.dig("base_url")
    return if base_url.blank?

    SERVED_PATHS.each do |name, path|
      callback = find_or_initialize_by(name: name)
      next if callback.url.present?

      callback.description = "Answered by this droplet at #{path}" if callback.description.blank?
      callback.url = "#{base_url.chomp('/')}#{path}"
      callback.timeout_in_seconds ||= DEFAULT_TIMEOUT_IN_SECONDS
      callback.active = true
      callback.save
    end
  end

  # Public: Whether this droplet answers callbacks at the given URL.
  #
  # True only when all three hold: the URL is absolute http(s), its host is
  # this droplet's own (served_host, when configured), and the real router
  # recognizes the path as a POST to a Callbacks:: controller. Asking the
  # router rather than matching a hand-kept list means adding a Callbacks::
  # route makes it enable-able with no change here.
  #
  # url - The String URL a Fluid registration would be pointed at.
  #
  # Returns a Boolean.
  def self.serves?(url)
    uri = URI.parse(url.to_s)
    return false unless uri.is_a?(URI::HTTP) && uri.host.present?
    return false unless served_host.nil? || uri.host == served_host

    recognized = Rails.application.routes.recognize_path(uri.path, method: :post)
    recognized[:controller].to_s.start_with?("callbacks/")
  rescue URI::InvalidURIError, ActionController::RoutingError
    false
  end

  # Public: The host Fluid must dispatch to for a callback to reach this
  # droplet, read from Setting.host_server.base_url — the same source the
  # install job uses to build webhook URLs.
  #
  # Returns a String host, or nil when the setting is absent or unparseable.
  def self.served_host
    return nil unless Setting.respond_to?(:host_server)

    URI.parse(Setting.host_server&.values&.dig("base_url").to_s).host
  rescue URI::InvalidURIError
    nil
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
  # So the URL is what gets checked, not the name. The check also refuses a
  # host other than this droplet's own, because a registration for a stale or
  # foreign host 404s in production no matter how valid its path looks here.
  #
  # Returns nothing.
  def validate_url_is_served
    return if url.blank?
    return if self.class.serves?(url)

    errors.add(:url, "is not a callback URL this droplet serves, so Fluid's dispatch would fail")
  end
end
