require "test_helper"

describe Admin::SettingsController do
  fixtures(:settings)

  describe "authentication" do
    it "requires authentication for index" do
      get admin_settings_path

      must_respond_with :redirect
      assert_redirected_to new_user_session_path
    end

    it "requires authentication for edit" do
      setting = settings(:droplet)

      get edit_admin_setting_path(setting)

      must_respond_with :redirect
      assert_redirected_to new_user_session_path
    end

    it "allows access when authenticated" do
      sign_in users(:admin)
      get admin_settings_path
      must_respond_with :success
    end
  end
end
