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
    Config = application:get_env (?APP, session, []),
    Opts = [
            {path,      <<"/">>},
            {secure,    idealib_conv:x2bool0 (proplists:get_value (secure_only, Config))},
            {http_only, idealib_conv:x2bool0 (proplists:get_value (http_only,   Config))}
           ],
    NewReq0 = cowboy_req:set_resp_cookie (atom_to_list (?SESSION_COOKIE), SID, Opts, Req),
    NewReq1 = cowboy_req:set_meta (?REQ_META_KEY_SID, SID, NewReq0),
    {NewReq1, SID}.

discard_session (Req) ->
    SessionCookie = list_to_binary ([ atom_to_list (?SESSION_COOKIE),
                                      <<"=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/">>]),
    NewReq0 = cowboy_req:set_resp_header (<<"Set-Cookie">>, SessionCookie, Req),
    cowboy_req:set_meta (?REQ_META_KEY_SID, undefined, NewReq0).

