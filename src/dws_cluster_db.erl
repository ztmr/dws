-module (dws_cluster_db).

-include_lib ("dws_cluster_db.hrl").

-export ([
          init/0
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

%% --- Internal functions ---

ensure_schema () ->
    ensure_table (mnesia:change_table_copy_type (schema, node (), disc_copies)).

%% Just created and loaded
ensure_table ({atomic, ok}) -> ok;

%% Maybe loaded, check if we need to load it by force
ensure_table ({aborted, {already_exists, Table}}) ->
    ensure_table ({aborted, {already_exists, Table, node ()}});
ensure_table ({aborted, {already_exists, Table, Node}}) ->
    ensure_table ({aborted, {already_exists, Table, Node, ram_copies}});
ensure_table ({aborted, {already_exists, Table, _Node, _Storage}}) ->
    %% Table exists, but still have no active replicas?
    %% That sounds like an after-crash issue, let's load it by force...
    %% Otherwise we would get `no_exists' error when trying to read them!
    case mnesia:table_info (Table, active_replicas) of
        [] ->
            lager:warning ("Force loading Mnesia table `~s'...", [Table]),
            yes = mnesia:force_load_table (Table),
            ok;
        _  ->
            ok
    end.

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

