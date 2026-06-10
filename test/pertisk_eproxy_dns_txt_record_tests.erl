-module(pertisk_eproxy_dns_txt_record_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FQDN, <<"_acme-challenge.www.example.com">>).
-define(ZONE, <<"example.com">>).

txt_record_name_strips_zone_suffix_test() ->
    ?assertEqual(<<"_acme-challenge.www">>, cf()),
    ?assertEqual(<<"_acme-challenge.www">>, desec()),
    ?assertEqual(<<"_acme-challenge.www">>, digitalocean()),
    ?assertEqual(<<"_acme-challenge.www">>, gandi()),
    ?assertEqual(<<"_acme-challenge.www">>, hetzner()),
    ?assertEqual(<<"_acme-challenge.www">>, linode()),
    ?assertEqual(<<"_acme-challenge.www">>, porkbun()),
    ?assertEqual(<<"_acme-challenge.www">>, powerdns()),
    ?assertEqual(<<"_acme-challenge.www">>, vultr()).

txt_record_name_no_suffix_match_test() ->
    Other = <<"_acme-challenge.other.net">>,
    ?assertEqual(Other, pertisk_eproxy_dns_cloudflare:cf_txt_record_name(Other, ?ZONE)),
    ?assertEqual(Other, pertisk_eproxy_dns_desec:txt_record_name(Other, ?ZONE)).

cf() -> pertisk_eproxy_dns_cloudflare:cf_txt_record_name(?FQDN, ?ZONE).
desec() -> pertisk_eproxy_dns_desec:txt_record_name(?FQDN, ?ZONE).
digitalocean() -> pertisk_eproxy_dns_digitalocean:txt_record_name(?FQDN, ?ZONE).
gandi() -> pertisk_eproxy_dns_gandi:txt_record_name(?FQDN, ?ZONE).
hetzner() -> pertisk_eproxy_dns_hetzner:txt_record_name(?FQDN, ?ZONE).
linode() -> pertisk_eproxy_dns_linode:txt_record_name(?FQDN, ?ZONE).
porkbun() -> pertisk_eproxy_dns_porkbun:txt_record_name(?FQDN, ?ZONE).
powerdns() -> pertisk_eproxy_dns_powerdns:txt_record_name(?FQDN, ?ZONE).
vultr() -> pertisk_eproxy_dns_vultr:txt_record_name(?FQDN, ?ZONE).
