-module (dws_session).
-export ([
          init/0,
          install/0, install/1,

          create_session/0,
          set_session_data/2,
          get_session_data/1,
          drop_session/1,
          wipe_sessions/0
         ]).

-include_lib ("stdlib/include/qlc.hrl").

-define (SESSION_LIFETIME, 24*60*60). %% 1day in secs

-record (session, {
           id = <<>> :: binary (),
           created = now (),
           state = #{} :: map ()
          }).

init () ->
    case mnesia:wait_for_tables ([session], 5000) of
        ok ->
            error_logger:info_msg ("Distributed session storage started...");
        {timeout, [session]} ->
            error_logger:info_msg ("Distributed session storage needs to be initialized!"),
            install ()
    end.

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

create_session () ->
    Id = list_to_binary (idealib_crypto:hash_hex (sha, crypto:rand_bytes (2048))),
    Fun = fun () ->
                  mnesia:write (#session { id = Id })
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    {ok, Id}.

set_session_data (SessionID, Data) when is_list (SessionID) ->
    set_session_data (list_to_binary (SessionID), Data);
set_session_data (SessionID, Data) when is_binary (SessionID) ->
    Fun = fun () ->
                  mnesia:write (#session { id = SessionID, state = Data })
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    ok.

get_session_data (SessionID) when is_list (SessionID) ->
    get_session_data (list_to_binary (SessionID));
get_session_data (SessionID) when is_binary (SessionID) ->
    Fun = fun () ->
                  mnesia:read ({session, SessionID})
          end,
    case mnesia:transaction (Fun) of
        {atomic, [#session { state = Data }]} -> {ok, Data};
        {atomic, []} -> {error, not_found};
        Error -> {error, Error}
    end.

drop_session (SessionID) when is_list (SessionID) ->
    drop_session (list_to_binary (SessionID));
drop_session (SessionID) when is_binary (SessionID) ->
    Fun = fun () ->
                  mnesia:delete ({session, SessionID})
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    ok.

wipe_sessions () ->
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

