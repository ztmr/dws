-ifndef (DWS_CLUSTER_DB_HRL).
-define (DWS_CLUSTER_DB_HRL, true).

-define (TABLE_SESSION,   dws_session).
-define (TABLE_SOCKET,    dws_socket).
-define (TABLE_LOCK,      dws_lock).

-define (WAIT_FOR_TABLES, 5000).

-record (?TABLE_SESSION, {
           id = <<>> :: binary (),
           created = erlang:timestamp (),
           state = #{} :: map ()
          }).

-record (?TABLE_SOCKET, {
           id = self () :: pid (),
           session_id = <<>> :: binary (),
           created = erlang:timestamp (),
           last_used = erlang:timestamp (),
           node = node ()
          }).

-record (?TABLE_LOCK, {
           id = <<>> :: binary (),
           owner_pid = self () :: pid (),
           created = erlang:timestamp ()
          }).

-endif. %% DWS_SESSION_HRL
