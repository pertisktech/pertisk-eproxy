%% @doc RFC3339 timestamps for Kubernetes API status/lease fields.
-module(pertisk_k8s_time).

-export([rfc3339_now/0]).

-spec rfc3339_now() -> binary().
rfc3339_now() ->
    Micro = erlang:system_time(microsecond),
    list_to_binary(
        calendar:system_time_to_rfc3339(Micro, [{unit, microsecond}, {offset, "Z"}])
    ).
