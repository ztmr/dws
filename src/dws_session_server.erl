-module (dws_session_server).
-behaviour (gen_server).

-include_lib ("stdlib/include/qlc.hrl").

-define (SERVER, ?MODULE).
-define (SESSION_LIFETIME, 24*60*60). %% 1day in secs

-record (session, {
           id = <<>> :: binary (),
           created = now (),
           state = #{} :: map ()
          }).

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
    gen_server:call (?SERVER, {create_session}).

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
    gen_server:call (?SERVER, {wipe_sessions}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init (Args) ->
    case mnesia:wait_for_tables ([session], 5000) of
        ok ->
            error_logger:info_msg ("Distributed session storage started...");
        {timeout, [session]} ->
            error_logger:info_msg ("Distributed session storage needs to be initialized!"),
            install ()
    end,
    {ok, Args}.

handle_call ({create_session} = _Request, _From, State) ->
    Id = list_to_binary (idealib_crypto:hash_hex (sha, crypto:rand_bytes (2048))),
    Fun = fun () ->
                  mnesia:write (#session { id = Id })
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    {reply, {ok, Id}, State};
handle_call ({set_session_data, SessionID, Data} = _Request, _From, State) ->
    Fun = fun () ->
                  mnesia:write (#session { id = SessionID, state = Data })
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    {reply, ok, State};
handle_call ({get_session_data, SessionID} = _Request, _From, State) ->
    Fun = fun () ->
                  mnesia:read ({session, SessionID})
          end,
    case mnesia:transaction (Fun) of
        {atomic, [#session { state = Data }]} ->
            {reply, {ok, Data}, State};
        {atomic, []} ->
            {reply, {error, not_found}, State};
        Error ->
            {reply, {error, Error}, State}
    end;
handle_call ({drop_session, SessionID} = _Request, _From, State) ->
    Fun = fun () ->
                  mnesia:delete ({session, SessionID})
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    {reply, ok, State};
handle_call ({wipe_sessions} = _Request, _From, State) ->
    Fun = fun () ->
                  qlc:eval (qlc:q ([ ok = mnesia:delete ({session, X#session.id})
                                     || X <- mnesia:table (session),
                                        is_expired (X) ]))
          end,
    {atomic, _} = mnesia:transaction (Fun),
    {reply, ok, State}.

handle_cast (_Msg, State) ->
    {noreply, State}.

handle_info (_Info, State) ->
    {noreply, State}.

terminate (_Reason, _State) ->
    ok.

code_change (_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

install () ->
    install ([node ()|nodes ()]).
install (Nodes) ->
    error_logger:info_msg ("Installing distributed session storage..."),
    %% XXX: install only where it is not installed yet
    %% since we don't want to stop/reinit Mnesia where
    %% it is already working!!!
    rpc:multicall (Nodes, application, stop, [mnesia]),
    mnesia:create_schema (Nodes),
    rpc:multicall (Nodes, application, start, [mnesia]),
    mnesia:create_table (session,
                         [{attributes, record_info (fields, session)},
                          {disc_copies, Nodes}]).
    %rpc:multicall (Nodes, application, stop, [mnesia]).
    %rpc:multicall (Nodes, application, start, [mnesia]),

is_expired (#session { created = Created }) ->
    Now = idealib_dt:now2us (),
    Ttl = idealib_dt:sec2us (?SESSION_LIFETIME),
    Expiry = idealib_dt:now2us (Created) + Ttl,
    Expiry < Now.

