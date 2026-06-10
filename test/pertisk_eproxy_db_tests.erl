-module(pertisk_eproxy_db_tests).

-include_lib("eunit/include/eunit.hrl").

tmp_db() ->
    filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_db_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".db"
    ]).

db_file_exists_false_for_missing_test() ->
    Path = tmp_db(),
    file:delete(Path),
    ?assertNot(pertisk_eproxy_db:db_file_exists(Path)).

migrate_schema_creates_file_test() ->
    Path = tmp_db(),
    file:delete(Path),
    ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
    ?assert(pertisk_eproxy_db:db_file_exists(Path)),
    file:delete(Path).

ensure_ready_new_file_test() ->
    Path = tmp_db(),
    file:delete(Path),
    ?assertMatch({ok, Path}, pertisk_eproxy_db:ensure_ready(Path)),
    file:delete(Path).

ensure_ready_existing_runs_migration_test() ->
    Path = tmp_db(),
    ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(Path)),
    ?assertMatch({ok, Path}, pertisk_eproxy_db:ensure_ready(Path)),
    file:delete(Path).
