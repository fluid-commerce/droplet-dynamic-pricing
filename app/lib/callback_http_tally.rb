# frozen_string_literal: true

# Public: How much of a callback's budget went to outbound Fluid calls, and
# across how many of them.
#
# The callback-timing line has always reported one number — the total. Which of
# the dozen-odd sequential Fluid calls a callback makes actually spent it was a
# deduction from silence: the CURRENT-3248 trace had a 6.16s gap with no log
# lines in it, and the retry inside it had to be inferred from the shape.
#
# That guesswork is affordable once. It is not a basis for deciding which call
# to batch, cache or move off the synchronous path — so the share is measured
# rather than reasoned about.
#
# Per-request by construction (ActiveSupport::CurrentAttributes resets on every
# request and job), and scoped to the :callback profile: background work is on
# nobody's critical path and would only pollute the numbers.
class CallbackHttpTally < ActiveSupport::CurrentAttributes
  attribute :calls, :elapsed_ms

  # Public: Record one completed Fluid call.
  #
  # elapsed_seconds - Float wall time the call took, timed out calls included:
  #                   the time a failed call spends is exactly the time worth
  #                   knowing about.
  #
  # Returns nothing.
  def self.record(elapsed_seconds)
    self.calls = calls.to_i + 1
    self.elapsed_ms = elapsed_ms.to_f + (elapsed_seconds * 1000)
  end

  # Public: Returns a Hash of { calls: Integer, elapsed_ms: Integer }.
  def self.summary
    { calls: calls.to_i, elapsed_ms: elapsed_ms.to_f.round }
  end
end
