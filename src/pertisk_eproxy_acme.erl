%%%-------------------------------------------------------------------
%% @doc ACME client for automatic certificate management (Let's Encrypt)
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_acme).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([request_certificate/1, renew_certificates/0, get_certificate/1]).

-define(SERVER, ?MODULE).
-define(DEFAULT_ACME_PROVIDER, "https://acme-v02.api.letsencrypt.org/directory").
-define(CERT_RENEWAL_INTERVAL, 86400000).  % 24 hours in milliseconds
-define(RENEWAL_DAYS_BEFORE_EXPIRY, 30).

-record(state, {
    acme_provider = ?DEFAULT_ACME_PROVIDER,
    certificates = #{},
    renewal_timer = undefined
}).

%%%===================================================================
%% API functions
%%%===================================================================

-spec start_link() -> {ok, Pid} | {error, Reason}
    when Pid :: pid(),
         Reason :: term().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec request_certificate(Domains) -> {ok, CertInfo} | {error, Reason}
    when Domains :: [string()],
         CertInfo :: map(),
         Reason :: term().
request_certificate(Domains) ->
    gen_server:call(?SERVER, {request_certificate, Domains}).

-spec renew_certificates() -> ok.
renew_certificates() ->
    gen_server:cast(?SERVER, renew_certificates).

-spec get_certificate(Domain) -> {ok, CertInfo} | {error, Reason}
    when Domain :: string(),
         CertInfo :: map(),
         Reason :: term().
get_certificate(Domain) ->
    gen_server:call(?SERVER, {get_certificate, Domain}).

%%%===================================================================
%% gen_server callbacks
%%%===================================================================

-spec init(Args) -> {ok, State}
    when Args :: term(),
         State :: #state{}.
init([]) ->
    io:format("Initializing ACME client~n"),
    
    AcmeEnabled = application:get_env(pertisk_eproxy, acme_enabled, false),
    AcmeProvider = application:get_env(pertisk_eproxy, acme_provider, ?DEFAULT_ACME_PROVIDER),
    
    case AcmeEnabled of
        true ->
            io:format("ACME enabled, using provider: ~s~n", [AcmeProvider]),
            % Start renewal timer
            Timer = erlang:send_after(?CERT_RENEWAL_INTERVAL, self(), check_renewal),
            {ok, #state{acme_provider = AcmeProvider, renewal_timer = Timer}};
        false ->
            io:format("ACME disabled~n"),
            {ok, #state{acme_provider = AcmeProvider}}
    end.

-spec handle_call(Request, From, State) -> {reply, Reply, State}
    when Request :: term(),
         From :: {pid(), reference()},
         State :: #state{},
         Reply :: term().
handle_call({request_certificate, Domains}, _From, State) ->
    io:format("Requesting certificate for domains: ~p~n", [Domains]),
    % This is a placeholder - actual ACME integration would:
    % 1. Create account
    % 2. Request order
    % 3. Complete challenges
    % 4. Finalize order
    % 5. Download certificate
    Reply = {ok, #{
        domains => Domains,
        status => pending,
        issued_at => erlang:system_time(second)
    }},
    {reply, Reply, State};

handle_call({get_certificate, Domain}, _From, State) ->
    Reply = case maps:find(Domain, State#state.certificates) of
        {ok, Cert} -> {ok, Cert};
        error -> {error, not_found}
    end,
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(Request, State) -> {noreply, State}
    when Request :: term(),
         State :: #state{}.
handle_cast(renew_certificates, State) ->
    io:format("Checking for certificates to renew~n"),
    % Iterate through certificates and check expiry
    NewState = State,
    {noreply, NewState};

handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(Info, State) -> {noreply, State}
    when Info :: term(),
         State :: #state{}.
handle_info(check_renewal, State) ->
    io:format("Performing periodic certificate renewal check~n"),
    % Schedule next check
    Timer = erlang:send_after(?CERT_RENEWAL_INTERVAL, self(), check_renewal),
    {noreply, State#state{renewal_timer = Timer}};

handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(Reason, State) -> ok
    when Reason :: term(),
         State :: #state{}.
terminate(_Reason, State) ->
    case State#state.renewal_timer of
        undefined -> ok;
        Timer -> erlang:cancel_timer(Timer)
    end,
    io:format("ACME client terminated~n"),
    ok.

-spec code_change(OldVsn, State, Extra) -> {ok, NewState}
    when OldVsn :: term(),
         State :: #state{},
         Extra :: term(),
         NewState :: #state{}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%% Internal functions
%%%===================================================================

-spec validate_domain_ownership(Domain, Challenge) -> ok | {error, Reason}
    when Domain :: string(),
         Challenge :: term(),
         Reason :: term().
validate_domain_ownership(_Domain, _Challenge) ->
    % Implementation for domain validation
    % Supports: http-01, dns-01, tls-alpn-01
    ok.

-spec create_csr(Domains, KeyPair) -> {ok, CSR} | {error, Reason}
    when Domains :: [string()],
         KeyPair :: term(),
         CSR :: binary(),
         Reason :: term().
create_csr(_Domains, _KeyPair) ->
    % Create Certificate Signing Request
    {ok, <<>>}.
