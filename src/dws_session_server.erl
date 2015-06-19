-module (dws_session_server).
-behaviour (gen_server).

-include_lib ("stdlib/include/qlc.hrl").
-include_lib ("dws_cluster_db.hrl").

-define (SERVER, ?MODULE).

%% Defaults, configurable from `sys.config'
-define (SESSION_LIFETIME,          24*60*60). %% 1d in secs
-define (SESSION_AUTOWIPE_INTERVAL,    60*60). %% 1h in secs

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export ([
          start_link/0,

          create_session/0,
          set_session_data/2,
          get_session_data/1,
          drop_session/1,
          wipe_sessions/0
         ]).

-export ([ %% Internal, but useful to have it exported
          get_session_ttl/0
         ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export ([
          init/1, handle_call/3, handle_cast/2, handle_info/2,
          terminate/2, code_change/3
         ]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link () ->
    gen_server:start_link ({local, ?SERVER}, ?MODULE, [], []).

create_session () ->
    gen_server:call (?SERVER, create_session).

set_session_data (SessionID, Data) when is_list (SessionID) ->
    set_session_data (list_to_binary (SessionID), Data);
set_session_data (SessionID, Data) when is_binary (SessionID) ->
    gen_server:call (?SERVER, {set_session_data, SessionID, Data}).

get_session_data (SessionID) when is_list (SessionID) ->
    get_session_data (list_to_binary (SessionID));
get_session_data (SessionID) when is_binary (SessionID) ->
    gen_server:call (?SERVER, {get_session_data, SessionID}).

drop_session (SessionID) when is_list (SessionID) ->
    drop_session (list_to_binary (SessionID));
drop_session (SessionID) when is_binary (SessionID) ->
    gen_server:call (?SERVER, {drop_session, SessionID}).

wipe_sessions () ->
    gen_server:cast (?SERVER, wipe_sessions).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init (Args) ->
    schedule_autowipe (),
    {ok, Args}.

handle_call (create_session, _From, State) ->
    Id = list_to_binary (idealib_crypto:hash_hex (sha, crypto:rand_bytes (2048))),
    Fun = fun () ->
                  mnesia:write (#?TABLE_SESSION { id = Id })
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    {reply, {ok, Id}, State};
handle_call ({set_session_data, SessionID, Data} = _Request, _From, State) ->
    Fun = fun () ->
                  mnesia:write (#?TABLE_SESSION { id = SessionID, state = Data })
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    {reply, ok, State};
handle_call ({get_session_data, SessionID} = _Request, _From, State) ->
    Fun = fun () ->
                  mnesia:read ({?TABLE_SESSION, SessionID})
          end,
    case mnesia:transaction (Fun) of
        {atomic, [#?TABLE_SESSION { state = Data }]} ->
            {reply, {ok, Data}, State};
        {atomic, []} ->
            {reply, {error, not_found}, State};
        Error ->
            {reply, {error, Error}, State}
    end;
handle_call ({drop_session, SessionID} = _Request, _From, State) ->
    Fun = fun () ->
                  mnesia:delete ({?TABLE_SESSION, SessionID})
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    {reply, ok, State}.

handle_cast (wipe_sessions, State) ->
    spawn (fun wipe_sessions_internal/0),
    {noreply, State};
handle_cast (_Msg, State) ->
    {noreply, State}.

handle_info ({timeout, _, autowipe_sessions}, State) ->
    wipe_sessions_internal (),
    schedule_autowipe (),
    {noreply, State};
handle_info (Info, State) ->
    lager:warning ("Received an info message: ~w", [Info]),
    {noreply, State}.

terminate (_Reason, _State) ->
    ok.

code_change (_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

schedule_autowipe () ->
    erlang:start_timer (get_session_autowipe_interval () * 1000,
                        ?SERVER, autowipe_sessions).

wipe_sessions_internal () ->
    lager:info ("Wiping session from node=~w...", [node ()]),
    Fun = fun () ->
                  qlc:eval (qlc:q ([ ok = mnesia:delete ({?TABLE_SESSION, X#?TABLE_SESSION.id})
                                     || X <- mnesia:table (?TABLE_SESSION),
                                        is_expired (X) ]))
          end,
    {atomic, _} = mnesia:transaction (Fun),
    ok.

get_session_ttl () ->
    T = application:get_env (dws, session_lifetime, ?SESSION_LIFETIME),
    idealib_conv:x2int0 (T).

get_session_autowipe_interval () ->
    T = application:get_env (dws, session_autowipe_interval, ?SESSION_AUTOWIPE_INTERVAL),
    idealib_conv:x2int0 (T).

is_expired (#?TABLE_SESSION { created = Created }) ->
    Now = idealib_dt:now2us (),
    Ttl = idealib_dt:sec2us (get_session_ttl ()),
    Expiry = idealib_dt:now2us (Created) + Ttl,
    Expiry < Now.

