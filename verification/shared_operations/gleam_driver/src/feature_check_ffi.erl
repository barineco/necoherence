%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(feature_check_ffi).
-export([read_stdin/0, print_line/1]).

read_stdin() ->
    read_stdin_loop([]).

read_stdin_loop(Acc) ->
    case io:get_chars(standard_io, "", 1048576) of
        eof -> unicode:characters_to_binary(lists:reverse(Acc));
        Data ->
            Bin = case is_binary(Data) of
                true -> Data;
                false -> unicode:characters_to_binary(Data)
            end,
            read_stdin_loop([Bin | Acc])
    end.

print_line(Text) ->
    io:format("~ts~n", [Text]),
    ok.
