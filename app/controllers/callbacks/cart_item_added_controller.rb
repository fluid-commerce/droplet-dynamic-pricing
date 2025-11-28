class Callbacks::CartItemAddedController < Callbacks::BaseController
private

  def service_class
    Callbacks::CartItemAddedService
  end
end
