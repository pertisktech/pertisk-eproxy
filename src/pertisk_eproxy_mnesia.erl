%%% Mnesia schema setup for pertisk_eproxy configuration storage.
-module(pertisk_eproxy_mnesia).

-export([ensure_started/1]).

-include("pertisk_eproxy_db_records.hrl").

-define(TABLES, [
    pertisk_eproxy_counter,
    pertisk_eproxy_runtime_state,
    pertisk_eproxy_site,
    pertisk_eproxy_certificate,
    pertisk_eproxy_dns_provider,
    pertisk_eproxy_admin_user
]).

-spec ensure_started(string()) -> ok | {error, term()}.
ensure_started(Dir) when is_list(Dir) ->
    case filelib:ensure_dir(filename:join(Dir, "PLACEHOLDER")) of
        ok ->
            ok = application:set_env(mnesia, dir, Dir),
            case ensure_mnesia_application() of
                ok ->
                    case ensure_schema() of
                        ok ->
                            start_mnesia_and_tables();
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, {mnesia_dir, Reason}}
    end.

%% Do not list `mnesia` in `pertisk_eproxy.app.src` applications — it must start
%% after `mnesia` `dir` is set (see sys.config / `mnesia_dir`).
ensure_mnesia_application() ->
    case application:ensure_all_started(mnesia) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

ensure_schema() ->
    case mnesia:create_schema([node()]) of
        ok ->
            ok;
        {error, Reason} ->
            case schema_already_exists(Reason) of
                true -> ok;
                false -> {error, Reason}
            end
    end.

%% OTP versions differ: `{already_exists, _}` vs `{Node, {already_exists, Node}}`.
schema_already_exists({already_exists, _}) ->
    true;
schema_already_exists({_Node, {already_exists, _}}) ->
    true;
schema_already_exists(_) ->
    false.

start_mnesia_and_tables() ->
    case mnesia:system_info(is_running) of
        yes ->
            create_tables();
        starting ->
            wait_until_running(30),
            create_tables();
        no ->
            case mnesia:start() of
                ok ->
                    create_tables();
                {error, {already_started, _}} ->
                    create_tables();
                {error, Reason} ->
                    {error, Reason}
            end
    end.

wait_until_running(0) ->
    {error, mnesia_start_timeout};
wait_until_running(N) ->
    case mnesia:system_info(is_running) of
        yes ->
            ok;
        _ ->
            timer:sleep(100),
            wait_until_running(N - 1)
    end.

create_tables() ->
    case lists:foldl(
        fun(Tab, ok) ->
            case create_table(Tab) of
                ok -> ok;
                {error, Reason} -> {error, Reason}
            end
        end,
        ok,
        ?TABLES
    ) of
        ok ->
            wait_for_storage_tables();
        {error, _} = E ->
            E
    end.

wait_for_storage_tables() ->
    case mnesia:wait_for_tables(?TABLES, 30000) of
        ok ->
            ok;
        {timeout, Bad} ->
            {error, {wait_for_tables, Bad}};
        {error, Reason} ->
            {error, Reason}
    end.

create_table(pertisk_eproxy_counter) ->
    create_disc_table(pertisk_eproxy_counter, [key, next_id], []);
create_table(pertisk_eproxy_runtime_state) ->
    create_disc_table(pertisk_eproxy_runtime_state, [key, value], []);
create_table(pertisk_eproxy_site) ->
    create_disc_table(pertisk_eproxy_site, record_info(fields, pertisk_eproxy_site), []);
create_table(pertisk_eproxy_certificate) ->
    create_disc_table(
        pertisk_eproxy_certificate,
        record_info(fields, pertisk_eproxy_certificate),
        [{index, [name]}]
    );
create_table(pertisk_eproxy_dns_provider) ->
    create_disc_table(
        pertisk_eproxy_dns_provider,
        record_info(fields, pertisk_eproxy_dns_provider),
        [{index, [name]}]
    );
create_table(pertisk_eproxy_admin_user) ->
    create_disc_table(pertisk_eproxy_admin_user, record_info(fields, pertisk_eproxy_admin_user), []).

create_disc_table(Name, Attributes, Extra) ->
    Nodes = [node()],
    Opts =
        [{attributes, Attributes}, {disc_copies, Nodes}, {type, set}, {load_order, 0}] ++ Extra,
    case mnesia:create_table(Name, Opts) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, Name}} ->
            ok;
        {aborted, Reason} ->
            {error, Reason}
    end.
