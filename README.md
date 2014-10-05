Distributed WebSockets Platform
===============================

Note that the original Prague Lambda Meetup project has moved here:
  https://github.com/ztmr/prague_lambda_meetup_erlang_otp_dws

That original project was split:
- https://github.com/ztmr/dws -- platform itself
- https://github.com/ztmr/dws_example -- sample application using DWS


Using in your project
---------------------
- add this repo to your `rebar.config`
- configure DWS having the following in your `sys.config`:
  ```Erlang
  {dws, [
    {listen_port, 9876},  %% a port where to start HTTP listener
    {routes, [
      {'_', [
        %% a path where the DWS broker should handle messages
        {"/ws", dws_websocket_handler, []},
        %% my_app's static data to be served (typically WebUI assets)
        {"/", cowboy_static, {priv_file, my_app, "index.html"}},
        {"/static/[...]", cowboy_static, {priv_dir, my_app, "static"}}
      ]}
    ]}
  ]}
  
  ```
- write your API service handler modules (see the following section)

Simple service handler example
------------------------------
```Erlang
-export (myapp_dws_service_demo).
-export ([echo/2, ping/1, get_system_processes/1]).

-export ([autoregister/0]). % must be exported if we use on_load
-on_load (autoregister/0).  % called everytime the module gets (re)loaded

autoregister () ->
    NS = <<"MyApp.Demo">>,
    ok = dws_service_broker:add_service_handler_async (NS, ?MODULE).

%% === Service API methods =================================================

echo (_SessionID, Msg) -> {ok, Msg}.

ping (_SessionID) -> {ok, pong}.

%% Client would do something like this:
%%   MyApp.Demo.setMyName ({ myNewName: 'John' }).
set_my_name (SessionID, Args) ->
    {ok, Name} = proplists:get_value (<<"myNewName">>, Args),
    {ok, SessionData} = dws_session_server:get_session_data (SessionID),
    dws_session_server:set_session_data (SessionData#{ name = Name }),
    ok.

%% Client would receive something like:
%%   { id: <requestId>, result: <name> }
get_my_name (SessionID) ->
    {ok, #{ name = Name }} = dws_session_server:get_session_data (SessionID),
    {ok, Name}.

get_system_processes (_SessionID) ->
    {ok, {array, [
                  {struct, [{pid_to_list (Pid), get_process_ancestors (Pid)}]}
                  || Pid <- erlang:processes ()
                 ]}}.

%% === Private functions ===================================================

get_process_ancestors (Pid) ->
    ProcInfo = erlang:process_info (Pid),
    Dict = proplists:get_value (dictionary, ProcInfo, []),
    Ancestors = proplists:get_value ('$ancestors', Dict, []),
    {array, [ proc_to_list (A) || A <- Ancestors ]}.

proc_to_list (undefined) -> null;
proc_to_list (Pid) when is_pid (Pid) -> pid_to_list (Pid);
proc_to_list (Name) when is_atom (Name) -> atom_to_list (Name).
```

Notes
-----
If you end up with the following message:
```
ERROR: OTP release R15B does not match required regex 17
```
...you need to upgrade your Erlang/OTP to 17.0+.

We also don't recommend to use service `on_load` together
with `dws_broker_handlers` configuration option since it
may interfere each other.
The `on_load` is actually the better way of doing the job.

TODO
----
- add an automatized proxy class generator to produce client-side
  code (JavaScript, before others) based on Service API specs.
  We may try to use Erlang's typespecs or just go our own way.
- add support for bi-directional streaming (useful for file
  transfers) and for EventSource-like server->client notifications
- `dws_admin` project to show some nice runtime stats
- add support for BERT, think about WAMPv2 standard

