defmodule Orchard.RuntimeEndpoint.ReconnectBackoffTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.ReconnectBackoff

  test "KAP-82 equal jitter uses each upper half and caps at 30 seconds" do
    {first_floor, state} = ReconnectBackoff.next(ReconnectBackoff.new(), fn _width -> 1 end)
    assert first_floor == 125
    assert state.ceiling_ms == 500

    {second_ceiling, state} = ReconnectBackoff.next(state, & &1)
    assert second_ceiling == 499
    assert state.ceiling_ms == 1_000

    capped =
      Enum.reduce(1..10, state, fn _, current -> elem(ReconnectBackoff.next(current), 1) end)

    assert capped.ceiling_ms == 30_000
    {delay, _state} = ReconnectBackoff.next(capped, fn _width -> 1 end)
    assert delay == 15_000
  end

  test "KAP-82 reset requires exact current authentication and fresh accepted observation" do
    {_delay, attempted} = ReconnectBackoff.next(ReconnectBackoff.new())

    assert ReconnectBackoff.reset(attempted, %{
             current_generation_authenticated: true,
             fresh_observation_accepted: false
           }) == attempted

    assert ReconnectBackoff.reset(attempted, %{
             current_generation_authenticated: false,
             fresh_observation_accepted: true
           }) == attempted

    assert ReconnectBackoff.reset(attempted, %{
             current_generation_authenticated: true,
             fresh_observation_accepted: true
           }) == ReconnectBackoff.new()
  end

  test "KAP-82 scheduled retry and authority loss fail closed" do
    state = ReconnectBackoff.new(1_000)
    assert ReconnectBackoff.due?(state, 1_000)

    {125, failed} = ReconnectBackoff.failed(state, 1_000, fn _width -> 0 end)
    refute ReconnectBackoff.due?(failed, 1_124)
    assert ReconnectBackoff.due?(failed, 1_125)

    blocked = ReconnectBackoff.authority_lost(failed)
    refute ReconnectBackoff.due?(blocked, 60_000)

    recovered = ReconnectBackoff.authority_recovered(blocked, 60_000)
    assert ReconnectBackoff.due?(recovered, 60_000)
    assert recovered.ceiling_ms == 250
  end
end
