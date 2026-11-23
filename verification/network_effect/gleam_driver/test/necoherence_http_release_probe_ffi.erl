%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(necoherence_http_release_probe_ffi).
-export([queue_process_count/0, late_worker_result/2]).

late_worker_result(Execution, Observation) ->
    necoherence_http_adapter_ffi:queue_publish(element(3, Execution), Observation).

queue_process_count() ->
    length([
        Pid
        || Pid <- erlang:processes(),
           erlang:process_info(Pid, current_function) =:=
               {current_function, {necoherence_http_adapter_ffi, queue_loop, 3}}
    ]).
