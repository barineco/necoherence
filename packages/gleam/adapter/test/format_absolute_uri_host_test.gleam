// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option
import gleeunit/should
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

fn absolute_uri(text: String) -> Bool {
  validation.recognizes(option.None, types.AbsoluteUri(option.Some(1000)), text)
}

pub fn ipv6_with_ipv4_tail_is_accepted_test() {
  absolute_uri("http://[::1.2.3.4]/") |> should.equal(True)
  absolute_uri("http://[1:2:3:4:5:6:1.2.3.4]/") |> should.equal(True)
  absolute_uri("http://[::ffff:1.2.3.4]/") |> should.equal(True)
  absolute_uri("http://[::1.2.3.4]:80/") |> should.equal(True)
}

pub fn ipv6_empty_group_at_open_side_is_rejected_test() {
  absolute_uri("http://[a::1:]/") |> should.equal(False)
  absolute_uri("http://[::1:]/") |> should.equal(False)
  absolute_uri("http://[1::2:]/") |> should.equal(False)
  absolute_uri("http://[:1::2]/") |> should.equal(False)
  absolute_uri("http://[1:::2]/") |> should.equal(False)
}

pub fn ipvfuture_address_rejects_percent_escape_test() {
  absolute_uri("http://[v1.a%41]/") |> should.equal(False)
  absolute_uri("http://[v1.a:b]/") |> should.equal(True)
  absolute_uri("http://[v1.a-b_c~d!$&'()*+,;=:x]/") |> should.equal(True)
}

pub fn ipv4_tail_octet_rejects_sign_and_leading_zero_test() {
  absolute_uri("http://[::+1.2.3.4]/") |> should.equal(False)
  absolute_uri("http://[::01.2.3.4]/") |> should.equal(False)
  absolute_uri("http://[::1.2.3.256]/") |> should.equal(False)
}
