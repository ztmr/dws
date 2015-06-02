-module (dws_app).
-behaviour (application).

%% Application callbacks
-export ([start/2, stop/1]).

-define (APP, dws).

%% ===================================================================
%% Application callbacks
%% ===================================================================
start (_StartType, _StartArgs) ->
    {ok, Routes} = application:get_env (?APP, routes),
    Dispatch = cowboy_router:compile (Routes),
    true = lists:foldl (fun (X, Acc) -> Acc or X end, false,
                        [ BootFun (Dispatch) /= not_started
                          || BootFun <- [ fun start_http/1,
                                          fun start_https/1 ] ]),
    dws_cluster_db:init (),
    dws_sup:start_link ().

start_http (Dispatch) ->
    case application:get_env (?APP, http_listener) of
        {ok, HttpOpts} when is_list (HttpOpts) ->
            start_listener (http, Dispatch, HttpOpts);
        undefined ->
            case application:get_env (?APP, listen_port) of
                {ok, Port} ->
                    start_listener (http, Dispatch, [{port, Port}]);
                undefined  -> not_started
            end
    end.

start_https (Dispatch) ->
    case application:get_env (?APP, https_listener) of
        {ok, HttpsOpts} when is_list (HttpsOpts) ->
            start_listener (https, Dispatch, HttpsOpts);
        undefined ->
            not_started
    end.

start_listener (http, Dispatch, Opts) ->
    {ok, _} = cowboy:start_http (dws_http, 100, Opts,
                                 [{env, [{dispatch, Dispatch}]},
                                  {onrequest, fun dws_session_handler:on_request/1}]);
start_listener (https, Dispatch, Opts) ->
    {ok, _} = cowboy:start_https (dws_https, 100, Opts,
                                  [{env, [{dispatch, Dispatch}]},
                                   {onrequest, fun dws_session_handler:on_request/1}]).

stop (_State) ->
    cowboy:stop_listener (dws_http),
    cowboy:stop_listener (dws_https),
    ok.

