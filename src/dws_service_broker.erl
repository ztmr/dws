-module (dws_service_broker).
-behaviour (gen_server).

-define (SERVER, ?MODULE).
-define (WAITING4STATE, '$WaitingForState').

%% TODO:
%%   break the broker into the multiple separate gen_servers,
%%   each per a service

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
         start_link/1,
         dispatch/4,
         notify_client/3,
         add_service_handler/2,
         add_service_handler_async/2,
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

-type dws_request_object () :: {struct, [{atom (), any ()}]}.
-type dws_response_object () :: {struct, [{atom (), any ()}]}.
-spec dispatch (SessionID::dws_session:session_id (),
                RequestData::dws_request_object (),
                RequestInfo::proplists:proplist (),
                ChannelState::maps:map ()) ->
                       {Result::dws_response_object (),
                        NewChannelState::maps:map ()}.
dispatch (SessionID, Req, ReqInfo, #{ request_counter := ReqCtr } = ChannelState) ->
    Timeout = application:get_env (dws, service_broker_timeout, 10000),
    case parse_request (Req, ReqCtr) of
        {ok, ProtoVsn, MsgId, Service, Call, Args} ->
            {ok, Result, NewChannelState} =
                gen_server:call (?SERVER, {call, SessionID, Service, Call,
                                           Args, ReqInfo, ChannelState}, Timeout),
            Resp = format_response (ProtoVsn, MsgId, Result),
            {Resp, NewChannelState};
        {error, ProtoVsn, MsgId, Error} ->
            lager:debug ("Malformed client request: ~w", [{ProtoVsn, MsgId, Error}]),
            Resp = format_response (ProtoVsn, MsgId, {error, [Error]}),
            {Resp, ChannelState}
    end.

notify_client (WsTransportId, MsgBody, EventClass) ->
    Msg = {struct, [
                    {type, <<"event">>},
                    {class, EventClass},
                    {data, MsgBody}
                   ]},
    dws_websocket_handler:notify_client (WsTransportId, Msg).

add_service_handler (Service0, Mod) ->
    Service = ensure_binary (Service0),
    gen_server:call (?SERVER, {add_service_handler, Service, Mod}).

add_service_handler_async (Services, Mod) when is_list (Services), is_atom (Mod) ->
    [ add_service_handler_async (S, Mod) || S <- Services ],
    ok;
add_service_handler_async (Service0, Mod) when is_binary (Service0), is_atom (Mod) ->
    Service = ensure_binary (Service0),
    do_async_call_until_success ({add_service_handler, Service, Mod}, 500).

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
    {reply, {error, ?WAITING4STATE}, State};
handle_call ({call, SessionID, Service, Call, Args, ReqInfo, ChannelState} = _Request,
             _From, #{ handlers := Handlers,
                       services := Services } = State) ->
    ServiceState = get_service_state (Service, Services),
    lager:debug ("Service Call Request ~p", [{SessionID, Service, Call, Args}]),
    case maps:find (Service, Handlers) of
        {ok, Mod} ->
            try
                {Result, NewChannelState, NewServiceState} =
                    do_service_call (Mod, Call, SessionID, Args, ReqInfo, ChannelState, ServiceState),
                NewServices = maps:put (Service, NewServiceState, Services),
                NewState = State#{ services => NewServices },
                {reply, {ok, Result, NewChannelState}, update_state (NewState)}
            catch
                E0:E1 ->
                    lager:error ("ImplementationError: ~w.~w: ~p~n", [E0, E1, erlang:get_stacktrace ()]),
                    {reply, {ok, [{error, implementation_error}], ChannelState}, State}
            end;
        error ->
            lager:warning ("InvalidService: ~s~n", [Service]),
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


handle_info (lazy_register_handlers, State) ->
    lazy_register_handlers (),
    {noreply, State};
handle_info ({'ETS-TRANSFER', Tab, _FromPid, Context} = _Info, State) ->
    lager:info ("~p: received ETS ownership request: ~p~n", [?MODULE, _Info]),
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

normalize_service_call_result (ok, ChanState, SvcState) -> {{ok, []}, ChanState, SvcState};
normalize_service_call_result ({ok, R, ChanState, SvcState}, _, _) -> {{ok, R}, ChanState, SvcState};
normalize_service_call_result ({ok, R, ChanState}, _, SvcState) -> {{ok, R}, ChanState, SvcState};
normalize_service_call_result ({ok, R}, ChanState, SvcState) -> {{ok, R}, ChanState, SvcState};
normalize_service_call_result ({error, R, ChanState, SvcState}, _, _) -> {{error, R}, ChanState, SvcState};
normalize_service_call_result ({error, R, ChanState}, _, SvcState) -> {{error, R}, ChanState, SvcState};
normalize_service_call_result ({error, R}, ChanState, SvcState) -> {{error, R}, ChanState, SvcState}.

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

%% Protocols V1 and V2 are compatible when it comes to response
format_response (_ProtoVsn, MsgId, {ok, Result}) ->
    {struct, [{id, MsgId}, {type, <<"rpc">>}, {success, true}, {result, Result}]};
format_response (_ProtoVsn, MsgId, {error, Reason}) ->
    {struct, [{id, MsgId}, {type, <<"rpc">>}, {success, false}, {reason, Reason}]}.

parse_request (Req, ReqCtr) ->
    ProtoVsn = idealib_conv:x2int0 (proplists:get_value (<<"proto">>, Req, 0)),
    parse_request_proto (ProtoVsn, Req, ReqCtr).

parse_request_proto (0, Req, ReqCtr) ->
    %% The legacy protocol was not versioned originally
    parse_request_proto (1, Req, ReqCtr);
parse_request_proto (1 = ProtoVsn, Req, ReqCtr) ->
    %% The legacy protocol is marked as protocol V1
    MsgId = ensure_binary (proplists:get_value (<<"id">>, Req, ReqCtr)),
    %% NOTE: ONLY cmd='call' is supported, let's crash on anything else!
    case ensure_binary (proplists:get_value (<<"cmd">>, Req)) of
        <<"call">> ->
            Service = ensure_binary (proplists:get_value (<<"ns">>, Req)),
            Call = ensure_atom (proplists:get_value (<<"method">>, Req)),
            Args = proplists:get_value (<<"args">>, Req, null),
            {ok, ProtoVsn, MsgId, Service, Call, Args};
        Cmd ->
            {error, ProtoVsn, MsgId, {unsupported_legacy_command, Cmd}}
    end;
parse_request_proto (ProtoVsn, Req, ReqCtr) when ProtoVsn > 1 ->
    %% The only known protocol newer than the V1 is V2 so use it if
    %% the version number higher than 1 was supplied by the client
    Service = ensure_binary (proplists:get_value (<<"service">>, Req)),
    Call = ensure_atom (proplists:get_value (<<"call">>, Req)),
    Args = proplists:get_value (<<"args">>, Req, null),
    MsgId = ensure_binary (proplists:get_value (<<"id">>, Req, ReqCtr)),
    {ok, ProtoVsn, MsgId, Service, Call, Args}.

do_async_call_until_success (Request, RetryTimeout) ->
    do_async_call_until_success (Request, RetryTimeout, undefined).

do_async_call_until_success (Request, RetryTimeout, CallBack) ->
    spawn (fun () ->
                   do_async_call_until_success_worker (Request, RetryTimeout, CallBack)
           end),
    ok.

do_async_call_until_success_worker (Request, RetryTimeout, CallBack) ->
    do_async_call_until_success_worker_ (whereis (?SERVER), Request, RetryTimeout, CallBack).

do_async_call_until_success_worker_ (undefined, Request, RetryTimeout, CallBack) ->
    %% The server process does not seem to exist in registry
    %% Making gen_server:call on it would crash on `noproc' error.
    do_async_call_until_success_worker (Request, RetryTimeout, CallBack);
do_async_call_until_success_worker_ (Server, Request, RetryTimeout, CallBack) ->
    %% Is the server ready to accept requests yet? Do we have to wait anymore?
    case catch (gen_server:call (Server, Request)) of
        {error, ?WAITING4STATE} ->
            timer:sleep (RetryTimeout),
            do_async_call_until_success_worker (Request, RetryTimeout, CallBack);
        Result when is_function (CallBack, 1) ->
            CallBack (Result);
        _Result ->
            ok
    end.

