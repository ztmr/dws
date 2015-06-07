-module (dws_app).
-behaviour (application).

%% Application callbacks
-export ([start/2, stop/1, reload_routes/0]).

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
                                  {middlewares, [cowboy_router, dws_session_handler, cowboy_handler]},
                                  {onresponse, get_response_handler ()}]);
start_listener (https, Dispatch, Opts) ->
    {ok, _} = cowboy:start_https (dws_https, 100, Opts,
                                  [{env, [{dispatch, Dispatch}]},
                                   {middlewares, [cowboy_router, dws_session_handler, cowboy_handler]},
                                   {onresponse, get_response_handler ()}]).

get_response_handler () ->
    case application:get_env (?APP, http_onresponse) of
        {ok, {Module, Function}} ->
            fun Module:Function/4;
        _ ->
            undefined
    end.

is_valid_file (File) ->
    filelib:is_file (File) andalso not filelib:is_dir (File).

find_config_file () ->
    Config = proplists:get_value (config, init:get_arguments (), "sys"),
    case is_valid_file (Config) of
        true ->
            {ok, Config};
        false ->
            Config1 = Config ++ ".config",
            case is_valid_file (Config1) of
                true ->
                    {ok, Config1};
                false ->
                    error
            end
    end.

reload_routes () ->
    {ok, ConfigFile} = find_config_file (),
    {ok, [Config]} = file:consult (ConfigFile),
    DWSConfig = proplists:get_value (dws, Config),
    Routes = proplists:get_value (routes, DWSConfig),
    Dispatch = cowboy_router:compile (Routes),
    [ catch (cowboy:set_env (Listener, dispatch, Dispatch))
      || Listener <- [dws_http, dws_https] ],
    ok.

stop (_State) ->
    cowboy:stop_listener (dws_http),
    cowboy:stop_listener (dws_https),
    ok.

