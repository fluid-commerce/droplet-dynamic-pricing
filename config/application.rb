require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module DropletTemplate
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    config.generators do |g|
      g.test_framework :minitest, spec: true, fixture: true
      g.helper false
      g.assets false
    end

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets])

    config.action_view.field_error_proc = Proc.new { |html_tag, instance|
      "<span class='text-orange-600'>#{html_tag}</span>".html_safe
    }

    config.session_store :cookie_store,
      key: "_droplet_dynamic_pricing_session",
      secure: Rails.env.production?,
      httponly: true,
      same_site: Rails.env.production? ? :none : :lax
  end
end
