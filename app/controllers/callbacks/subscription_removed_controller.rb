class Callbacks::SubscriptionRemovedController < Callbacks::BaseController
private

  def service_class
    Callbacks::SubscriptionRemovedService
  end
end
