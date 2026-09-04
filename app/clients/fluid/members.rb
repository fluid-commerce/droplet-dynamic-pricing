require "uri"

module Fluid
  # Members are admin-tier endpoints, but the droplet's own installation token
  # reaches them: it sets company_admin (TokenAuthentication#
  # handle_droplet_installation_token) and auth_type "droplet", which skips the
  # Tier-2 permission check (PermissionAuthorizable#skip_permission_check?).
  # MembersController does not forbid droplet auth. Verified against a live
  # Fluid with an installation token.
  module Members
    def members
      @members ||= Resource.new(self)
    end

    # Fluid provisions this system member type for every company
    # (Company::SystemMemberTypeProvisioner, tier_level 1), so it is a constant
    # rather than per-company config.
    PREFERRED_SLUG = "preferred".freeze

    # The one system member type below preferred (tier_level 0 against
    # preferred's 1). It is the only type a promotion may overwrite: rep is
    # tier_level 2, so writing preferred over it demotes, and a company's own
    # custom type ranks nowhere this droplet can reason about.
    PROMOTABLE_SLUGS = [ nil, "", "customer" ].freeze

    class Resource
      BASE_PATH = "/api/v2025-06/members".freeze

      # The keys `find` matches on, in the order Fluid resolves them.
      IDENTIFIERS = %i[email username external_id legacy_customer_id].freeze

      def initialize(client)
        @client = client
      end

      # Returns the member's `member_type_slug` (flat) and `member_type` object.
      # A missing member raises FluidClient::ResourceNotFoundError on purpose:
      # resolving a customer to a member is expected to miss, and the caller has
      # to tell that apart from a member that simply has no type.
      def find(member_id)
        @client.get("#{BASE_PATH}/#{member_id}")
      end

      # Collection endpoint used to resolve a member from what the droplet
      # already holds (external_id, email) — there is no customer -> member
      # mapping table on this side.
      #
      # Exactly one identifier. Fluid does not AND them: `find` matches on the
      # first present key in IDENTIFIERS order and ignores the rest, so passing
      # two would quietly resolve on the wrong one. Both guards raise before the
      # request rather than spending a round trip on a 422.
      def find_by(**identifier)
        validate_identifier!(identifier)

        @client.get("#{BASE_PATH}/find?#{URI.encode_www_form(identifier)}")
      end

      def update_member_type(member_id, slug)
        payload = { "member_type_slug" => slug.to_s }
        @client.put("#{BASE_PATH}/#{member_id}/member-type", body: payload)
      end

    private

      def validate_identifier!(identifier)
        unknown = identifier.keys - IDENTIFIERS
        if unknown.any?
          raise ArgumentError, "unknown identifier #{unknown.join(', ')}; expected one of #{IDENTIFIERS.join(', ')}"
        end

        return if identifier.size == 1

        raise ArgumentError, "find_by takes exactly one of #{IDENTIFIERS.join(', ')}, got #{identifier.size}"
      end
    end
  end
end
