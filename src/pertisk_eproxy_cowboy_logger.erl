%% @doc Cowboy logger adapter that suppresses known benign QUIC shutdown noise.
-module(pertisk_eproxy_cowboy_logger).

-export([emergency/2, alert/2, critical/2, error/2, warning/2, notice/2, info/2, debug/2]).

-include_lib("lager/include/lager.hrl").

emergency(Fmt, Args) -> lager:error(Fmt, Args).
alert(Fmt, Args) -> lager:error(Fmt, Args).
critical(Fmt, Args) -> lager:error(Fmt, Args).
error(Fmt, Args) -> lager:error(Fmt, Args).
notice(Fmt, Args) -> lager:warning(Fmt, Args).
info(Fmt, Args) -> lager:info(Fmt, Args).
debug(Fmt, Args) -> lager:debug(Fmt, Args).

warning("Received unknown QUIC message ~p.", [{quic, shutdown, _Ref, _Code}]) ->
    ok;
warning(Fmt, Args) ->
    lager:warning(Fmt, Args).
