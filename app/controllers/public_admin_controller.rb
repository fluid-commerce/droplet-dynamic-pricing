# frozen_string_literal: true

class PublicAdminController < ApplicationController
  layout "public_dashboard"
  skip_before_action :verify_authenticity_token
end
