-module (dws_service_example).
-export ([
          echo/2,
          ping/1,
          get_system_processes/1,
          get_mnesia_info/1
         ]).

echo (_SessionID, Msg) -> {ok, Msg}.

ping (_SessionID) -> {ok, pong}.

get_system_processes (_SessionID) ->
    {ok, {array, [
                  {struct, [{pid_to_list (Pid), get_process_ancestors (Pid)}]}
                  || Pid <- erlang:processes ()
                 ]}}.

get_mnesia_info (_SessionID) ->
    A = fun (X) -> {array, X} end,  %% Array
    S = fun (X) -> X end,           %% Scalar
    Props = [
             {extra_db_nodes, A},
             {db_nodes, A},
             {running_db_nodes, A},
             {is_running, S},
             {local_tables, A},
             {tables, A}
            ],
    Info = [ {K, F (mnesia:system_info (K))}
             || {K, F} <- Props ],
    {ok, {struct, Info}}.

%% === Private functions ===

proc_to_list (undefined) -> null;
proc_to_list (Pid) when is_pid (Pid) -> pid_to_list (Pid);
proc_to_list (Name) when is_atom (Name) -> atom_to_list (Name).

get_process_ancestors (Pid) ->
    ProcInfo = erlang:process_info (Pid),
    Dict = proplists:get_value (dictionary, ProcInfo, []),
    Ancestors = proplists:get_value ('$ancestors', Dict, []),
    {array, [ proc_to_list (A) || A <- Ancestors ]}.

