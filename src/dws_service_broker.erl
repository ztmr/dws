-module (dws_service_broker).
-behaviour (gen_server).

-define (SERVER, ?MODULE).

%% TODO:
%%   break the broker into the multiple separate gen_servers,
%%   each per a service

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
         start_link/1,
         dispatch/4,
         add_service_handler/2,
         get_service_handlers/0,
         flush_service_state/1
        ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([
         init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3
        ]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link (Args) ->
    gen_server:start_link ({local, ?SERVER}, ?MODULE, Args, []).

-type json_struct () :: {struct, [any ()]}.
-spec dispatch (SessionID::dws_session:session_id (),
                RequestData::proplists:proplist (),
                RequestInfo::proplists:proplist (),
                ChannelState::maps:map ()) ->
                       {Result::json_struct (),
                        NewChannelState::maps:map ()}.
dispatch (SessionID, Req, ReqInfo, #{ request_counter := ReqCtr } = ChannelState) ->
    Service = ensure_binary (proplists:get_value (<<"service">>, Req)),
    Call = ensure_atom (proplists:get_value (<<"call">>, Req)),
    Args = proplists:get_value (<<"args">>, Req, null),
    Id = ensure_binary (proplists:get_value (<<"id">>, Req, ReqCtr)),
    {ok, Result, NewChannelState} =
        gen_server:call (?SERVER, {call, SessionID, Service, Call,
                                   Args, ReqInfo, ChannelState}),
    Resp = {struct, [{id, Id}, {result, Result}]},
    {Resp, NewChannelState}.

add_service_handler (Service0, Mod) ->
    Service = ensure_binary (Service0),
    gen_server:call (?SERVER, {add_service_handler, Service, Mod}).

get_service_handlers () ->
    gen_server:call (?SERVER, {get_service_handlers}).

flush_service_state (Service0) ->
    Service = ensure_binary (Service0),
    gen_server:call (?SERVER, {flush_service_state, Service}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init (TableOwnRequest) when is_function (TableOwnRequest, 0) ->
    TableOwnRequest (),
    {ok, #{ ets => undefined, handlers => #{}, services => #{} }}.

handle_call (_Request, _From, #{ ets := undefined } = State) ->
    {reply, {error, waiting_for_state}, State};
handle_call ({call, SessionID, Service, Call, Args, ReqInfo, ChannelState} = _Request,
             _From, #{ handlers := Handlers,
                       services := Services } = State) ->
    ServiceState = get_service_state (Service, Services),
    error_logger:info_msg ("SVC ~p", [{Service, Handlers}]),
    case maps:find (Service, Handlers) of
        {ok, Mod} ->
            {Result, NewChannelState, NewServiceState} =
                do_service_call (Mod, Call, SessionID, Args, ReqInfo, ChannelState, ServiceState),
            NewServices = maps:put (Service, NewServiceState, Services),
            NewState = State#{ services => NewServices },
            {reply, {ok, Result, NewChannelState}, update_state (NewState)};
        error ->
            {reply, {ok, [{error, invalid_service}], ChannelState}, State}
    end;
handle_call ({get_service_handlers} = _Request,
             _From, #{ handlers := Handlers } = State) ->
    {reply, Handlers, State};
handle_call ({add_service_handler, Service, Mod} = _Request,
             _From, #{ handlers := Handlers,
                       services := Services } = State) ->
    ServiceState = get_service_state (Service, Services),
    NewHandlers = maps:put (Service, Mod, Handlers),
    NewServices = maps:put (Service, ServiceState, Services),
    NewState = State#{ services => NewServices, handlers => NewHandlers },
    {reply, ok, update_state (NewState)};
handle_call ({flush_service_state, Service} = _Request,
             _From, #{ services := Services } = State) ->
    NewState = State#{ services => maps:put (Service, #{}, Services) },
    {reply, ok, update_state (NewState)}.

handle_cast (_Msg, State) ->
    {noreply, State}.


handle_info ({timeout, _Ref, lazy_register_handlers}, State) ->
    lazy_register_handlers (),
    {noreply, State};
handle_info ({'ETS-TRANSFER', Tab, _FromPid, Context} = _Info, State) ->
    error_logger:info_msg ("~p: received ETS ownership request: ~p~n",
                           [?MODULE, _Info]),
    case Context of
        created -> ?SERVER ! lazy_register_handlers;
        reused  -> ok
    end,
    NewState = get_state (Tab, State),
    {noreply, NewState}.

terminate (_Reason, _State) ->
    ok.

code_change (_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-define (STATE_KEY, '$gen_server_state').

get_state (Tab, DefaultState) ->
    State = case ets:lookup (Tab, ?STATE_KEY) of
                [] -> DefaultState;
                [{?STATE_KEY, NewState}] -> NewState
            end,
    maps:put (ets, Tab, State).

update_state (#{ ets := Tab } = State) ->
    true = ets:insert (Tab, {?STATE_KEY, State}),
    State.

lazy_register_handlers () ->
    spawn (fun register_handlers/0).

register_handlers () ->
    case application:get_env (dws, broker_handlers) of
        {ok, Handlers} ->
            [ ok = add_service_handler (Svc, Mod)
              || {Svc, Mod} <- Handlers ];
        undefined ->
            ok
    end.

do_service_call (Mod, Call, SessionID, Args, ReqInfo, ChannelState, ServiceState) ->
    Functions = Mod:module_info (functions),
    Arity = lists:max (proplists:get_all_values (Call, Functions)),
    N = fun (X) -> normalize_service_call_result (X, ChannelState, ServiceState) end,
    case Arity of
        5 ->
            N (Mod:Call (SessionID, Args, ReqInfo, ChannelState, ServiceState));
        4 ->
            N (Mod:Call (SessionID, Args, ReqInfo, ChannelState));
        3 ->
            N (Mod:Call (SessionID, Args, ReqInfo));
        2 ->
            N (Mod:Call (SessionID, Args));
        1 ->
            N (Mod:Call (SessionID))
    end.

normalize_service_call_result ({ok, R, ChanState, SvcState}, _, _) -> {R, ChanState, SvcState};
normalize_service_call_result ({ok, R, ChanState}, _, SvcState) -> {R, ChanState, SvcState};
normalize_service_call_result ({ok, R}, ChanState, SvcState) -> {R, ChanState, SvcState}.

get_service_state (Service, Services) ->
    case maps:find (Service, Services) of
        {ok, SvcState} -> SvcState;
        error          -> #{}
    end.

ensure_binary (X) when is_binary (X) -> X;
ensure_binary (X) when is_list (X) -> list_to_binary (X);
ensure_binary (X) when is_integer (X) -> list_to_binary (integer_to_list (X));
ensure_binary (X) when is_atom (X) -> atom_to_binary (X, unicode).

ensure_atom (X) when is_atom (X) -> X;
ensure_atom (X) when is_list (X) -> list_to_atom (X);
ensure_atom (X) when is_binary (X) -> binary_to_atom (X, unicode).

