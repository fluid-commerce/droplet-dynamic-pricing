class CallbackSyncService
  def initialize
    @client = FluidClient.new(Setting.fluid_api.api_key)
  end

  def sync
    begin
      response = @client.callback_definitions.get

      if response&.dig("definitions")&.any?
        sync_callbacks(response["definitions"])
        { success: true, message: "Successfully synced #{response['definitions'].length} callbacks" }
      else
        { success: false, message: "No callback definitions found" }
      end
    rescue => e
      Rails.logger.error "Callback sync failed: #{e.message}"
      { success: false, message: "Sync failed: #{e.message}" }
    end
  end

private

  def sync_callbacks(definitions)
    definitions.each do |definition|
      create_or_update_callback(definition)
    end
  end

  # A sync imports Fluid's whole catalogue, most of which this droplet has no
  # handler for, so a NEW row arrives switched off. An existing row keeps its
  # active flag, URL and timeout: reassigning active: false here switched off
  # every callback an install had turned on, and the droplet stopped receiving
  # them with nothing logged.
  def create_or_update_callback(definition)
    callback = Callback.find_or_initialize_by(name: definition["name"])

    callback.description = definition["description"]
    callback.active = false unless callback.persisted?

    callback.save!
  rescue => e
    Rails.logger.error "Failed to sync callback #{definition['name']}: #{e.message}"
  end
end
