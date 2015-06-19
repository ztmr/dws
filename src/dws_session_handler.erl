-module (dws_session_handler).
-behaviour (cowboy_middleware).

-export ([execute/2]).
-export ([on_request/1, get_session/1, discard_session/1]).

-define (APP, dws).
-define (SESSION_COOKIE, '%dwsid').
-define (REQ_META_KEY_SID, '%dws_session_id').

%% Middleware callback
execute (Req, Env) ->
    {NewReq, SessionID} = ensure_session (Req),
    NewEnv = [{session_id, SessionID}|Env],
    {ok, NewReq, NewEnv}.

%% Former Cowboy OnRequest handler
on_request (Req) ->
    {NewReq, _SessionID} = ensure_session (Req),
    NewReq.

ensure_session (Req) ->
    case get_session (Req) of
        undefined ->
            init_session (Req);
        SID ->
            {cowboy_req:set_meta (?REQ_META_KEY_SID, SID, Req), SID}
    end.

get_session (Req) ->
    #{ ?SESSION_COOKIE := SID } = cowboy_req:match_cookies ([{?SESSION_COOKIE, [], undefined}], Req),
    case is_valid_session (SID) of
        true  -> SID;
        false -> cowboy_req:meta (?REQ_META_KEY_SID, Req)
    end.

is_valid_session (undefined) -> false;
is_valid_session (SessionID) ->
    case dws_session_server:get_session_data (SessionID) of
        {ok, _} -> true;
        {error, _} -> false
    end.

init_session (Req) ->
    {ok, SID} = dws_session_server:create_session (),
    lager:debug ("Generating a new session SID=~ts", [SID]),
    NewReq = build_session (Req, SID, dws_session_server:get_session_ttl ()),
    {NewReq, SID}.

discard_session (Req) ->
    build_session (Req, undefined, 0).

build_session (Req, Value, TTL) ->
    Config = application:get_env (?APP, session, []),
    Opts = [
            {path,      <<"/">>},
            {secure,    idealib_conv:x2bool0 (proplists:get_value (secure_only, Config))},
            {http_only, idealib_conv:x2bool0 (proplists:get_value (http_only,   Config))},
            {max_age,   TTL}
           ],
    NewReq0 = cowboy_req:set_resp_cookie (atom_to_list (?SESSION_COOKIE), Value, Opts, Req),
    cowboy_req:set_meta (?REQ_META_KEY_SID, Value, NewReq0).

