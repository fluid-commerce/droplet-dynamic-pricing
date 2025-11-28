class Callbacks::VerifyEmailSuccessController < Callbacks::BaseController
private

  def service_class
    Callbacks::VerifyEmailSuccessService
  end
end
