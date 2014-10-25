-module (dws_app).
-behaviour (application).

%% Application callbacks
-export ([start/2, stop/1]).

-define (APP, dws).

%% ===================================================================
%% Application callbacks
%% ===================================================================
start (_StartType, _StartArgs) ->
    {ok, Port} = application:get_env (?APP, listen_port),
    {ok, Routes} = application:get_env (?APP, routes),
    Dispatch = cowboy_router:compile (Routes),
    {ok, _} = cowboy:start_http (dws_http, 100, [{port, Port}],
                                 [{env, [{dispatch, Dispatch}]},
                                  {onrequest, fun dws_session_handler:on_request/1}]),
    dws_cluster_db:init (),
    dws_sup:start_link ().

stop (_State) ->
    cowboy:stop_listener (dws_http),
    ok.

