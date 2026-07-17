defmodule Orchard.BenchmarkConfigTest do
  use ExUnit.Case, async: false

  @benchmark_config Path.expand("../../../config/benchmark.exs", __DIR__)

  # The benchmark environment owns the Repo, so Orchard.Application supervises a
  # MembershipOwner whose init/1 fails closed on an incomplete identity. Unlike
  # :prod and :dev, config/benchmark.exs has no config/runtime.exs block to
  # resolve that identity, so it must carry the whole tuple itself or the
  # cold-start benchmark cannot boot.
  test "SPEC.md §8.3 the Repo-owning benchmark Controller carries a complete membership identity" do
    config = read_controller_config!()

    assert config[:start_repo] == true

    assert config[:controller_membership][:private_ipv4] == "127.0.0.1"
    assert config[:controller_membership][:scope] == :local_only
    assert is_binary(config[:controller_membership][:authorization_root_path])
    assert is_binary(config[:node_trust][:root])
  end

  defp read_controller_config! do
    @benchmark_config
    |> Config.Reader.read!(env: :benchmark)
    |> Keyword.fetch!(:orchard_controller)
  end
end
