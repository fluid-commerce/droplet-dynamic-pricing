require "test_helper"

# A flat per-call timeout cannot tell "hung" from "slow but about to answer",
# so any value tight enough to survive a hang also kills calls that would have
# finished in time. A deadline can: give each call whatever is LEFT of the
# callback's budget, and a call is only ever cut short when finishing it could
# no longer have helped.
describe CallbackBudget do
  after { CallbackBudget.reset }

  it "has no deadline outside a callback request" do
    CallbackBudget.reset

    assert_nil CallbackBudget.remaining,
      "background work is not on a callback's clock and must not be limited by one"
  end

  it "offers nearly the whole budget to the first call" do
    CallbackBudget.start!("cart_subscription_removed")

    assert_in_delta 5 - Connections::Fluid::CALLBACK_MARGIN, CallbackBudget.remaining, 0.05
  end

  # Fluid declares the deadline per DEFINITION, and they are not all the same.
  # Four carry maximum_timeout_in_milliseconds: 5000; the rest omit it and get
  # Callback::Client::MAX_TIMEOUT_IN_MILLISECONDS, 20s. Holding every callback
  # to the tightest of them cuts the most call-heavy ones off while Fluid is
  # still listening.
  it "gives a 20s callback the 20s Fluid actually waits" do
    CallbackBudget.start!("cart_customer_logged_in")

    assert_in_delta 20 - Connections::Fluid::CALLBACK_MARGIN, CallbackBudget.remaining, 0.05
  end

  it "assumes the tightest budget for a callback it does not know" do
    CallbackBudget.start!("something_new")

    assert_in_delta 5 - Connections::Fluid::CALLBACK_MARGIN, CallbackBudget.remaining, 0.05
  end

  it "shrinks as the callback spends its budget" do
    CallbackBudget.start!("cart_subscription_removed")
    CallbackBudget.started_at -= 3.0

    assert_in_delta 1.75, CallbackBudget.remaining, 0.05
  end

  # Past the deadline there is nothing left to win: Fluid has served the cart.
  # The floor keeps the call cheap rather than letting it inherit a connection
  # default and run on for seconds nobody is waiting through.
  it "floors at a token timeout once the budget is gone" do
    CallbackBudget.start!("cart_subscription_removed")
    CallbackBudget.started_at -= 30.0

    assert_equal CallbackBudget::FLOOR, CallbackBudget.remaining
  end

  it "never offers more than the budget, however early the call" do
    CallbackBudget.start!("cart_subscription_removed")
    CallbackBudget.started_at += 10.0

    assert_operator CallbackBudget.remaining, :<=, 5
  end
end

# A budget missing here is not a tuning gap, it is this droplet not knowing how
# long Fluid waits for a callback it answers.
describe "every served callback has a budget" do
  it "covers all of Callback::SERVED_PATHS" do
    missing = Callback::SERVED_PATHS.keys - Connections::Fluid::CALLBACK_BUDGETS.keys

    assert_empty missing, "no declared Fluid deadline for: #{missing.inspect}"
  end
end
