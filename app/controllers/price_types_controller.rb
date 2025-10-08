class PriceTypesController < ApplicationController
  def index
    @price_types = PriceType.order(:name)
  end
end
