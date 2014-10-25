-module (dws_service_broker_test).
-compile (export_all).

-include_lib ("eunit/include/eunit.hrl").

persistent_state_test_ () ->
    {timeout, 15, ?_assertEqual (ok, persistent_state ())}.

persistent_state () ->
    setup (),
    SvcID = <<"TMR.API">>,
    OrigPid = whereis (dws_service_broker),

    OrigHandlers = maps:keys (dws_service_broker:get_service_handlers ()),
    dws_service_broker:add_service_handler (SvcID, dws_service_example),

    NewHandlers = maps:keys (dws_service_broker:get_service_handlers ()),
    ?assertEqual ([SvcID], NewHandlers -- OrigHandlers),

    %% Let's crash the Service Broker
    dws_service_broker ! lets_crash_together_my_dear,

    %% Wait for some time to restart the server
    %% (1s is too much, but just to be sure)
    timer:sleep (1000),

    NewPid = whereis (dws_service_broker),
    ?assertNotEqual (OrigPid, NewPid),

    %% Did the original state got back?
    NewHandlers2 = maps:keys (dws_service_broker:get_service_handlers ()),
    ?assertEqual ([SvcID], NewHandlers2 -- OrigHandlers),

    teardown ([]),
    ok.

%% ====================================================================
%% Setup and Teardown
%% ====================================================================

setup () ->
    application:ensure_all_started (dws).

teardown (_) ->
    application:stop (dws).

