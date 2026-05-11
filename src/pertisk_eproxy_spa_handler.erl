%% @doc Serves the admin SPA index.html for any non-/api route on the management listener.
%% This enables client-side routing (react-router) to work correctly.

-module(pertisk_eproxy_spa_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, State) ->
    %% Resolve the SPA index.html from the app's priv directory.
    PrivDir = code:priv_dir(pertisk_eproxy),
    IndexFile = filename:join([PrivDir, "admin", "index.html"]),
    case file:read_file(IndexFile) of
        {ok, Html} ->
            Req2 = cowboy_req:reply(200,
                #{<<"content-type">> => <<"text/html; charset=utf-8">>},
                Html, Req),
            {ok, Req2, State};
        {error, _} ->
            %% Admin UI not built yet; return a helpful message.
            Body = <<"<html><body style='font-family:monospace;padding:40px'>"
                     "<h2>Admin UI not built</h2>"
                     "<p>Run: <code>cd admin &amp;&amp; npm install &amp;&amp; npm run build</code></p>"
                     "</body></html>">>,
            Req2 = cowboy_req:reply(200,
                #{<<"content-type">> => <<"text/html; charset=utf-8">>},
                Body, Req),
            {ok, Req2, State}
    end.
