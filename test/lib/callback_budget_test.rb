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
    CallbackBudget.start!

    assert_in_delta Connections::Fluid::CALLBACK_BUDGET - Connections::Fluid::CALLBACK_MARGIN,
                    CallbackBudget.remaining, 0.05
  end

  it "shrinks as the callback spends its budget" do
    CallbackBudget.start!
    CallbackBudget.started_at -= 3.0

    assert_in_delta 1.75, CallbackBudget.remaining, 0.05
  end

  # Past the deadline there is nothing left to win: Fluid has served the cart.
  # The floor keeps the call cheap rather than letting it inherit a connection
  # default and run on for seconds nobody is waiting through.
  it "floors at a token timeout once the budget is gone" do
    CallbackBudget.start!
    CallbackBudget.started_at -= 30.0

    assert_equal CallbackBudget::FLOOR, CallbackBudget.remaining
  end

  it "never offers more than the budget, however early the call" do
    CallbackBudget.start!
    CallbackBudget.started_at += 10.0

    assert_operator CallbackBudget.remaining, :<=, Connections::Fluid::CALLBACK_BUDGET
  end
end
