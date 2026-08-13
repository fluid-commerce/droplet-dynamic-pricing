# frozen_string_literal: true

# Reporting only, never raised to the caller. See
# Callbacks::BaseService#refuse_cross_country_price (STU2-3108).
class CrossCountryPriceError < StandardError
end
