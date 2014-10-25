-module (dws_lock_manager).
-export ([
          acquire_lock/2,
          release_lock/1,
          find_lock/1,
          find_all_locks/0,
          wipe_dead_locks/0
         ]).

%% XXX: do we need to convert it to the gen_server?

-include_lib ("stdlib/include/qlc.hrl").
-include_lib ("dws_cluster_db.hrl").


acquire_lock (Resource, WsTransportPID) ->
    case find_lock (Resource) of
        {error, _} ->
            try_acquire_lock (Resource, WsTransportPID);
        {ok, #?TABLE_LOCK { owner_pid = WsTransportPID }} ->
            ok;  % already locked by the same PID, no problem...
        {ok, LockEntry} ->
            {error, {already_locked, LockEntry}}
    end.

find_all_locks () ->
    Fun = fun () ->
                  qlc:eval (qlc:q ([ X || X <- mnesia:table (?TABLE_LOCK) ]))
          end,
    {atomic, Transports} = mnesia:transaction (Fun),
    {ok, Transports}.

find_lock (Resource) ->
    Fun = fun () ->
                  mnesia:read ({?TABLE_LOCK, Resource})
          end,
    case mnesia:transaction (Fun) of
        {atomic, [LockEntry]} ->
            {ok, LockEntry};
        {atomic, []} ->
            {error, not_found};
        Error ->
            {error, Error}
    end.

release_lock (Resource) ->
    Fun = fun () ->
                  mnesia:delete ({?TABLE_LOCK, Resource})
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    ok.

wipe_dead_locks () ->
    Fun = fun () ->
                  qlc:eval (qlc:q ([ ok = mnesia:delete ({?TABLE_LOCK, X#?TABLE_LOCK.id})
                                     || X <- mnesia:table (?TABLE_LOCK),
                                        not is_lock_owner_alive (X#?TABLE_LOCK.owner_pid) ]))
          end,
    {atomic, _} = mnesia:transaction (Fun),
    ok.

%% --- Private internal functions ---

is_lock_owner_alive (WsTransportPid) ->
    process_info (WsTransportPid) =/= undefined.

try_acquire_lock (Resource, WsTransportPID) ->
    case is_lock_owner_alive (WsTransportPID) of
        true ->
            perform_acquire_lock (Resource, WsTransportPID);
        false ->
            {error, invalid_lock_owner}
    end.

perform_acquire_lock (Resource, WsTransportPID) ->
    Fun = fun () ->
                  mnesia:write (#?TABLE_LOCK {
                                    id = Resource,
                                    owner_pid = WsTransportPID
                                   })
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    ok.

