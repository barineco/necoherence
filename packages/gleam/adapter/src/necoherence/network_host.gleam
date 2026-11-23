// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/network_effect as effect

pub type AdapterPorts {
  AdapterPorts(start: fn(effect.SendCommand) -> StartResult)
}

pub type Execution {
  Execution(
    handle: effect.ExecutionHandle,
    observe: fn() -> Result(effect.HostObservation, Nil),
  )
}

pub type StartResult {
  Started(Execution)
  StartFailed(effect.NetworkHostFailure, effect.EffectStatus)
}

pub fn start_with_ports(
  command: effect.SendCommand,
  ports: AdapterPorts,
) -> StartResult {
  ports.start(command)
}

pub fn handle(execution: Execution) -> effect.ExecutionHandle {
  execution.handle
}

pub fn observe(execution: Execution) -> Result(effect.HostObservation, Nil) {
  execution.observe()
}
