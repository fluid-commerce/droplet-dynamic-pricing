require "test_helper"

describe Admin::CallbacksController do
  describe "authentication" do
    it "requires authentication for index" do
      get admin_callbacks_url

      must_respond_with :redirect
      assert_redirected_to new_user_session_path
    end

    it "requires authentication for show" do
      # No sign_in call - should redirect to login
      callback = callbacks(:one)

      get admin_callback_url(callback)

      must_respond_with :redirect
      assert_redirected_to new_user_session_path
    end

    it "allows access when authenticated" do
      sign_in users(:admin)
      get admin_callbacks_url
      must_respond_with :success
    end
  end

  describe "with authentication" do
    before do
      sign_in users(:admin)
    end

    it "gets index" do
      get admin_callbacks_url
      must_respond_with :success
    end

    it "gets show" do
      callback = callbacks(:one)
      get admin_callback_url(callback)
      must_respond_with :success
    end

    it "gets edit" do
      callback = callbacks(:one)
      get edit_admin_callback_url(callback)
      must_respond_with :success
    end

    it "gets update" do
      callback = callbacks(:one)
      patch admin_callback_url(callback), params: {
        callback: {
          url: "https://example.com/updated-callback",
          timeout_in_seconds: 15,
          active: true,
        },
      }
      must_respond_with :redirect
    end

    it "posts sync" do
      post sync_admin_callbacks_url
      must_respond_with :redirect
    end
  end
end
