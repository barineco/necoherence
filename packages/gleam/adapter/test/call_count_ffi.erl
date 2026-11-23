%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(call_count_ffi).
-export([count/2]).

%% Runs the function with a call count on each of the named local functions and returns, for each of them,
%% the number of functions that the pattern matched and the number of calls.
count(Patterns, Run) ->
    Specs = [{binary_to_atom(Module, utf8), binary_to_atom(Name, utf8), Arity} || {Module, Name, Arity} <- Patterns],
    [code:ensure_loaded(Module) || {Module, _, _} <- Specs],
    Matched = [erlang:trace_pattern(Spec, true, [local, call_count]) || Spec <- Specs],
    try
        Run(),
        Counts = [begin {call_count, Count} = erlang:trace_info(Spec, call_count), Count end || Spec <- Specs],
        lists:zip(Matched, Counts)
    after
        [erlang:trace_pattern(Spec, false, [local, call_count]) || Spec <- Specs]
    end.
