defmodule OrchardConsole.ModelHubTest do
  use ExUnit.Case, async: false

  alias OrchardConsole.ModelHub

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        model_hub_impl: ModelHub,
        model_hub_client_impl: __MODULE__.StubClient
      )
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)
    :ok
  end

  describe "start_search/3" do
    test "returns {:ok, pid} immediately" do
      stub_client(search: {:ok, []})

      assert {:ok, pid} = ModelHub.start_search(self(), make_ref(), "Qwen")
      assert is_pid(pid)
    end

    test "task is not linked to the caller" do
      ref = make_ref()
      stub_client(search: {:ok, []})

      {:ok, pid} = ModelHub.start_search(self(), ref, "Qwen")

      {:links, links} = Process.info(self(), :links)
      refute pid in links

      assert_receive {:model_hub, ^ref, :search_finished, {:ok, %{query: "Qwen", results: []}}}, 1000
    end

    test "forwards query with the supported empty opts contract and sends success message" do
      ref = make_ref()
      results = [%{repo_id: "mlx-community/Qwen2.5-7B-Instruct-4bit"}]

      stub_client(
        search: {:ok, results},
        capture_search: true
      )

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, "Qwen")

      assert_receive {:captured_search, "Qwen", []}, 1000
      assert_receive {:model_hub, ^ref, :search_finished, {:ok, %{query: "Qwen", results: ^results}}}, 1000
    end

    test "forwards client errors unchanged" do
      ref = make_ref()
      error = %{status: :rate_limited, code: "hf_rate_limited", message: "slow down"}

      stub_client(search: {:error, error})

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)
      assert_receive {:model_hub, ^ref, :search_finished, {:error, ^error}}, 1000
    end

    test "normalizes raised exceptions to a generic error result" do
      ref = make_ref()
      stub_client(search: :raise)

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

      assert_receive {:model_hub, ^ref, :search_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :search_finished, _}, 50
    end

    test "normalizes thrown values to a generic error result" do
      ref = make_ref()
      stub_client(search: :throw)

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

      assert_receive {:model_hub, ^ref, :search_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :search_finished, _}, 50
    end

    test "normalizes exits to a generic error result" do
      ref = make_ref()
      stub_client(search: :exit)

      assert {:ok, _pid} = ModelHub.start_search(self(), ref, nil)

      assert_receive {:model_hub, ^ref, :search_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :search_finished, _}, 50
    end
  end

  describe "start_detail/3" do
    test "returns {:ok, pid} immediately" do
      stub_client(detail: {:ok, %{repo_id: "mlx-community/Qwen"}})

      assert {:ok, pid} = ModelHub.start_detail(self(), make_ref(), "mlx-community/Qwen")
      assert is_pid(pid)
    end

    test "forwards repo_id to the client and sends success message" do
      ref = make_ref()
      detail = %{repo_id: "mlx-community/Qwen2.5-7B-Instruct-4bit"}

      stub_client(
        detail: {:ok, detail},
        capture_detail: true
      )

      assert {:ok, _pid} =
               ModelHub.start_detail(self(), ref, "mlx-community/Qwen2.5-7B-Instruct-4bit")

      assert_receive {:captured_detail, "mlx-community/Qwen2.5-7B-Instruct-4bit"}, 1000
      assert_receive {:model_hub, ^ref, :detail_finished, {:ok, ^detail}}, 1000
    end

    test "forwards client errors unchanged" do
      ref = make_ref()
      error = %{status: :not_found, code: "hf_not_found", message: "missing"}

      stub_client(detail: {:error, error})

      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/missing")
      assert_receive {:model_hub, ^ref, :detail_finished, {:error, ^error}}, 1000
    end

    test "normalizes raised exceptions to a generic error result" do
      ref = make_ref()
      stub_client(detail: :raise)

      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/exploded")

      assert_receive {:model_hub, ^ref, :detail_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :detail_finished, _}, 50
    end

    test "normalizes thrown values to a generic error result" do
      ref = make_ref()
      stub_client(detail: :throw)

      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/exploded")

      assert_receive {:model_hub, ^ref, :detail_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :detail_finished, _}, 50
    end

    test "normalizes exits to a generic error result" do
      ref = make_ref()
      stub_client(detail: :exit)

      assert {:ok, _pid} = ModelHub.start_detail(self(), ref, "mlx-community/exploded")

      assert_receive {:model_hub, ^ref, :detail_finished, {:error, error}}, 1000
      assert error == %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
      refute_receive {:model_hub, ^ref, :detail_finished, _}, 50
    end
  end

  defmodule StubClient do
    def search_models(query, opts) do
      [{pid, config}] = Registry.lookup(OrchardConsole.ModelHubTest.StubRegistry, :client)

      if config[:capture_search] do
        send(pid, {:captured_search, query, opts})
      end

      case config[:search] do
        :raise -> raise "search exploded"
        :throw -> throw(:search_exploded)
        :exit -> exit(:search_exploded)
        nil -> {:ok, []}
        result -> result
      end
    end

    def get_model_detail(repo_id) do
      [{pid, config}] = Registry.lookup(OrchardConsole.ModelHubTest.StubRegistry, :client)

      if config[:capture_detail] do
        send(pid, {:captured_detail, repo_id})
      end

      case config[:detail] do
        :raise -> raise "detail exploded"
        :throw -> throw(:detail_exploded)
        :exit -> exit(:detail_exploded)
        nil -> {:ok, %{repo_id: repo_id}}
        result -> result
      end
    end
  end

  defp stub_client(config) do
    ensure_registry()
    Registry.register(__MODULE__.StubRegistry, :client, config)
  end

  defp ensure_registry do
    unless Process.whereis(__MODULE__.StubRegistry) do
      start_supervised!({Registry, keys: :duplicate, name: __MODULE__.StubRegistry})
    end
  end
end
