-module (dws_websocket_handler).
-behaviour (cowboy_websocket_handler).

-export ([init/3]).
-export ([websocket_init/3]).
-export ([websocket_handle/3]).
-export ([websocket_info/3]).
-export ([websocket_terminate/3]).

-define (MAX_MSG_CTR, 9007199254740992). %% 2^53

init ({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

websocket_init (_TransportName, Req, _Opts) ->
    SessionID = dws_session_handler:get_session (Req),
    error_logger:info_msg ("Client [~ts] connected.", [SessionID]),
    {ok, Req, #{ request_counter => 1, data => undefined }}.

websocket_handle ({text, JsonMsg}, Req, #{ request_counter := ReqCtr } = State) ->
    SessionID = dws_session_handler:get_session (Req),
    error_logger:info_msg ("Client [~ts] request: ~ts", [SessionID, JsonMsg]),
    %% It came from client, so let's catch a potential error
    DecodedMsg = (catch (mochijson2:decode (JsonMsg))),
    NewState0 = State#{ request_counter => ReqCtr+1 rem ?MAX_MSG_CTR },
    ReqInfo = make_cowboy_request_info (Req),
    {Response, NewState} = process_request (SessionID, DecodedMsg, ReqInfo, NewState0),
    ResponseJson = mochijson2:encode (Response),
    {reply, {text, ResponseJson}, Req, NewState}.

websocket_info (_Info, Req, State) ->
    {ok, Req, State}.

websocket_terminate (_Reason, Req, #{ request_counter := ReqCtr } = _State) ->
    SessionID = dws_session_handler:get_session (Req),
    error_logger:info_msg ("Client [~ts] disconnected after ~w requests.",
                           [SessionID, ReqCtr]),
    ok.

process_request (SessionID, {struct, MsgData}, ReqInfo, State) ->
    %% Looks fine, so let's process it!
    dws_service_broker:dispatch (SessionID, MsgData, ReqInfo, State);
process_request (_SessionID, {'EXIT', _Reason}, _ReqInfo, State) ->
    %% Couldn't even parse the message
    {{struct, [{error, cannot_parse}]}, State};
process_request (_SessionID, _Whatever, _ReqInfo, State) ->
    %% Message parsed, but it is not a valid request object (structure)
    {{struct, [{error, invalid_json}]}, State}.

make_cowboy_request_info (Req) ->
    Keys = [cookies, headers, peer, host, host_info, host_url,
            method, path, path_info, port, qs, qs_vals, url,
            version],
    Get = fun (M, R) -> element (1, cowboy_req:M (R)) end,
    maps:from_list ([ {Key, Get (Key, Req)} || Key <- Keys ]).

