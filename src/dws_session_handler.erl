-module (dws_session_handler).
-export ([on_request/1, get_session/1, discard_session/1]).

-define (SESSION_COOKIE, '%dwsid').

on_request (Req) ->
    ensure_session (Req).

ensure_session (Req) ->
    case is_valid_session (get_session (Req)) of
        true -> Req;
        false ->
            {NewReq, _} = init_session (Req),
            NewReq
    end.

is_valid_session (undefined) -> false;
is_valid_session (SessionID) ->
    case dws_session_server:get_session_data (SessionID) of
        {ok, _} -> true;
        {error, _} -> false
    end.

get_session (Req) ->
    #{ ?SESSION_COOKIE := SID } = cowboy_req:match_cookies ([{?SESSION_COOKIE, [], undefined}], Req),
    SID.

init_session (Req) ->
    {ok, SID} = dws_session_server:create_session (),
    lager:debug ("Generating a new session SID=~ts", [SID]),
    NewReq = cowboy_req:set_resp_cookie (?SESSION_COOKIE, SID, [{path, <<"/">>}], Req),
    {NewReq, SID}.

discard_session (Req) ->
    SessionCookie = list_to_binary ([ ?SESSION_COOKIE,
                                      <<"=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/">>]),
    cowboy_req:set_resp_header (<<"Set-Cookie">>, SessionCookie, Req).

