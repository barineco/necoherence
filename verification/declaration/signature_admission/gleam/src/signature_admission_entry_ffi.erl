%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: AGPL-3.0-only

-module(signature_admission_entry_ffi).
-export([read_stdin/0, batch_requested/0, guarded/1]).

batch_requested() ->
    init:get_plain_arguments() =:= ["--batch"].

guarded(Run) ->
    try
        {ok, Run()}
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p: ~P", [Class, Reason, 12]))}
    end.

read_stdin() ->
    unicode:characters_to_binary(read_lines([])).

read_lines(Acc) ->
    case io:get_line(standard_io, "") of
        eof -> lists:flatten(lists:reverse(Acc));
        {error, _} -> lists:flatten(lists:reverse(Acc));
        Line -> read_lines([Line | Acc])
    end.
