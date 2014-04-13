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
    start_node_discovery (),
    dws_session:init (),
    {ok, _} = cowboy:start_http (http, 100, [{port, Port}],
                                 [{env, [{dispatch, Dispatch}]},
                                  {onrequest, fun dws_session_handler:on_request/1}]),
    dws_sup:start_link ().

stop (_State) ->
    ok.


start_node_discovery () ->
    %spawn (fun node_discovery_loop/0).
    spawn (fun discover_neighbours/0).

%node_discovery_loop () ->
%    discover_neighbours (),
%    timer:sleep (30000),
%    node_discovery_loop ().

discover_neighbours () ->
    {ok, Neighbours} = net_adm:names (),
    Result = join_nodes (Neighbours),
    error_logger:info_msg ("Neighbour discovery: ~w", [Result]),
    ok.

join_nodes (Nodes) -> join_nodes (Nodes, []).

join_nodes ([], Acc) -> Acc;
join_nodes ([H|T], Acc) ->
    Result = join_node (H),
    join_nodes (T, [Result|Acc]).

join_node ({Name, _Port}) ->
    %% XXX: other nodes may run on different boxes,
    %% but these won't be returned by net_adm:names ()
    Node = list_to_atom (Name++"@127.0.0.1"),
    {Node, net_kernel:connect (Node)}.

