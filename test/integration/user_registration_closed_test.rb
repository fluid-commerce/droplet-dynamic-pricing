require "test_helper"

# Public sign-up is closed: any account that can sign in gets the full admin UI,
# so a self-registration route would hand admin to anyone who found it. Staff
# sign-in, sign-out and password reset must keep working.
describe "User registration is closed", :integration do
  it "has no sign-up page" do
    get "/users/sign_up"

    must_respond_with :not_found
  end

  it "does not create a user from a registration POST" do
    params = {
      user: {
        email: "outsider@example.com",
        password: "password123456",
        password_confirmation: "password123456",
      },
    }

    assert_no_difference -> { User.count } do
      post "/users", params: params
    end

    must_respond_with :not_found
    _(User.exists?(email: "outsider@example.com")).must_equal false
  end

  it "has no edit or cancel registration routes" do
    %w[/users/edit /users/cancel].each do |path|
      get path
      must_respond_with :not_found
    end

    %i[patch put delete].each do |verb|
      send(verb, "/users")
      must_respond_with :not_found
    end
  end

  it "defines no registration route helpers" do
    # Routes load lazily outside CI (eager_load is off), and method_defined?
    # does not trigger the load, so force it and prove helpers exist at all.
    Rails.application.reload_routes_unless_loaded
    helpers = Rails.application.routes.url_helpers

    _(helpers.method_defined?(:new_user_session_path)).must_equal true
    _(helpers.method_defined?(:new_user_registration_path)).must_equal false
    _(helpers.method_defined?(:user_registration_path)).must_equal false
  end

  # Either layer alone closes the routes (devise_for only draws routes for the
  # model's modules, and skip: drops them regardless), so each is pinned here
  # directly: re-adding one must not be silently covered by the other.
  it "keeps User out of Devise's registerable module" do
    _(User.devise_modules).wont_include :registerable
  end

  # devise_for only draws routes for the model's modules, so `skip:` is only
  # observable while User is registerable. Redraw the real config/routes.rb with
  # the module put back to prove the route layer holds on its own.
  it "skips registration routes for users even if the model regains registerable" do
    original_modules = User.devise_modules.dup
    User.devise_modules |= [ :registerable ]
    Rails.application.reload_routes!

    _(Devise.mappings[:user].used_routes).wont_include :registration
    _(Rails.application.routes.url_helpers.method_defined?(:new_user_registration_path)).must_equal false
  ensure
    User.devise_modules = original_modules if original_modules
    Rails.application.reload_routes!
  end

  it "still serves the sign-in page" do
    get new_user_session_path

    must_respond_with :success
  end

  it "still serves the password reset page" do
    get new_user_password_path

    must_respond_with :success
  end

  it "lets an existing user sign in, reach the admin UI, and sign out" do
    user = users(:admin)
    user.update!(password: "staff-password-123", password_confirmation: "staff-password-123")

    post user_session_path, params: { user: { email: user.email, password: "staff-password-123" } }
    must_redirect_to admin_dashboard_index_path

    get admin_dashboard_index_path
    must_respond_with :success

    get admin_callbacks_url
    must_respond_with :success

    delete destroy_user_session_path
    get admin_callbacks_url
    assert_redirected_to new_user_session_path
  end
end
