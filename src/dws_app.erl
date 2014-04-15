-module (dws_app).
-behaviour (application).

%% Application callbacks
-export ([start/2, stop/1]).

-define (APP, dws).

%% ===================================================================
%% Application callbacks
%% ===================================================================
start(_StartType, _StartArgs) ->
    {ok, Port} = application:get_env (?APP, listen_port),
    Routes = [{'_', [
                     {"/", cowboy_static, {priv_file, ?APP, "index.html"}},
                     {"/ws", dws_websocket_handler, []},
                     {"/static/[...]", cowboy_static, {priv_dir, ?APP, "static"}}
                    ]}],
    Dispatch = cowboy_router:compile (Routes),
    {ok, _} = cowboy:start_http (http, 100, [{port, Port}],
                                 [{env, [{dispatch, Dispatch}]},
                                  {onrequest, fun dws_session_handler:on_request/1}]),
    dws_sup:start_link ().

stop (_State) ->
    ok.

