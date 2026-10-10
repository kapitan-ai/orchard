defmodule Orchard.API.ToolSchemaAdmissionTest do
  use Orchard.ConnCase, async: false

  @moduletag :db
  @moduletag :live

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Governance
  alias Orchard.Inference.{ChatOrchestrator, ResponsesOrchestrator}
  alias Orchard.Repo
  alias Orchard.Requests.{Idempotency, Request}

  @non_object_parameters [nil, false, true, 0, 1.5, "{}", [], [%{"type" => "object"}]]

  defmodule BoundaryProbe do
    @behaviour Orchard.Tokenizer.Client
    @behaviour Orchard.Scheduler.SingleNode

    @impl Orchard.Tokenizer.Client
    def tokenize(request, _opts) do
      send(self(), {:schema_render_boundary, request.tooling.tools})
      {:error, :unavailable}
    end

    @impl Orchard.Scheduler.SingleNode
    def schedule(_request, _opts) do
      raise "declared-schema admission reached scheduling"
    end
  end

  setup do
    keys = [:inference, :api_chat_orchestrator_impl, :api_responses_orchestrator_impl]
    previous = Map.new(keys, &{&1, Application.fetch_env(:orchard_controller, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:orchard_controller, key, value)
        {key, :error} -> Application.delete_env(:orchard_controller, key)
      end)
    end)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(Application.fetch_env!(:orchard_controller, :inference),
        tokenizer_mode: :fake,
        tokenizer_client_impl: BoundaryProbe,
        scheduler_impl: BoundaryProbe
      )
    )

    Application.put_env(:orchard_controller, :api_chat_orchestrator_impl, ChatOrchestrator)

    Application.put_env(
      :orchard_controller,
      :api_responses_orchestrator_impl,
      ResponsesOrchestrator
    )

    suffix = System.unique_integer([:positive])

    {:ok, tenant} =
      Governance.create_tenant(%{
        slug: "schema-admission-#{suffix}",
        name: "Schema admission",
        request_body_capture_mode: :full
      })

    {:ok, %{token: token}} = Governance.create_api_key(tenant.id, %{name: "Schema admission"})
    model = create_model!(%{state: :active, capabilities: ["chat", "tool_calling"]})

    %{token: token, tenant: tenant, model: "#{model.model_id}@#{model.version}"}
  end

  for endpoint <- [:chat_completions, :responses],
      stream? <- [false, true],
      keyed? <- [false, true] do
    @endpoint_kind endpoint
    @stream? stream?
    @keyed? keyed?

    test "SPEC §3.4 #{@endpoint_kind} stream=#{@stream?} keyed=#{@keyed?} rejects non-object parameters before downstream boundaries",
         context do
      for parameters <- @non_object_parameters,
          model <- [context.model, "schema-admission-missing@v1"] do
        tools = [inline_tool(%{"name" => "lookup", "parameters" => parameters})]

        context
        |> Map.put(:model, model)
        |> submit(@endpoint_kind, @stream?, @keyed?, tools)
        |> assert_tool_rejection()

        refute_received {:schema_render_boundary, _tools}
        refute Repo.exists?(Request)
      end
    end

    test "characterizes #{@endpoint_kind} stream=#{@stream?} keyed=#{@keyed?} implementation rejection of missing invalid or duplicate function names",
         context do
      malformed_tools =
        Enum.map([%{}, %{"name" => nil}, %{"name" => ""}, %{"name" => 12}], fn function ->
          [inline_tool(function)]
        end) ++ [[inline_tool(%{"name" => "duplicate"}), inline_tool(%{"name" => "duplicate"})]]

      for tools <- malformed_tools do
        context
        |> submit(@endpoint_kind, @stream?, @keyed?, tools)
        |> assert_tool_rejection()

        refute_received {:schema_render_boundary, _tools}
        refute Repo.exists?(Request)
      end
    end

    test "characterizes #{@endpoint_kind} stream=#{@stream?} keyed=#{@keyed?} object-only schema admission at the render boundary",
         context do
      # SPEC §3.4 promises object shape, not a JSON Schema dialect, strictness, or size policy.
      # The probe stops before real rendering: these are admission observations, not model support.
      for function <- object_shape_examples() do
        tools = [inline_tool(function)]
        conn = submit(context, @endpoint_kind, @stream?, @keyed?, tools)

        assert conn.status == 500
        assert_received {:schema_render_boundary, ^tools}
        refute Repo.exists?(Request)
      end
    end
  end

  test "idempotency hashes JSON-encodable invalid tool shapes without persisting them", context do
    params = %{
      "model" => context.model,
      "input" => "schema admission",
      "tools" => [inline_tool(%{"name" => "lookup", "parameters" => "not an object"})]
    }

    assert {:ok, %{body_hash: hash}} =
             Idempotency.build_context(context.tenant.id, "schema-admission", params)

    assert byte_size(hash) == 32
    refute Repo.exists?(Request)
  end

  defp submit(context, endpoint, stream?, keyed?, tools) do
    {path, input} =
      case endpoint do
        :chat_completions ->
          {"/v1/chat/completions",
           %{"messages" => [%{"role" => "user", "content" => "schema admission"}]}}

        :responses ->
          {"/v1/responses", %{"input" => "schema admission"}}
      end

    params = Map.merge(input, %{"model" => context.model, "stream" => stream?, "tools" => tools})

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{context.token}")

    conn =
      if keyed? do
        put_req_header(
          conn,
          "idempotency-key",
          "schema-admission-#{System.unique_integer([:positive])}"
        )
      else
        conn
      end

    post(conn, path, Jason.encode!(params))
  end

  defp assert_tool_rejection(conn) do
    assert conn.status == 400
    assert ["application/json" <> _rest] = get_resp_header(conn, "content-type")

    assert %{
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_value",
               "param" => "tools"
             }
           } =
             Jason.decode!(conn.resp_body)
  end

  defp inline_tool(function), do: %{"type" => "function", "function" => function}

  defp object_shape_examples do
    deep_schema =
      Enum.reduce(1..64, %{"type" => "string"}, fn _depth, child ->
        %{"type" => "object", "properties" => %{"child" => child}}
      end)

    [
      %{"name" => "lookup"},
      %{"name" => "lookup", "parameters" => %{}},
      %{"name" => "lookup", "parameters" => %{"type" => "not-a-schema-type"}},
      %{"name" => "lookup", "parameters" => %{"required" => "not-an-array"}},
      %{"name" => "lookup", "parameters" => %{"properties" => []}},
      %{"name" => "lookup", "parameters" => %{"$ref" => "#/$defs/missing"}},
      %{"name" => "lookup", "strict" => true, "parameters" => %{"type" => "not-a-schema-type"}},
      %{"name" => "lookup", "strict" => false, "parameters" => %{"type" => "not-a-schema-type"}},
      %{"name" => "lookup", "parameters" => deep_schema},
      %{"name" => "lookup", "parameters" => %{"description" => String.duplicate("x", 65_536)}}
    ]
  end
end
