%% Mnesia record definitions for pertisk_eproxy configuration storage.

-record(pertisk_eproxy_counter, {
    key :: certificate | dns_provider,
    next_id = 1 :: non_neg_integer()
}).

-record(pertisk_eproxy_runtime_state, {
    key :: atom(),
    value :: binary()
}).

-record(pertisk_eproxy_site, {
    host :: binary(),
    backend :: binary(),
    certificate = <<>> :: binary(),
    dns_provider = <<>> :: binary(),
    challenge_type = <<>> :: binary(),
    wildcard = 0 :: 0 | 1,
    acme_wildcard_base = <<>> :: binary(),
    advertise_http3 = 1 :: 0 | 1,
    acme_contact_email = <<>> :: binary(),
    routes_json = <<"[]">> :: binary()
}).

-record(pertisk_eproxy_certificate, {
    id :: pos_integer(),
    name :: binary(),
    cert_pem = <<>> :: binary(),
    key_pem = <<>> :: binary(),
    source_type = <<"acme">> :: binary()
}).

-record(pertisk_eproxy_dns_provider, {
    id :: pos_integer(),
    name :: binary(),
    provider_type :: binary(),
    credentials_json = <<"{}">> :: binary()
}).

-record(pertisk_eproxy_admin_user, {
    username :: binary(),
    salt_b64 :: binary(),
    pass_hash_b64 :: binary()
}).
