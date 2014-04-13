-module (dws_websocket_handler).
-behaviour (cowboy_websocket_handler).

%% TODO:
%%   - chat service API and protocol

-export ([init/3]).
-export ([websocket_init/3]).
-export ([websocket_handle/3]).
-export ([websocket_info/3]).
-export ([websocket_terminate/3]).

init ({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

websocket_init (_TransportName, Req, _Opts) ->
    SessionID = dws_session_handler:get_session (Req),
    {ok, Data} = dws_session:get_session_data (SessionID),
    dws_session:set_session_data (SessionID, Data#{ history => [] }),
    error_logger:info_msg ("Client connected: ~ts", [SessionID]),
    {ok, Req, #{ request_counter => 1 }}.

websocket_handle ({text, Msg}, Req, #{ request_counter := ReqCtr } = State) ->
    SessionID = dws_session_handler:get_session (Req),
    error_logger:info_msg ("Client request: ~ts", [SessionID]),
    {ok, #{ history := History } = Data} = dws_session:get_session_data (SessionID),
    NewHistory = [{now (), node (), Msg}|History],
    NewData = Data#{ history => NewHistory },
    dws_session:set_session_data (SessionID, NewData),
    NewReqCtr = ReqCtr+1,
    JsonHist = {array, [
                        {struct,
                         [{ts, list_to_binary (idealib_dt:dt2iso (idealib_dt:now2dt (Ts)))},
                          {node, Node},
                          {msg, M}]}
                        || {Ts, Node, M} <- NewHistory ]},
    Response = mochijson2:encode ({struct, [
                                            {msg, Msg},
                                            {node, node ()},
                                            {ctr, NewReqCtr},
                                            {sid, SessionID},
                                            {history, JsonHist}
                                           ]}),
    NewState = State#{ request_counter => NewReqCtr },
    {reply, {text, Response}, Req, NewState }.

websocket_info (_Info, Req, State) ->
    {ok, Req, State}.

websocket_terminate (_Reason, Req, _State) ->
    SessionID = dws_session_handler:get_session (Req),
    error_logger:info_msg ("Client disconnected: ~ts", [SessionID]),
    ok.

