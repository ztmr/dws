-module (dws_websocket_handler).
-behaviour (cowboy_websocket_handler).

-export ([
          init/2,
          websocket_handle/3,
          websocket_info/3,
          terminate/3
         ]).

-export ([
          notify_client/2,
          force_disconnect/1
         ]).

-define (MAX_MSG_CTR, 9007199254740992). %% 2^53
-define (HDR_WS_SUBPROTO, <<"sec-websocket-protocol">>).

init (Req, _Opts) ->
    SessionID = dws_session_handler:get_session (Req),
    lager:debug ("Client [~ts] connected.", [SessionID]),
    dws_websocket_manager:register_transport (SessionID, self ()),
    negotiate_subprotocol (Req, SessionID).

websocket_handle ({text, RawMsg}, Req, #{ request_counter := ReqCtr } = State) ->
    try
        SessionID = dws_session_handler:get_session (Req),
        lager:debug ("Client [~ts] request: ~ts", [SessionID, RawMsg]),
        dws_websocket_manager:update_transport (self ()),
        %% It came from client, so let's catch a potential error
        DecodedMsg = decode_message (RawMsg, State),
        NewState0 = State#{
                      request_counter => ReqCtr+1 rem ?MAX_MSG_CTR,
                      transport_pid   => self ()
                     },
        ReqInfo = make_cowboy_request_info (Req),
        {Response, NewState} = process_request (SessionID, DecodedMsg, ReqInfo, NewState0),
        ResponseEncoded = encode_message (Response, NewState),
        lager:debug ("Client [~ts] response: ~ts", [SessionID, ResponseEncoded]),
        {reply, {text, ResponseEncoded}, Req, NewState}
    catch
        EClass:EReason ->
            lager:error ("InternalError: ~w.~w: ~p~n", [EClass, EReason, erlang:get_stacktrace ()]),
            ErrMsg = encode_message ({struct, [{error, internal_error}]}, State),
            {reply, {text, ErrMsg}, Req, State}
    end.

websocket_info ({notify_client, Msg}, Req, State) ->
    EncodedMsg = encode_message (Msg, State),
    {reply, {text, EncodedMsg}, Req, State};
websocket_info (force_disconnect, Req, State) ->
    {reply, close, Req, State};
websocket_info (_Info, Req, State) ->
    {ok, Req, State}.

terminate (_Reason, Req, #{ request_counter := ReqCtr } = _State) ->
    SessionID = dws_session_handler:get_session (Req),
    lager:debug ("Client [~ts] disconnected after ~w requests.",
                 [SessionID, ReqCtr]),
    dws_websocket_manager:discard_transport (self ()),
    dws_websocket_manager:wipe_inactive_transports (),
    ok;
terminate (_, _, _) -> ok.

notify_client (WsTransportPid, Message) ->
    WsTransportPid ! {notify_client, Message},
    ok.

force_disconnect (WsTransportPid) ->
    WsTransportPid ! force_disconnect,
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
    case cowboy_req:parse_header (?HDR_WS_SUBPROTO, Req, undefined) of
        undefined ->
            {cowboy_websocket, Req, initialize_state ()};
        ClientSubProtocols ->
            ServerSubprotocols = supported_subprotocol_names (),
            case find_subprotocol_match (ClientSubProtocols, ServerSubprotocols) of
                {ok, SubProto} ->
                    Req2 = cowboy_req:set_resp_header (?HDR_WS_SUBPROTO, SubProto, Req),
                    lager:info ("Client [~ts] negotiated subprotocol: ~p.", [SessionID, SubProto]),
                    {cowboy_websocket, Req2, initialize_state (SubProto)};
                {error, _} ->
                    lager:error ("Client [~ts] subprotocol negotiation failed!", [SessionID]),
                    lager:debug ("Client [~ts] offered subprotocols ~p while the server supports ~p.",
                                 [ClientSubProtocols, ServerSubprotocols]),
                    {shutdown, Req}
            end
    end.

decode_message (RawMsg, #{ subprotocol := #{ codec_module := Codec } }) ->
    catch (Codec:decode (RawMsg)).

encode_message (Msg, #{ subprotocol := #{ codec_module := Codec } }) ->
    iolist_to_binary (Codec:encode (Msg)).

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
    Keys = [bindings, {parse_cookies, cookies},
            headers, peer, host, host_info, host_url,
            method, path, path_info, port, qs, url,
            version],
    Get = fun
              ({M0, M1}, R) -> {M1, cowboy_req:M0 (R)};
              (M, R) -> {M, cowboy_req:M (R)}
          end,
    maps:from_list ([ Get (Key, Req) || Key <- Keys ]).

