#!/usr/bin/env bash
#
# Synthetic smoke test against a deployed Next service.
#
#   scripts/smoke-next.sh https://fluid-droplet-name-next-xxxx.a.run.app
#
# Sends no valid signatures, so it needs no secrets and is safe against
# production. Read the limits below before trusting a pass.
#
# WHAT THIS CAN AND CANNOT SHOW
#
# The webhook route fails CLOSED, so an unsigned request must be refused with a
# 401. That is a real assertion: if verification were broken or the route were
# unwrapped, this would come back 200.
#
# EIGHT of this droplet's nine callbacks fail CLOSED, so an unsigned probe must
# come back 401 — a real assertion, and the reason this script can say more
# about callbacks than the fleet's usual one. Fluid discards the status of those
# eight (the cart-item subscriber throws the response away), so refusing costs
# a cart nothing and is the only thing that alerts.
#
# The NINTH — cart_email_on_create — fails open, because Fluid applies its
# response back to the cart. An unsigned probe there cannot distinguish
# "verifying correctly and refusing me" from "cannot verify anything and
# refusing everyone". That one is checked for its exact neutral body instead,
# which at least catches a route that has started answering with metadata.
#
# What a pass means: the service is up, routed, refusing unsigned webhooks and
# refusing unsigned fail-closed callbacks. It does NOT say a genuine Fluid
# callback would be ACCEPTED. Only real traffic — or a request signed with a
# real registration token — shows that, which is why the first cutover is an
# internal installation and not a client.
set -uo pipefail

BASE="${1:-}"
[ -n "$BASE" ] || { echo "usage: $0 <base-url>"; exit 2; }
BASE="${BASE%/}"

fail=0
check () {
  local name="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    printf '  ok    %-48s %s\n' "$name" "$got"
  else
    printf '  FAIL  %-48s got %s, want %s\n' "$name" "$got" "$expected"
    fail=$((fail + 1))
  fi
}

code () { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" 2>/dev/null || echo 000; }
body () { curl -s -m 20 "$@" 2>/dev/null || echo ""; }

echo "Smoke testing $BASE"

check "health" 200 "$(code "$BASE/api/health")"

# Fails closed. This is the assertion that carries weight.
check "webhook without a signature is refused" 401 \
  "$(code -X POST "$BASE/api/webhooks" \
      -H 'content-type: application/json' \
      -d '{"resource":"order","event":"created","company":{"fluid_shop":"smoke"}}')"

# 400, NOT 401. The SDK wrapper reads and JSON.parses the body BEFORE it looks
# at the signature (withFluidWebhook: onInvalidBody fires on a parse failure,
# well above the verification block), so a malformed body is rejected as a bad
# request and never reaches auth. This assertion previously demanded 401 on the
# strength of a comment claiming the opposite order — it would have failed
# against a correctly deployed service.
check "webhook with a malformed body is a bad request" 400 \
  "$(code -X POST "$BASE/api/webhooks" \
      -H 'content-type: application/json' -d 'not json')"

# A bootstrap-eligible event with no signature must also be refused. The shared
# secret is a candidate for these events, not a bypass of verification.
check "unsigned install event is refused" 401 \
  "$(code -X POST "$BASE/api/webhooks" \
      -H 'content-type: application/json' \
      -d '{"name":"droplet_installed","payload":{"company":{"fluid_shop":"smoke"}}}')"

# All eight fail-closed callbacks, individually. Checking one would not catch a
# route that was never created, and a missing route is the failure this droplet
# cannot see any other way: Fluid stops calling and the symptom is "prices are
# wrong", not an error. A 404 here is exactly that, caught before cutover.
for path in cart-item-added cart-item-updated cart-subscription-added \
            cart-subscription-removed cart-customer-logged-in \
            cart-customer-attached cart-customer-detached cart-country-changed; do
  check "callback $path refuses unsigned" 401 \
    "$(code -X POST "$BASE/api/callbacks/$path" \
        -H 'content-type: application/json' -d '{"cart":{"id":1}}')"
done

# The fail-open one. 200 proves routing only — it answers 200 to everything by
# design — so the BODY is what is asserted.
check "callback cart-email-on-create answers (fail-open, routing only)" 200 \
  "$(code -X POST "$BASE/api/callbacks/cart-email-on-create" \
      -H 'content-type: application/json' -d '{"cart":{"id":1}}')"

CB_BODY=$(body -X POST "$BASE/api/callbacks/cart-email-on-create" \
      -H 'content-type: application/json' -d '{"cart":{"id":1}}')
# Compared EXACTLY, not with a substring match, and the exactness is the point:
# a neutral body carrying `metadata` would stamp preferred pricing onto a cart
# that has not earned it, on an auth failure. `*success*` would also match
# {"success":false} and an HTML error page containing the word — precisely the
# kind of green that means nothing.
if [ "$CB_BODY" = '{"success":true}' ]; then
  printf '  ok    %-48s %s\n' "cart-email-on-create neutral body" "$CB_BODY"
else
  printf '  FAIL  %-48s %s\n' "cart-email-on-create neutral body" "$CB_BODY"
  fail=$((fail + 1))
fi

# The five subscription webhooks. No bootstrap secret is accepted on these, so
# an unsigned probe is a 401 in every case.
for path in subscription-started subscription-paused subscription-cancelled \
            subscription-resumed subscription-reactivated; do
  check "webhook $path refuses unsigned" 401 \
    "$(code -X POST "$BASE/api/webhooks/$path" \
        -H 'content-type: application/json' \
        -d '{"resource":"subscription","event":"started","company_id":0}')"
done

# The assertions above prove the service REFUSES what it should. They cannot
# prove it ACCEPTS what it should: deploy with FLUID_WEBHOOK_AUTH_TOKEN absent
# or wrong and every one of them still passes, while every genuine signed
# install and uninstall is also refused. So if the secret is available, send a
# correctly signed lifecycle event and require it NOT to be a 401.
#
#   FLUID_WEBHOOK_AUTH_TOKEN=... scripts/smoke-next.sh https://...
#
# 401 means verification is rejecting real Fluid traffic. Anything else — 202,
# 204, even a 500 from the handler — proves the signature was accepted, which is
# the only thing this check is about.
if [ -n "${FLUID_WEBHOOK_AUTH_TOKEN:-}" ]; then
  # `droplet.uninstalled`, NOT `droplet.installed`, and this matters.
  #
  # A signed install would WRITE: handleDropletInstalled only bails early when a
  # configured droplet uuid fails to match, and when none is configured it warns
  # and carries on — creating a `companies` row named "Smoke" with
  # `authentication_token: "smoke"` in whatever database the service is pointed
  # at. A smoke test must not be able to do that.
  #
  # Uninstall is also a bootstrap event, so it proves exactly the same thing
  # about the signature, but `handleDropletUninstalled` resolves the company
  # first and returns when it finds none. With a DRI that matches nothing, it is
  # provably write-free.
  BODY='{"resource":"droplet","event":"uninstalled","company":{"droplet_installation_uuid":"dri_smoke_probe_no_such_installation"}}'
  TS=$(date +%s)
  SIG=$(printf '%s.%s' "$TS" "$BODY" \
    | openssl dgst -sha256 -hmac "$FLUID_WEBHOOK_AUTH_TOKEN" \
    | sed 's/^.*= //')
  SIGNED=$(code -X POST "$BASE/api/webhooks" \
    -H 'content-type: application/json' \
    -H "X-Fluid-Timestamp: $TS" \
    -H "X-Fluid-Signature: $SIG" \
    -d "$BODY")
  if [ "$SIGNED" = "401" ]; then
    printf '  FAIL  %-48s %s\n' "signed lifecycle webhook is accepted" "$SIGNED"
    fail=$((fail + 1))
  else
    printf '  ok    %-48s %s\n' "signed lifecycle webhook is accepted" "$SIGNED"
  fi
else
  printf '  SKIP  %-48s %s\n' "signed lifecycle webhook is accepted" \
    "set FLUID_WEBHOOK_AUTH_TOKEN to check"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "$fail check(s) failed — do not repoint any installation at this service."
  exit 1
fi
if [ -n "${FLUID_WEBHOOK_AUTH_TOKEN:-}" ]; then
  echo "Passed. The service refuses unsigned webhooks AND accepts a signed one."
else
  echo "Passed, but only the refusal half was checked — nothing here proves a"
  echo "genuine signed webhook would be accepted. Re-run with"
  echo "FLUID_WEBHOOK_AUTH_TOKEN set before repointing anything."
fi
echo "This does NOT establish that a signed callback would be accepted;"
echo "cut an internal installation over first and watch it."
