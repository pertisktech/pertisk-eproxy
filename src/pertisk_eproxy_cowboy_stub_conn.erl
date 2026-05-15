%% @doc Minimal Cowboy connection stub for in-process admin handler dispatch (HTTP/3).
-module(pertisk_eproxy_cowboy_stub_conn).

-export([start/2, stub_stream_id/0]).

-define(STUB_STREAM_ID, 1).

stub_stream_id() ->
    ?STUB_STREAM_ID.

%% @doc Spawn a process that answers cowboy_req casts for `read_body` and captures `reply`.
-spec start(pid(), binary()) -> pid().
start(Parent, Body) when is_pid(Parent) ->
    spawn_link(fun() -> loop(Parent, Body) end).

loop(Parent, Body) ->
    Self = self(),
    receive
        {{Self, ?STUB_STREAM_ID}, {read_body, From, Ref, _Len, _Period}} ->
            From ! {request_body, Ref, fin, byte_size(Body), Body},
            loop(Parent, Body);
        {{Self, ?STUB_STREAM_ID}, {response, Status, Headers, RespBody}} ->
            Parent ! {h3_admin_response, Status, Headers, RespBody},
            ok;
        {{Self, ?STUB_STREAM_ID}, {headers, _Status, _Headers}} ->
            loop(Parent, Body);
        {{Self, ?STUB_STREAM_ID}, {data, _Data, _Fin}} ->
            loop(Parent, Body);
        {{Self, ?STUB_STREAM_ID}, {trailers, _Trailers}} ->
            loop(Parent, Body);
        Msg ->
            lager:debug("cowboy_stub_conn: ignored ~p", [Msg]),
            loop(Parent, Body)
    end.
