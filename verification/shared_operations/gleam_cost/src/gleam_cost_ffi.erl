%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(gleam_cost_ffi).
-export([arguments/0, count_on/1, count_read/1]).

arguments() ->
    [unicode:characters_to_binary(Argument) || Argument <- init:get_plain_arguments()].

count_on(Names) ->
    lists:foreach(
        fun(Module) ->
            {module, Module} = code:ensure_loaded(Module),
            erlang:trace_pattern({Module, '_', '_'}, true, [local, call_count])
        end,
        modules(Names)),
    nil.

count_read(Names) ->
    lists:sum([
        Count
     || Module <- modules(Names),
        {Function, Arity} <- Module:module_info(functions),
        Function =/= module_info,
        {call_count, Count} <- [erlang:trace_info({Module, Function, Arity}, call_count)],
        is_integer(Count)
    ]).

modules(Names) ->
    [binary_to_atom(Name, utf8) || Name <- Names].
