-module (dws_websocket_manager).
-export ([
          register_transport/2,
          update_transport/1,
          find_all_transports/0,
          find_transport/1,
          discard_transport/1,
          wipe_inactive_transports/0,

          entry_to_map/1,
          entry_to_list/1
         ]).

%% TODO: - convert it to gen_server
%%       - monitor the WsTransportPID and discard its socket if it dies

-include_lib ("stdlib/include/qlc.hrl").
-include_lib ("dws_cluster_db.hrl").


register_transport (SessionID, WsTransportPID) ->
    Fun = fun () ->
                  mnesia:write (#?TABLE_SOCKET {
                                    session_id = SessionID,
                                    id = WsTransportPID
                                   })
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    ok.

update_transport (WsTransportPID) ->
    {ok, SocketEntry} = find_transport (WsTransportPID),
    NewSocketEntry = SocketEntry#?TABLE_SOCKET { last_used = now () },
    Fun = fun () ->
                  mnesia:write (NewSocketEntry)
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    ok.

find_all_transports () ->
    Fun = fun () ->
                  qlc:eval (qlc:q ([ X || X <- mnesia:table (?TABLE_SOCKET) ]))
          end,
    {atomic, Transports} = mnesia:transaction (Fun),
    {ok, Transports}.

find_transport (WsTransportPID) ->
    Fun = fun () ->
                  mnesia:read ({?TABLE_SOCKET, WsTransportPID})
          end,
    case mnesia:transaction (Fun) of
        {atomic, [SocketEntry]} ->
            {ok, SocketEntry};
        {atomic, []} ->
            {error, not_found};
        Error ->
            {error, Error}
    end.

discard_transport (WsTransportPID) ->
    Fun = fun () ->
                  mnesia:delete ({?TABLE_SOCKET, WsTransportPID})
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    ok.

wipe_inactive_transports () ->
    Fun = fun () ->
                  qlc:eval (qlc:q ([ ok = mnesia:delete ({?TABLE_SOCKET, X#?TABLE_SOCKET.id})
                                     || X <- mnesia:table (?TABLE_SOCKET),
                                        not is_transport_alive (X#?TABLE_SOCKET.id) ]))
          end,
    {atomic, _} = mnesia:transaction (Fun),
    ok.

entry_to_map (#?TABLE_SOCKET
              {
                id = ID,
                session_id = SessionID,
                created = Created,
                last_used = LastUsed,
                node = Node
              } = _Entry) ->
    #{
       id => ID,
       session_id => SessionID,
       created => Created,
       last_used => LastUsed,
       node => Node
     }.

entry_to_list (#?TABLE_SOCKET {} = Entry) ->
    maps:to_list (entry_to_map (Entry)).

%% =========

is_transport_alive (WsTransportPid) ->
    try
        process_info (WsTransportPid) =/= undefined
    catch
        _:_ -> false
    end.

