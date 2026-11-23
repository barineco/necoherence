%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: AGPL-3.0-only
-module(admission_probe).
-export([main/1]).

components() ->
    [{decode, [{'necoherence@semantic_signatures', admit_declared_generation, 2}]},
     {sha256, [{necoherence_semantic_generation_native, sha256_utf8, 1}]},
     {checkLibrary, [{'necoherence@semantic_signatures', check_library, 1}]},
     {graph, [{'necoherence@semantic_signatures', decode_library_value_unchecked, 1}]},
     {preparation, [{'necoherence@semantic_signatures', check_generation_context, 1},
                    {'necoherence@semantic_signatures', prepare_composition, 3},
                    {'necoherence@semantic_validation', prepare, 1},
                    {'necoherence@semantic_validation', index_graph, 1}]},
     {admit, [{'neco_quotient_certificate@admission', admit, 6}]},
     {blocks, [{neco_quotient_application, keyed_blocks_of, 1}]}].

main([RunsText]) ->
    Runs = list_to_integer(RunsText),
    Parent = self(),
    spawn_link(fun() -> Parent ! {result, measure(Runs)} end),
    receive {result, Result} -> io:format("~s~n", [Result]) end,
    halt(0).

initialization() ->
    [{basis, [{'necoherence@semantic_signatures', calculate_generation_identity, 3}]},
     {composition, [{'necoherence@semantic_signatures', decode_generation_composition, 2}]},
     {sha256, [{necoherence_semantic_generation_native, sha256_utf8, 1}]}].

measure(Runs) ->
    InitializationPatterns = [Pattern || {_, Owned} <- initialization(), Pattern <- Owned],
    [code:ensure_loaded(Module) || {Module, _, _} <- InitializationPatterns],
    [erlang:trace_pattern(Pattern, true, [local, call_count]) || Pattern <- InitializationPatterns],
    Run = probe_support:setup(),
    InitializationCalls = [{Name, lists:sum([initialization_count(Pattern) || Pattern <- Owned])} || {Name, Owned} <- initialization()],
    [erlang:trace_pattern(Pattern, false, [local, call_count]) || Pattern <- InitializationPatterns],
    Run(),
    Patterns = [Pattern || {_, Owned} <- components(), Pattern <- Owned],
    [code:ensure_loaded(Module) || {Module, _, _} <- Patterns],
    [1 = erlang:trace_pattern(Pattern, true, [local, call_count]) || Pattern <- Patterns],
    [Run() || _ <- lists:seq(1, Runs)],
    Calls = [{Name, lists:sum([count(Pattern) || Pattern <- Owned])} || {Name, Owned} <- components()],
    [erlang:trace_pattern(Pattern, false, [local, call_count]) || Pattern <- Patterns],
    Reductions = lists:min([reductions(Run) || _ <- lists:seq(1, Runs)]),
    Fields = [io_lib:format("\"~s\":~b", [Name, Count]) || {Name, Count} <- Calls],
    InitializationFields = [io_lib:format("\"~s\":~b", [Name, Count]) || {Name, Count} <- InitializationCalls],
    io_lib:format("{\"calls\":{~s},\"init\":{~s},\"quantity\":~b,\"second\":null}",
                  [lists:join(",", Fields), lists:join(",", InitializationFields), Reductions]).

initialization_count(Pattern) ->
    case erlang:trace_info(Pattern, call_count) of
        {call_count, Count} when is_integer(Count) -> Count;
        _ -> 0
    end.

count(Pattern) ->
    {call_count, Count} = erlang:trace_info(Pattern, call_count),
    Count.

reductions(Run) ->
    {reductions, Before} = process_info(self(), reductions),
    Run(),
    {reductions, After} = process_info(self(), reductions),
    After - Before.
