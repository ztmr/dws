-module (dws_message_codec_json).
-behavior (dws_message_codec).
-export ([encode/1, decode/1]).

encode (Msg) ->
    mochijson2:encode (Msg).

decode (Msg) ->
    mochijson2:decode (Msg).

