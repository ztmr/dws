-module (dws_message_codec).
-export ([behaviour_info/1]).

%% @spec behavior_info( atom() ) -> [ {Function::atom(), Arity::integer()} ] | undefined
behaviour_info (callbacks) ->
    [ {encode, 1}, {decode, 1} ];
behaviour_info (_Other) ->
    undefined.

