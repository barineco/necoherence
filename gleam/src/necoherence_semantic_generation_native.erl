%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(necoherence_semantic_generation_native).
-export([sha256_utf8/1, encode_bytes/1, decode_bytes/1]).

sha256_utf8(Text) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(crypto:hash(sha256, Text))))).

encode_bytes(Bytes) ->
    try {ok, base64:encode(list_to_binary(Bytes))}
    catch error:_ -> {error, nil}
    end.

decode_bytes(Text) ->
    try
        Padded = case byte_size(Text) rem 4 of
            0 -> Text;
            2 -> <<Text/binary, "==">>;
            3 -> <<Text/binary, "=">>;
            _ -> error(invalid_base64_length)
        end,
        {ok, binary_to_list(base64:decode(Padded))}
    catch error:_ -> {error, nil}
    end.
