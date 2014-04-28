-ifndef (DWS_SESSION_HRL).
-define (DWS_SESSION_HRL, true).

-define (TABLE,                      session).
-define (WAIT_FOR_TABLES,               5000).

%% XXX: to be moved to the system configuration
-define (SESSION_LIFETIME,          24*60*60). %% 1d in secs
-define (AUTOWIPE_SESSION_INTERVAL,    60*60). %% 1h in secs

-record (session, {
           id = <<>> :: binary (),
           created = now (),
           state = #{} :: map ()
          }).

-endif. %% DWS_SESSION_HRL
