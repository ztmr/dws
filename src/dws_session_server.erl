-module (dws_session_server).
-behaviour (gen_server).

-include_lib ("stdlib/include/qlc.hrl").
-include_lib ("dws_session.hrl").

-define (SERVER, ?MODULE).

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
    init_db (),
    schedule_autowipe (),
    {ok, Args}.

handle_call (create_session, _From, State) ->
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

init_db () ->
    discover_nodes (),
    Tables = [?TABLE],
    Nodes = [node () | nodes ()],
    {ok, _} = mnesia:change_config (extra_db_nodes, Nodes),
    ok = ensure_schema (),
    case mnesia:wait_for_tables (Tables, ?WAIT_FOR_TABLES) of
        ok ->
            ensure_table (mnesia:add_table_copy (?TABLE, node (), disc_copies));
        {timeout, Tables} ->
            Attribs = [{attributes, record_info (fields, ?TABLE)},
                       {disc_copies, Nodes}],
            ensure_table (mnesia:create_table (?TABLE, Attribs))
    end.

ensure_schema () ->
    ensure_table (mnesia:change_table_copy_type (schema, node (), disc_copies)).

ensure_table ({atomic, ok}) -> ok;
ensure_table ({aborted, {already_exists, schema, _Node, disc_copies}}) -> ok;
ensure_table ({aborted, {already_exists, session, _Node}}) -> ok.

cluster_hosts () ->
    case application:get_env (dws, cluster_hosts) of
        undefined ->
            [];
        {ok, Hosts} when is_list (Hosts) ->
            Hosts
    end.

discover_nodes () ->
    LocalNodes = discover_nodes (net_adm:names (), "127.0.0.1"),
    ExtraNodes = [ discover_nodes (net_adm:names (H), H)
                   || H <- cluster_hosts () ],
    lists:flatten ([ LocalNodes, ExtraNodes ]).

discover_nodes ({error, _}, _) -> ok;
discover_nodes ({ok, Nodes}, Host) ->
    join_nodes (Nodes, Host).

join_nodes (Nodes, Host) ->
    join_nodes (Nodes, Host, []).

join_nodes ([], _Host, Acc) -> Acc;
join_nodes ([H|T], Host, Acc) ->
    Result = join_node (H, Host),
    join_nodes (T, Host, [Result|Acc]).

join_node ({Name, _Port}, Host) ->
    Node = list_to_atom (Name++"@"++Host),
    {Node, net_kernel:connect (Node)}.

schedule_autowipe () ->
    erlang:start_timer (?AUTOWIPE_SESSION_INTERVAL*1000, ?SERVER, autowipe_sessions).

wipe_sessions_internal () ->
    lager:info ("Wiping session from node=~w...", [node ()]),
    Fun = fun () ->
                  qlc:eval (qlc:q ([ ok = mnesia:delete ({session, X#session.id})
                                     || X <- mnesia:table (session),
                                        is_expired (X) ]))
          end,
    {atomic, _} = mnesia:transaction (Fun),
    ok.

is_expired (#session { created = Created }) ->
    Now = idealib_dt:now2us (),
    Ttl = idealib_dt:sec2us (?SESSION_LIFETIME),
    Expiry = idealib_dt:now2us (Created) + Ttl,
    Expiry < Now.

