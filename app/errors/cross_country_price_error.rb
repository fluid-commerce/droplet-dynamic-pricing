# frozen_string_literal: true

# Raised (for reporting only, never to the caller) when a callback payload
# carries a price that belongs to a different country's variant row than the
# cart's. See Callbacks::BaseService#guarded_payload_price (STU2-3108).
class CrossCountryPriceError < StandardError
end
