class Callbacks::BaseController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    started_at = monotonic_now
    result = service_class.call(callback_params)
    log_timing(started_at, outcome: result[:success] ? "ok" : "rejected")

    if result[:success]
      render json: result
    else
      render json: result, status: :bad_request
    end
  rescue ActionController::ParameterMissing => e
    log_timing(started_at, outcome: "invalid_payload")
    Rails.logger.error "Callback error for #{self.class.name}: #{e.message}"
    render json: { success: false, error: e.message }, status: :bad_request
  rescue StandardError => e
    log_timing(started_at, outcome: "error")
    Rails.logger.error "Callback error for #{self.class.name}: #{e.message}"
    render json: { success: false, error: e.message }, status: :internal_server_error
  end

private

  # One greppable line per callback. These are the requests the shopper's
  # add-to-cart is blocked on, and none of them was measured before, so there was
  # no way to say which callback spends the budget or how close to Fluid's 20s
  # cut-off it runs.
  #
  # Best-effort by construction: instrumentation must never be the reason a
  # callback fails, and it reads the raw params rather than permitted_params
  # because the invalid-payload path is exactly one of the cases worth timing.
  def log_timing(started_at, outcome:)
    return if started_at.nil?
    # Latched: log_timing runs before render, so a render that raises would reach
    # the rescue below and emit a SECOND line for the same request — one ok, one
    # error — double-counting anything that aggregates by outcome.
    return if @timing_logged

    @timing_logged = true

    duration_ms = ((monotonic_now - started_at) * 1000).round

    Rails.logger.info(
      "[DynamicPricing] marker=callback-timing callback=#{timing_callback_name} " \
      "outcome=#{outcome} duration_ms=#{duration_ms} cart=#{timing_cart_token.inspect}"
    )
  rescue StandardError => e
    Rails.logger.warn "[DynamicPricing] failed to log callback timing: #{e.message}"
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def timing_callback_name
    self.class.name.demodulize.sub(/Controller\z/, "").underscore
  end

  def timing_cart_token
    params.dig(:cart, :cart_token) || params.dig(:cart, :token)
  end

  def service_class
    raise NotImplementedError, "Subclasses must implement service_class method"
  end

  def permitted_params
    raise NotImplementedError, "Subclasses must implement permitted_params method"
  end

  def callback_params
    permitted_params.to_h.with_indifferent_access
  end

  # A batched callback (Fluid's BATCH_CART_ITEM_CALLBACKS) may carry the
  # items it speaks for as a top-level cart_items array of item objects.
  # permit's empty-hash filter only passes hashes, so the array is permitted
  # per element — the same accept-anything trust the cart and cart_item
  # objects already get. filter_map: a malformed member (null, a scalar) is
  # dropped rather than raising NoMethodError out of the params layer as a
  # 500. Stated here once so every cart callback treats the field the same
  # way.
  def permit_batch_cart_items(permitted)
    batch_items = params[:cart_items]
    return permitted unless batch_items.is_a?(Array)

    permitted[:cart_items] = batch_items.filter_map { |item| item.permit!.to_h if item.respond_to?(:permit!) }
    permitted
  end
end
