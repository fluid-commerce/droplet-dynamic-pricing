class Callbacks::CartEmailOnCreateController < Callbacks::BaseController
private

  def service_class
    Callbacks::CartEmailOnCreateService
  end
end
