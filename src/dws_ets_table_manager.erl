-module (dws_ets_table_manager).
-behaviour (gen_server).

-define (SERVER, ?MODULE).

%% Inspired by:
%%   http://steve.vinoski.net/blog/2011/03/23/dont-lose-your-ets-tables/
%%   https://2600hz.atlassian.net/wiki/display/Dedicated/ETS+Persistence

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export ([
          start_link/0,

          create/2,
          own/1,
          make_own_request/1
         ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export ([
          init/1, handle_call/3, handle_cast/2, handle_info/2,
          terminate/2, code_change/3
         ]).

-type ets_table_name () :: atom ().
-type ets_table_id () :: ets:tid ().
-type ets_table () :: ets_table_id () | ets_table_name ().
-type ets_table_option () :: any ().
-type ets_table_options () :: [ets_table_option ()].

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link () ->
    gen_server:start_link ({local, ?SERVER}, ?MODULE, [], []).

-spec create (Table   :: ets_table_name (),
              Options :: ets_table_options ()) ->
                     ok | error.
create (Name, Options) ->
    gen_server:call (?SERVER, {create, Name, Options}).

-spec own (Table :: ets_table ()) -> ok | error.
own (Table) ->
    gen_server:cast (?SERVER, {own, self (), Table}).

-spec make_own_request (Table :: ets_table ()) ->
                               OwnRequestCallback::fun ().
make_own_request (Table) ->
    fun () -> ?MODULE:own (Table) end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init (Args) ->
    {ok, Args}.

handle_call ({create, Name, Options} = _Request, _From, State) ->
    %% Make the table owned by us
    TableID = create_table (Name, Options),
    {reply, {ok, TableID}, State}.

handle_cast ({own, NewOwner, TableID} = _Request, State) ->
    error_logger:info_msg ("~p: received ETS take-over request: ~p~n",
                           [?MODULE, _Request]),
    X = case ets:info (TableID) of
        undefined ->
            create_table (TableID, [set, private, named_table]),
            created;
        _ ->
            reused
    end,
    true = ets:give_away (TableID, NewOwner, X),
    {noreply, State}.

handle_info ({'ETS-TRANSFER', _Tab, _FromPid, _Context} = _Info, State) ->
    error_logger:info_msg ("~p: received ETS ownership request: ~p~n",
                           [?MODULE, _Info]),
    {noreply, State};
handle_info (_Info, State) ->
    {noreply, State}.

terminate (_Reason, _State) ->
    ok.

code_change (_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

create_table (Name, Options) ->
    ets:new (Name, [{heir, self (), []}|Options]).

