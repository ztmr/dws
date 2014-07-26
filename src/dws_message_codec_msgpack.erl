-module (dws_message_codec_msgpack).
-behavior (dws_message_codec).
-export ([encode/1, decode/1]).

encode (Msg) ->
    msgpack:pack (encode_ (Msg)).

decode (Msg) ->
    {ok, Decoded} = msgpack:unpack (Msg, [{format, map}]),
    decode_ (Decoded).


encode_ ({struct, Props}) when is_list (Props) ->
    {[ {normalize_key (K), encode_ (V)} || {K, V} <- Props ]};
encode_ ({array, List}) when is_list (List) ->
    [ encode_ (E) || E <- List ];
encode_ (X) ->
    X.

decode_ (#{} = Props) when is_map (Props) ->
    {struct, [ {K, decode_ (V)} || {K, V} <- maps:to_list (Props) ]};
decode_ (List) when is_list (List) ->
    %% XXX: compat with (incorrect mochijson2?)
    %{array, [ decode_ (E) || E <- List ]};
    [ decode_ (E) || E <- List ];
decode_ (X) ->
    X.

normalize_key (K) when is_atom (K) ->
    atom_to_binary (K, utf8);
normalize_key (K) when is_list (K) ->
    list_to_binary (K);
normalize_key (K) ->
    list_to_binary (idealib_conv:x2str (K)).

