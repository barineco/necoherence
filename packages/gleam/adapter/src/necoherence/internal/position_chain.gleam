// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}

pub opaque type PositionChain {
  PositionChain(
    first: Option(Int),
    last: Option(Int),
    links: Dict(Int, #(Option(Int), Option(Int))),
  )
}

pub fn empty() -> PositionChain {
  PositionChain(None, None, dict.new())
}

pub fn first(chain: PositionChain) -> Option(Int) {
  chain.first
}

pub fn contains(chain: PositionChain, position: Int) -> Bool {
  dict.has_key(chain.links, position)
}

pub fn push_back(chain: PositionChain, position: Int) -> PositionChain {
  case dict.has_key(chain.links, position) {
    True -> chain
    False -> {
      let links =
        dict.insert(chain.links, position, #(chain.last, None))
        |> relink_next(chain.last, Some(position))
      PositionChain(
        first: case chain.first {
          None -> Some(position)
          existing -> existing
        },
        last: Some(position),
        links: links,
      )
    }
  }
}

pub fn remove(chain: PositionChain, position: Int) -> PositionChain {
  case dict.get(chain.links, position) {
    Error(Nil) -> chain
    Ok(#(previous, next)) -> {
      let links =
        dict.delete(chain.links, position)
        |> relink_next(previous, next)
        |> relink_previous(next, previous)
      PositionChain(
        first: case previous {
          None -> next
          Some(_) -> chain.first
        },
        last: case next {
          None -> previous
          Some(_) -> chain.last
        },
        links: links,
      )
    }
  }
}

pub fn to_list(chain: PositionChain) -> List(Int) {
  collect(chain, chain.first, [])
  |> reverse_ints([])
}

fn collect(
  chain: PositionChain,
  cursor: Option(Int),
  accumulated: List(Int),
) -> List(Int) {
  case cursor {
    None -> accumulated
    Some(position) ->
      case dict.get(chain.links, position) {
        Ok(#(_, next)) -> collect(chain, next, [position, ..accumulated])
        Error(Nil) -> accumulated
      }
  }
}

fn reverse_ints(values: List(Int), accumulated: List(Int)) -> List(Int) {
  case values {
    [] -> accumulated
    [value, ..rest] -> reverse_ints(rest, [value, ..accumulated])
  }
}

fn relink_next(
  links: Dict(Int, #(Option(Int), Option(Int))),
  position: Option(Int),
  next: Option(Int),
) -> Dict(Int, #(Option(Int), Option(Int))) {
  case position {
    None -> links
    Some(key) ->
      case dict.get(links, key) {
        Ok(#(previous, _)) -> dict.insert(links, key, #(previous, next))
        Error(Nil) -> links
      }
  }
}

fn relink_previous(
  links: Dict(Int, #(Option(Int), Option(Int))),
  position: Option(Int),
  previous: Option(Int),
) -> Dict(Int, #(Option(Int), Option(Int))) {
  case position {
    None -> links
    Some(key) ->
      case dict.get(links, key) {
        Ok(#(_, next)) -> dict.insert(links, key, #(previous, next))
        Error(Nil) -> links
      }
  }
}
