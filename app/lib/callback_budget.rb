# frozen_string_literal: true

# Public: What is left of the deadline Fluid gives a synchronous callback.
#
# A flat per-call timeout has to pick one number for two different situations
# it cannot tell apart: a call that has hung, and a call that is slow but about
# to answer. Any value tight enough to survive the first kills the second — a
# 2s cap makes every legitimate 2-5s call fail where a 5s cap let it through,
# and a 5s cap (the whole budget) lets one hung call end the callback by
# itself. There is no flat number that is right.
#
# A deadline dissolves the choice. Each call is offered whatever remains of the
# callback's budget, so a call is cut short only when finishing it could no
# longer have helped — Fluid has already served the cart by then. Nothing that
# could have arrived in time is ever refused.
#
# Per-request by construction (ActiveSupport::CurrentAttributes resets on every
# request and job). Outside a callback request there is no deadline at all, and
# #remaining answers nil so background work keeps its own generous budget.
class CallbackBudget < ActiveSupport::CurrentAttributes
  attribute :started_at, :budget

  # The smallest timeout worth issuing. Past the deadline nothing can be won,
  # but the call still has to carry SOME timeout or it inherits the connection
  # default and runs on for seconds nobody is waiting through.
  FLOOR = 0.25

  # Public: Start the clock for one callback request.
  #
  # definition_name - Fluid's name for the callback being answered, which is
  #                   what carries the deadline. An unknown name takes the
  #                   tightest budget rather than the most generous.
  #
  # Returns nothing.
  def self.start!(definition_name)
    self.budget = Connections::Fluid::CALLBACK_BUDGETS.fetch(
      definition_name, Connections::Fluid::CALLBACK_BUDGET
    )
    self.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Public: Seconds a call may take without outliving the callback's deadline.
  #
  # Returns a Float, or nil when not inside a callback request.
  def self.remaining
    return nil if started_at.nil?

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    left = budget - Connections::Fluid::CALLBACK_MARGIN - elapsed

    left.clamp(FLOOR, budget)
  end
end
