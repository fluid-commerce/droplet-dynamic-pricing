# frozen_string_literal: true

# Base controller for public admin views that don't require authentication
class PublicAdminController < ApplicationController
  layout "admin"
end
