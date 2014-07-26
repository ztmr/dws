-module (dws_websocket_handler).
-behaviour (cowboy_websocket_handler).

-export ([init/3]).
-export ([websocket_init/3]).
-export ([websocket_handle/3]).
-export ([websocket_info/3]).
-export ([websocket_terminate/3]).

-define (MAX_MSG_CTR, 9007199254740992). %% 2^53
-define (HDR_WS_SUBPROTO, <<"sec-websocket-protocol">>).

init ({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

websocket_init (_TransportName, Req, _Opts) ->
    SessionID = dws_session_handler:get_session (Req),
    lager:debug ("Client [~ts] connected.", [SessionID]),
    negotiate_subprotocol (Req, SessionID).

websocket_handle ({text, RawMsg}, Req, #{ request_counter := ReqCtr } = State) ->
    SessionID = dws_session_handler:get_session (Req),
    lager:debug ("Client [~ts] request: ~ts", [SessionID, RawMsg]),
    %% It came from client, so let's catch a potential error
    DecodedMsg = decode_message (RawMsg, State),
    NewState0 = State#{ request_counter => ReqCtr+1 rem ?MAX_MSG_CTR },
    ReqInfo = make_cowboy_request_info (Req),
    {Response, NewState} = process_request (SessionID, DecodedMsg, ReqInfo, NewState0),
    ResponseEncoded = encode_message (Response, State),
    {reply, {text, ResponseEncoded}, Req, NewState}.

websocket_info (_Info, Req, State) ->
    {ok, Req, State}.

websocket_terminate (_Reason, Req, #{ request_counter := ReqCtr } = _State) ->
    SessionID = dws_session_handler:get_session (Req),
    lager:debug ("Client [~ts] disconnected after ~w requests.",
                 [SessionID, ReqCtr]),
    ok.


%%======================================================================
%% Internal functions
%%======================================================================

initialize_state () ->
    initialize_state (hd (supported_subprotocol_names ())).

initialize_state (SubProtocolName) ->
    SubProto = supported_subprotocol_by_name (SubProtocolName),
    #{ request_counter => 1, data => undefined, subprotocol => SubProto }.

supported_subprotocol_by_name (SubProtocolName) ->
    maps:get (SubProtocolName, supported_subprotocols ()).

supported_subprotocol_names () ->
    maps:keys (supported_subprotocols ()).

%% TODO: add subprotocol plugin options to the `sys.config'
supported_subprotocols () ->
    #{
       <<"json">>     => #{ codec_module => dws_message_codec_json },
       <<"msgpack">>  => #{ codec_module => dws_message_codec_msgpack }
     }.

find_subprotocol_match ([], _ServerSubProtocols) -> {error, no_matching_subprotocols};
find_subprotocol_match ([H|T] = _ClientSubProtocols, ServerSubProtocols) ->
    case lists:member (H, ServerSubProtocols) of
        true  -> {ok, H};
        false -> find_subprotocol_match (T, ServerSubProtocols)
    end.

negotiate_subprotocol (Req, SessionID) ->
    case cowboy_req:parse_header (?HDR_WS_SUBPROTO, Req) of
        {ok, undefined, _Req2} ->
            {ok, Req, initialize_state ()};
        {ok, ClientSubProtocols, Req2} ->
            ServerSubprotocols = supported_subprotocol_names (),
            case find_subprotocol_match (ClientSubProtocols, ServerSubprotocols) of
                {ok, SubProto} ->
                    Req3 = cowboy_req:set_resp_header (?HDR_WS_SUBPROTO, SubProto, Req2),
                    lager:info ("Client [~ts] negotiated subprotocol: ~p.", [SessionID, SubProto]),
                    {ok, Req3, initialize_state (SubProto)};
                {error, _} ->
                    lager:error ("Client [~ts] subprotocol negotiation failed!", [SessionID]),
                    lager:debug ("Client [~ts] offered subprotocols ~p while the server supports ~p.",
                                 [ClientSubProtocols, ServerSubprotocols]),
                    {shutdown, Req2}
            end
    end.

decode_message (RawMsg, #{ subprotocol := #{ codec_module := Codec } }) ->
    catch (Codec:decode (RawMsg)).

encode_message (Msg, #{ subprotocol := #{ codec_module := Codec } }) ->
    Codec:encode (Msg).

process_request (SessionID, {struct, MsgData}, ReqInfo, State) ->
    %% Looks fine, so let's process it!
    dws_service_broker:dispatch (SessionID, MsgData, ReqInfo, State);
process_request (_SessionID, {'EXIT', _Reason}, _ReqInfo, State) ->
    %% Couldn't even parse the message
    {{struct, [{error, cannot_parse}]}, State};
process_request (_SessionID, _Whatever, _ReqInfo, State) ->
    %% Message parsed, but it is not a valid request object (structure)
    {{struct, [{error, invalid_structure}]}, State}.

make_cowboy_request_info (Req) ->
    Keys = [cookies, headers, peer, host, host_info, host_url,
            method, path, path_info, port, qs, qs_vals, url,
            version],
    Get = fun (M, R) -> element (1, cowboy_req:M (R)) end,
    maps:from_list ([ {Key, Get (Key, Req)} || Key <- Keys ]).

