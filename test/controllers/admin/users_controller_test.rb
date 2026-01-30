require "test_helper"

describe Admin::UsersController do
  describe "authentication" do
    it "requires authentication" do
      get admin_users_path

      must_respond_with :redirect
      assert_redirected_to new_user_session_path
    end

    it "allows access when authenticated" do
      sign_in users(:admin)
      get admin_users_path
      must_respond_with :success
    end
  end
end
