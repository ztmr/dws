-module (dws_cluster_db).

-include_lib ("dws_cluster_db.hrl").

-export ([
          init/0,
          update_lock_table/2
         ]).

%% This must be a macro because Erlang records
%% are handled by Erlang preprocessor and that's
%% why `record_info' cannot accept runtime variables
-define (CREATE_TABLE (NAME, NODES, STORAGE),
         ensure_table (mnesia:create_table (NAME, [
             {attributes, record_info (fields, NAME)},
             {STORAGE, NODES}
         ]))).

init () ->
    discover_nodes (),
    Tables = [?TABLE_SESSION, ?TABLE_SOCKET, ?TABLE_LOCK],
    Nodes = [node () | nodes ()],
    {ok, _} = mnesia:change_config (extra_db_nodes, Nodes),
    ok = ensure_schema (),
    case mnesia:wait_for_tables (Tables, ?WAIT_FOR_TABLES) of
        ok ->
            ensure_table (mnesia:add_table_copy (?TABLE_SESSION, node (), disc_copies)),
            ensure_table (mnesia:add_table_copy (?TABLE_SOCKET, node (), ram_copies)),
            ensure_table (mnesia:add_table_copy (?TABLE_LOCK, node (), ram_copies));
        {timeout, _Tables2Create} ->
            ok = ?CREATE_TABLE (?TABLE_SESSION, Nodes, disc_copies),
            ok = ?CREATE_TABLE (?TABLE_SOCKET, Nodes, ram_copies),
            ok = ?CREATE_TABLE (?TABLE_LOCK, Nodes, ram_copies)
    end.

update_lock_table (SessionID, Resource) ->
    Fun = fun () ->
                  mnesia:write (#?TABLE_LOCK {
                                    session_id = SessionID,
                                    id = Resource
                                   })
          end,
    {atomic, ok} = mnesia:transaction (Fun),
    ok.

%% --- Internal functions ---

ensure_schema () ->
    ensure_table (mnesia:change_table_copy_type (schema, node (), disc_copies)).

ensure_table ({atomic, ok}) -> ok;
ensure_table ({aborted, {already_exists, _Table, _Node, _Storage}}) -> ok;
ensure_table ({aborted, {already_exists, _Table, _Node}}) -> ok;
ensure_table ({aborted, {already_exists, _Table}}) -> ok.

cluster_hosts () ->
    case application:get_env (dws, cluster_hosts) of
        undefined ->
            [];
        {ok, Hosts} when is_list (Hosts) ->
            Hosts
    end.

discover_nodes () ->
    LocalNodes = discover_nodes (net_adm:names (), net_adm:localhost ()),
    ExtraNodes = [ discover_nodes (net_adm:names (H), H)
                   || H <- cluster_hosts () ],
    lists:flatten ([ LocalNodes, ExtraNodes ]).

discover_nodes ({error, _}, _) -> ok;
discover_nodes ({ok, Nodes}, Host) ->
    join_nodes (Nodes, Host).

join_nodes (Nodes, Host) ->
    join_nodes (Nodes, Host, []).

join_nodes ([], _Host, Acc) -> Acc;
join_nodes ([H|T], Host, Acc) ->
    Result = join_node (H, Host),
    join_nodes (T, Host, [Result|Acc]).

join_node ({Name, _Port}, Host) ->
    Node = list_to_atom (Name++"@"++Host),
    {Node, net_kernel:connect (Node)}.

