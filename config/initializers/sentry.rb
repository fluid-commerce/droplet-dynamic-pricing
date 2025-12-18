# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.traces_sample_rate = 1.0
  config.breadcrumbs_logger = %i[ active_support_logger http_logger ]
  config.send_default_pii = true
end
