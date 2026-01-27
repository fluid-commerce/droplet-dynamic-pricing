require "test_helper"

describe Admin::DashboardController do
  describe "authentication" do
    it "requires authentication" do
      get admin_dashboard_index_url

      must_respond_with :redirect
      assert_redirected_to new_user_session_path
    end

    it "allows access when authenticated" do
      Tasks::Settings.create_defaults

      sign_in users(:admin)
      get admin_dashboard_index_url
      must_respond_with :success
    end
  end
end
