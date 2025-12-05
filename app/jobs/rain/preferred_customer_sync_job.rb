module Rain
  class PreferredCustomerSyncJob < ApplicationJob
    # before_perform :check_if_company_is_rain

    queue_as :default

    def perform
      rain_company

      unless rain_company.present?
        abort("Rain company not found")
      end



      get_customers_from_fluid_and_append_metadata(exigo_preferred_ids)
    end
  end

private

  def rain_company
    @rain_company ||= Company.find_by(fluid_company_id: ENV.fetch("RAIN_FLUID_COMPANY_ID", nil))
  end

  def fluid_client
    @fluid_client ||= FluidClient.new(rain_company.authentication_token)
  end

  def exigo_client
    @exigo_client ||= ExigoClient.new(rain_company.integration_setting.credentials)
  end

  # def company
  #   Company.find_by(fluid_company_id: ENV.fetch("RAIN_FLUID_COMPANY_ID", nil))
  # end

  def get_customers_from_fluid_and_append_metadata(exigo_preferred_ids)
    fluid_client.customers.get(country_code: %w[US CA]) do |customer|
      if exigo_preferred_ids.include?(customer["id"])
        # ask for batch update for metadata
        fluid_client.customers.append_metadata(customer["id"], { "customer_type" => "preferred" })
      end
    end
  end






  # def check_if_company_is_rain


  #   rain_company_id = ENV.fetch("RAIN_FLUID_COMPANY_ID", nil)
  #   Rails.logger.info("Rain company id: #{rain_company_id}")
  #   droplet_company_id = company&.fluid_company_id
  #   Rails.logger.info("Droplet company id: #{droplet_company_id}")

  #   unless droplet_company_id.present?
  #     abort("Droplet company id not found")
  #   end

  #   unless rain_company_id.present?
  #     abort("Rain company id not found")
  #   end

  #   unless droplet_company_id == rain_company_id
  #     abort("Droplet company id does not match rain company id")
  #   end

  #   true
  # end

  def abort(message)
    Rails.logger.error(message)
    throw(:abort)
  end
end
