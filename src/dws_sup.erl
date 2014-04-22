-module (dws_sup).
-behaviour (supervisor).

%% API
-export ([start_link/0]).

%% Supervisor callbacks
-export ([init/1]).

%% Helper macro for declaring children of supervisor
-define (CHILD (I, Args, Type),
         {I, {I, start_link, Args}, permanent, 5000, Type, [I]}).
-define (WORKER (I, Args), ?CHILD (I, Args, worker)).

%% ===================================================================
%% API functions
%% ===================================================================

start_link () ->
    supervisor:start_link ({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init ([]) ->
    MakeOwnReq = fun dws_ets_table_manager:make_own_request/1,
    DSB_OwnReq = MakeOwnReq (dws_service_broker_state),
    Strategy = {one_for_one, 10, 10},
    Childs = [
              ?WORKER (dws_ets_table_manager, []),
              ?WORKER (dws_session_server, []),
              ?WORKER (dws_service_broker, [DSB_OwnReq])
             ],
    {ok, {Strategy, Childs}}.

