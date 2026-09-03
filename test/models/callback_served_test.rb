require "test_helper"

describe "Callback.ensure_served!" do
  BASE_URL = "https://droplet.example.com"

  before do
    Tasks::Settings.create_defaults
    Callback.delete_all
    # The test fixture leaves base_url empty, and ensure_served! deliberately
    # no-ops without a host — see the last example.
    Setting.find_by(name: "host_server").update!(values: { "base_url" => BASE_URL })
  end

  def base_host
    URI.parse(BASE_URL).host
  end

  it "creates a row for every callback this droplet answers" do
    Callback.ensure_served!

    _(Callback.pluck(:name).sort).must_equal Callback::SERVED_PATHS.keys.sort
  end

  # The two the droplet has always been able to answer but was never registered
  # for: cart_customer_attached/detached had routes and services, and no rows,
  # so no install ever registered them.
  it "includes the cart customer attach and detach callbacks" do
    Callback.ensure_served!

    _(Callback.active.pluck(:name)).must_include "cart_customer_attached"
    _(Callback.active.pluck(:name)).must_include "cart_customer_detached"
  end

  it "points each row at the path this droplet serves it on" do
    Callback.ensure_served!

    # Fluid's name and the path can differ: cart_customer_logged_in is answered
    # at /callbacks/customer_logged_in.
    url = Callback.find_by(name: "cart_customer_logged_in").url

    _(URI.parse(url).path).must_equal "/callbacks/customer_logged_in"
    _(URI.parse(url).host).must_equal base_host
  end

  it "builds URLs this droplet actually serves" do
    Callback.ensure_served!

    Callback.find_each { |callback| assert Callback.serves?(callback.url), "#{callback.name} -> #{callback.url}" }
  end

  it "activates them with a timeout, which activation requires" do
    Callback.ensure_served!

    _(Callback.where(active: true).count).must_equal Callback::SERVED_PATHS.size
    _(Callback.pluck(:timeout_in_seconds).uniq).must_equal [ Callback::DEFAULT_TIMEOUT_IN_SECONDS ]
  end

  it "is idempotent" do
    Callback.ensure_served!
    before_count = Callback.count

    Callback.ensure_served!

    _(Callback.count).must_equal before_count
  end

  # An operator who tuned a timeout or deliberately turned one off should not
  # have it reset by the next install.
  # The real production shape: CallbackSyncService has already imported every
  # definition Fluid offers as an inactive row with no URL and no timeout.
  # Skipping those as "already exists" would register nothing at all.
  it "configures and activates a row the sync imported but nobody set up" do
    Callback.create!(name: "cart_customer_detached", description: "imported by sync", active: false)

    Callback.ensure_served!

    imported = Callback.find_by(name: "cart_customer_detached")
    assert imported.active
    _(URI.parse(imported.url).path).must_equal "/callbacks/cart_customer_detached"
    _(imported.timeout_in_seconds).must_equal Callback::DEFAULT_TIMEOUT_IN_SECONDS
  end

  it "leaves an existing row's timeout alone" do
    Callback.create!(
      name: "cart_item_added",
      description: "existing",
      url: "#{BASE_URL}/callbacks/cart_item_added",
      timeout_in_seconds: 12,
      active: true
    )

    Callback.ensure_served!

    _(Callback.find_by(name: "cart_item_added").timeout_in_seconds).must_equal 12
  end

  it "leaves a deliberately deactivated row deactivated" do
    Callback.create!(
      name: "cart_item_updated",
      description: "existing",
      url: "#{BASE_URL}/callbacks/cart_item_updated",
      timeout_in_seconds: 5,
      active: false
    )

    Callback.ensure_served!

    refute Callback.find_by(name: "cart_item_updated").active
  end

  # The counterpart of creating what we serve. validate_url_is_served refuses to
  # SAVE such a row as active, but rows activated before that validation existed
  # are still in the table active — which is how the droplet's own list claimed
  # verify_email_success was on long after its route was deleted.
  #
  # Route-based on purpose, like serves? itself: deleting a Callbacks:: route is
  # what retires a callback, with no second list to remember to edit.
  it "deactivates an active row whose URL it no longer serves" do
    stale = Callback.create!(
      name: "verify_email_success",
      description: "route deleted after activation",
      url: "#{BASE_URL}/callbacks/cart_item_added",
      timeout_in_seconds: 5,
      active: true
    )
    stale.update_column(:url, "#{BASE_URL}/callbacks/verify_email_success")

    Callback.ensure_served!

    refute stale.reload.active, "a row this droplet cannot answer must not stay active"
  end

  it "leaves an active row it does serve alone" do
    served = Callback.create!(
      name: "cart_item_added",
      description: "served",
      url: "#{BASE_URL}/callbacks/cart_item_added",
      timeout_in_seconds: 5,
      active: true
    )

    Callback.ensure_served!

    assert served.reload.active
  end

  # Already off is already correct: no write, and the row keeps the shape the
  # sync gave it so a later host change can still configure it.
  it "leaves an already inactive stale row untouched" do
    stale = Callback.create!(name: "verify_email_success", description: "catalogue", active: false)

    Callback.ensure_served!

    refute stale.reload.active
    _(stale.reload.url).must_be_nil
  end

  it "does nothing when the host is not configured yet" do
    Setting.find_by(name: "host_server").update!(values: { "base_url" => "" })

    Callback.ensure_served!

    _(Callback.count).must_equal 0
  end
end
