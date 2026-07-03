defmodule OrchardConsole.SettingsLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Orchard.TestSupport.LicenseGateHelpers,
    only: [activation_guidance: 0, set_license_enforcement: 1]

  alias Orchard.ConsoleSettings

  @moduletag :live
  @moduletag :db

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        playground_impl: __MODULE__.PlaygroundStub,
        licensing_impl: __MODULE__.LicensingValidStub,
        runtime_impl: __MODULE__.RuntimeStub
      )
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      :persistent_term.erase({__MODULE__, :models})
      :persistent_term.erase({__MODULE__, :runtime_mode})
      :persistent_term.erase({__MODULE__, :runtime_count})
      :persistent_term.erase({__MODULE__, :runtime_test_pid})
      :persistent_term.erase({__MODULE__, :settings_save_failure_mode})
    end)

    stub_models([
      %{model_id: "test-model", version: "v1"},
      %{model_id: "test-model", version: "v2"},
      %{model_id: "other-model", version: "v1"}
    ])

    stub_runtime({:ok, :initial})

    :ok
  end

  describe "GET /console/settings" do
    test "renders shell, title, active nav, and stable section cards", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/settings")

      assert html =~ "Settings — Orchard Console"
      assert html =~ "console-sidebar"
      assert has_element?(view, ~s(a[aria-current="page"][href="/console/settings"]))

      assert has_element?(view, "#settings-license-card")
      assert has_element?(view, "#settings-appearance-card")
      assert has_element?(view, "#settings-inference-defaults-card")
      assert has_element?(view, "#settings-advanced-card")
    end

    test "renders read-only appearance guidance without a second theme toggle", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/settings")
      card_html = view |> element("#settings-appearance-card") |> render()

      assert card_html =~ "Appearance"
      assert card_html =~ "System"
      assert card_html =~ "Light"
      assert card_html =~ "Dark"
      assert card_html =~ "orchard_console_theme"
      assert card_html =~ "no server-side persistence"
      assert card_html =~ "sidebar footer"
      assert Regex.scan(~r/id="theme-toggle"/, html) |> length() == 1
    end
  end

  describe "License Status" do
    test "hides missing license activation noise when enforcement is off", %{conn: conn} do
      set_license_enforcement(:off)
      put_console_config(licensing_impl: __MODULE__.LicensingMissingStub)

      {:ok, view, html} = live(conn, "/console/settings")

      refute has_element?(view, "#settings-license-card")
      refute html =~ activation_guidance()
      assert has_element?(view, "#settings-appearance-card")
      assert has_element?(view, "#settings-inference-defaults-card")
      assert has_element?(view, "#settings-advanced-card")
    end

    test "renders display-safe license fields as read-only status", %{conn: conn} do
      set_license_enforcement(:off)

      {:ok, view, _html} = live(conn, "/console/settings")

      card_html = view |> element("#settings-license-card") |> render()

      assert card_html =~ "Valid"
      assert card_html =~ "License bundle is valid."
      assert card_html =~ "2027-04-15T00:00:00Z"
      assert card_html =~ "Settings Orchard Lab"
      assert card_html =~ "program=settings ref=settings-001"
      refute card_html =~ activation_guidance()
      refute card_html =~ "license_certificate"
      refute card_html =~ "machine_certificate"
      refute card_html =~ "PRIVATE KEY"
      refute card_html =~ "phx-submit"
      refute card_html =~ "phx-click"
    end

    test "renders fetched activation guidance in warn mode when the license is not activated", %{
      conn: conn
    } do
      set_license_enforcement(:warn)
      put_console_config(licensing_impl: __MODULE__.LicensingMissingStub)

      {:ok, view, _html} = live(conn, "/console/settings")

      card_html = view |> element("#settings-license-card") |> render()
      activation_html = view |> element("#settings-license-activation") |> render()

      assert card_html =~ "Missing bundle"
      assert card_html =~ "No local license bundle is installed."
      assert activation_html =~ "Activation required"
      assert activation_html =~ activation_guidance()
    end

    test "degrades safely when license inspection fails", %{conn: conn} do
      set_license_enforcement(:hard)
      put_console_config(licensing_impl: __MODULE__.LicensingProbeFailureStub)

      {:ok, view, _html} = live(conn, "/console/settings")

      card_html = view |> element("#settings-license-card") |> render()

      assert card_html =~ "Malformed bundle"
      assert card_html =~ "License inspection failed."
      assert card_html =~ activation_guidance()
      refute card_html =~ "license_certificate"
      refute card_html =~ "machine_certificate"
      refute card_html =~ "PRIVATE KEY"
    end
  end

  describe "Advanced / Debug" do
    test "renders a collapsed-by-default read-only runtime disclosure", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/settings")
      render_until(view, "Idle")

      card_html = view |> element("#settings-advanced-card") |> render()

      assert card_html =~ ~s(id="settings-advanced-debug-disclosure")
      assert card_html =~ ~s(<details)
      refute card_html =~ ~r/<details[^>]*\sopen(?:\s|=|>)/
      assert card_html =~ "Runtime / config snapshot"
      assert card_html =~ "Loaded models"
      assert card_html =~ "Active requests"
      assert card_html =~ "Runtime health"
      assert card_html =~ "Transport mode"
      assert view |> element("#settings-advanced-worker-state") |> render() =~ "Idle"
      assert view |> element("#settings-advanced-node") |> render() =~ "settings-node-initial"
      assert view |> element("#settings-advanced-worker-backend") |> render() =~ "mlx"
      assert view |> element("#settings-advanced-loaded-models") |> render() =~ "1"
      assert view |> element("#settings-advanced-active-requests") |> render() =~ "2"
      assert view |> element("#settings-advanced-runtime-health") |> render() =~ "Ready"

      assert view |> element("#settings-advanced-transport-mode") |> render() =~
               "plain_http_localhost"

      refute card_html =~ "license-secret"
      refute card_html =~ "PRIVATE KEY"
    end

    test "manual refresh uses an in-flight guard and updates the snapshot", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/settings")
      render_until(view, "Idle")
      assert runtime_count() == 1

      stub_runtime({:block, :refreshed})

      refreshing_html =
        view
        |> element("#settings-advanced-refresh-now")
        |> render_click()

      assert_receive {:runtime_snapshot_started, runtime_pid}, 1_000
      assert refreshing_html =~ "Refreshing…"

      assert refreshing_html =~
               ~r/<button(?=[^>]*id="settings-advanced-refresh-now")(?=[^>]*disabled)[^>]*>/

      render_click(view, "refresh_now")

      assert runtime_count() == 2

      send(runtime_pid, :release_runtime_snapshot)
      updated_html = render_until(view, "Busy")

      assert updated_html =~ "Busy"
      assert view |> element("#settings-advanced-worker-state") |> render() =~ "Busy"
      assert view |> element("#settings-advanced-node") |> render() =~ "settings-node-refreshed"
      assert view |> element("#settings-advanced-active-requests") |> render() =~ "7"
      assert view |> element("#settings-advanced-runtime-health") |> render() =~ "warning"
    end

    test "manual refresh times out and ignores stale runtime replies", %{conn: conn} do
      put_console_config(advanced_debug_refresh_timeout_ms: 20)
      stub_runtime({:block, :refreshed})

      {:ok, view, _html} = live(conn, "/console/settings")
      assert_receive {:runtime_snapshot_started, runtime_pid}, 1_000

      timeout_html = render_until(view, "Runtime snapshot timed out.", 20)

      assert timeout_html =~ "Runtime snapshot timed out."
      assert timeout_html =~ "Refresh now"
      refute has_element?(view, "#settings-advanced-refresh-now[disabled]")

      send(runtime_pid, :release_runtime_snapshot)
      Process.sleep(30)

      stale_html = render(view)
      assert stale_html =~ "Runtime snapshot timed out."
      refute stale_html =~ "Busy"
      refute stale_html =~ "settings-node-refreshed"
    end

    test "runtime probe failure renders a safe degraded state", %{conn: conn} do
      stub_runtime(:exit)

      {:ok, view, _html} = live(conn, "/console/settings")
      render_until(view, "Runtime snapshot unavailable.")

      card_html = view |> element("#settings-advanced-card") |> render()

      assert card_html =~ "Runtime snapshot unavailable."
      assert card_html =~ "Unavailable"
      refute card_html =~ "license-secret"
      refute card_html =~ "PRIVATE KEY"
    end
  end

  describe "Inference Defaults" do
    test "renders form with deduped versionless default model options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/settings")

      card_html = view |> element("#settings-inference-defaults-card") |> render()

      assert card_html =~ ~s(id="settings-inference-defaults-form")
      assert card_html =~ ~s(id="settings-default-model")
      assert card_html =~ ~s(id="settings-temperature")
      assert card_html =~ ~s(id="settings-top-p")
      assert card_html =~ ~s(id="settings-max-completion-tokens")

      assert Regex.scan(~r/<option[^>]+value="test-model"/, card_html) |> length() == 1
      assert Regex.scan(~r/<option[^>]+value="other-model"/, card_html) |> length() == 1
      refute card_html =~ "test-model@v1"
      refute card_html =~ "test-model@v2"
    end

    test "preserves saved inactive default model option on unrelated saves", %{conn: conn} do
      assert {:ok, %{default_model: "archived-model"}} =
               ConsoleSettings.save_playground_defaults(%{"default_model" => "archived-model"})

      {:ok, view, _html} = live(conn, "/console/settings")
      card_html = view |> element("#settings-inference-defaults-card") |> render()

      assert card_html =~
               ~r/<option[^>]+selected[^>]+value="archived-model">archived-model<\/option>/

      html =
        render_submit(view, "save_inference_defaults", %{
          "settings_inference_defaults" => %{"temperature" => "0.4"}
        })

      assert html =~ "Inference defaults saved."

      assert %{
               default_model: "archived-model",
               temperature: 0.4,
               top_p: nil,
               max_completion_tokens: nil
             } = ConsoleSettings.get_playground_defaults()
    end

    test "recomputes default model options from the saved default after save", %{conn: conn} do
      assert {:ok, %{default_model: "archived-model"}} =
               ConsoleSettings.save_playground_defaults(%{"default_model" => "archived-model"})

      {:ok, view, _html} = live(conn, "/console/settings")
      assert has_element?(view, ~s(#settings-default-model option[value="archived-model"]))

      html =
        render_submit(view, "save_inference_defaults", %{
          "settings_inference_defaults" => %{"default_model" => "replacement-archived"}
        })

      assert html =~ "Inference defaults saved."

      assert has_element?(
               view,
               ~s(#settings-default-model option[selected][value="replacement-archived"])
             )

      refute has_element?(view, ~s(#settings-default-model option[value="archived-model"]))

      assert %{default_model: "replacement-archived"} = ConsoleSettings.get_playground_defaults()
    end

    test "saves playground defaults and re-renders persisted values", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/settings")

      html =
        view
        |> form("#settings-inference-defaults-form",
          settings_inference_defaults: %{
            default_model: "test-model",
            temperature: "0.7",
            top_p: "0.95",
            max_completion_tokens: "256"
          }
        )
        |> render_submit()

      assert html =~ "Inference defaults saved."

      assert %{
               default_model: "test-model",
               temperature: 0.7,
               top_p: 0.95,
               max_completion_tokens: 256
             } = ConsoleSettings.get_playground_defaults()

      card_html = view |> element("#settings-inference-defaults-card") |> render()
      assert card_html =~ ~r/<option[^>]+selected[^>]+value="test-model"/
      assert card_html =~ ~s(id="settings-temperature")
      assert card_html =~ ~s(value="0.7")
      assert card_html =~ ~s(value="0.95")
      assert card_html =~ ~s(value="256")
    end

    test "preserves omitted sampling defaults on partial save", %{conn: conn} do
      assert {:ok,
              %{
                default_model: "test-model",
                temperature: 0.7,
                top_p: 0.95,
                max_completion_tokens: 256
              }} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => "test-model",
                 "temperature" => "0.7",
                 "top_p" => "0.95",
                 "max_completion_tokens" => "256"
               })

      {:ok, view, _html} = live(conn, "/console/settings")

      html =
        render_submit(view, "save_inference_defaults", %{
          "settings_inference_defaults" => %{"default_model" => "other-model"}
        })

      assert html =~ "Inference defaults saved."

      assert %{
               default_model: "other-model",
               temperature: 0.7,
               top_p: 0.95,
               max_completion_tokens: 256
             } = ConsoleSettings.get_playground_defaults()
    end

    test "treats submitted empty strings as explicit inference default unsets", %{conn: conn} do
      assert {:ok,
              %{
                default_model: "test-model",
                temperature: 0.7,
                top_p: 0.95,
                max_completion_tokens: 256
              }} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => "test-model",
                 "temperature" => "0.7",
                 "top_p" => "0.95",
                 "max_completion_tokens" => "256"
               })

      {:ok, view, _html} = live(conn, "/console/settings")

      render_submit(view, "save_inference_defaults", %{
        "settings_inference_defaults" => %{"temperature" => ""}
      })

      assert %{
               default_model: "test-model",
               temperature: nil,
               top_p: 0.95,
               max_completion_tokens: 256
             } = ConsoleSettings.get_playground_defaults()
    end

    test "ignores malformed inference defaults submits without changing persisted defaults", %{
      conn: conn
    } do
      assert {:ok,
              %{
                default_model: "test-model",
                temperature: 0.7,
                top_p: 0.95,
                max_completion_tokens: 256
              }} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => "test-model",
                 "temperature" => "0.7",
                 "top_p" => "0.95",
                 "max_completion_tokens" => "256"
               })

      {:ok, view, _html} = live(conn, "/console/settings")

      html = render_submit(view, "save_inference_defaults", %{"unexpected" => "payload"})

      refute html =~ "Inference defaults saved."
      assert has_element?(view, "#settings-inference-defaults-card")

      assert %{
               default_model: "test-model",
               temperature: 0.7,
               top_p: 0.95,
               max_completion_tokens: 256
             } = ConsoleSettings.get_playground_defaults()
    end

    test "shows validation errors without persisting invalid sampling defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/settings")

      html =
        view
        |> form("#settings-inference-defaults-form",
          settings_inference_defaults: %{top_p: "2", max_completion_tokens: "0"}
        )
        |> render_submit()

      assert html =~ "must be between 0 (exclusive) and 1 (inclusive)"
      assert html =~ "must be a positive integer"

      assert %{
               default_model: nil,
               temperature: nil,
               top_p: nil,
               max_completion_tokens: nil
             } = ConsoleSettings.get_playground_defaults()
    end

    test "sanitizes crafted nested invalid params before rebuilding failed form", %{conn: conn} do
      assert {:ok,
              %{
                default_model: "test-model",
                temperature: 0.4,
                top_p: 0.9,
                max_completion_tokens: 128
              }} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => "test-model",
                 "temperature" => "0.4",
                 "top_p" => "0.9",
                 "max_completion_tokens" => "128"
               })

      {:ok, view, _html} = live(conn, "/console/settings")

      html =
        render_submit(view, "save_inference_defaults", %{
          "settings_inference_defaults" => %{
            "default_model" => %{"crafted" => "nested"},
            "temperature" => %{"crafted" => "nested"},
            "top_p" => "2",
            "max_completion_tokens" => "0"
          }
        })

      assert html =~
               "Some inference defaults were restored because the submitted form data was malformed."

      refute html =~ "is invalid"
      assert html =~ "must be between 0 (exclusive) and 1 (inclusive)"
      assert html =~ "must be a positive integer"
      refute html =~ "crafted"
      refute html =~ "nested"

      card_html = view |> element("#settings-inference-defaults-card") |> render()
      assert card_html =~ ~r/<option[^>]+selected[^>]+value="test-model"/
      assert card_html =~ ~s(value="0.4")
      assert card_html =~ ~s(value="2")
      assert card_html =~ ~s(value="0")

      assert %{
               default_model: "test-model",
               temperature: 0.4,
               top_p: 0.9,
               max_completion_tokens: 128
             } = ConsoleSettings.get_playground_defaults()
    end

    test "disables default model select and shows saved value when model list is unavailable", %{
      conn: conn
    } do
      assert {:ok, %{default_model: "saved-model"}} =
               ConsoleSettings.save_playground_defaults(%{"default_model" => "saved-model"})

      for model_failure <- [:error, :exit, :throw] do
        stub_models(model_failure)

        {:ok, view, _html} = live(conn, "/console/settings")
        card_html = view |> element("#settings-inference-defaults-card") |> render()

        assert card_html =~ "Active model list unavailable."
        assert card_html =~ ~r/<option[^>]+selected[^>]+value="saved-model">saved-model<\/option>/
        assert card_html =~ ~r/<select[^>]+id="settings-default-model"[^>]+disabled/
      end
    end

    test "preserves saved default model when degraded submit omits disabled select", %{
      conn: conn
    } do
      assert {:ok, %{default_model: "saved-model"}} =
               ConsoleSettings.save_playground_defaults(%{"default_model" => "saved-model"})

      stub_models(:error)

      {:ok, view, _html} = live(conn, "/console/settings")

      view
      |> form("#settings-inference-defaults-form",
        settings_inference_defaults: %{temperature: "0.4"}
      )
      |> render_submit()

      assert %{
               default_model: "saved-model",
               temperature: 0.4,
               top_p: nil,
               max_completion_tokens: nil
             } = ConsoleSettings.get_playground_defaults()
    end

    test "shows unavailable error and preserves current state when saving defaults fails", %{
      conn: conn
    } do
      assert {:ok,
              %{
                default_model: "test-model",
                temperature: 0.4,
                top_p: 0.9,
                max_completion_tokens: 128
              }} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => "test-model",
                 "temperature" => "0.4",
                 "top_p" => "0.9",
                 "max_completion_tokens" => "128"
               })

      put_console_config(settings_impl: __MODULE__.SettingsSaveFailureStub)

      for failure_mode <- [:error, :raise, :exit, :throw] do
        :persistent_term.put({__MODULE__, :settings_save_failure_mode}, failure_mode)

        {:ok, view, _html} = live(conn, "/console/settings")

        html =
          render_submit(view, "save_inference_defaults", %{
            "settings_inference_defaults" => %{"temperature" => "0.8"}
          })

        assert html =~ "Inference defaults unavailable."

        card_html = view |> element("#settings-inference-defaults-card") |> render()
        assert card_html =~ ~r/<option[^>]+selected[^>]+value="test-model"/
        assert card_html =~ ~s(value="0.4")
        assert card_html =~ ~s(value="0.9")
        assert card_html =~ ~s(value="128")

        assert %{
                 default_model: "test-model",
                 temperature: 0.4,
                 top_p: 0.9,
                 max_completion_tokens: 128
               } = ConsoleSettings.get_playground_defaults()
      end
    end

    test "fails closed and preserves persisted defaults when inference defaults cannot be loaded",
         %{
           conn: conn
         } do
      assert {:ok,
              %{
                default_model: "saved-model",
                temperature: 0.4,
                top_p: 0.9,
                max_completion_tokens: 128
              }} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => "saved-model",
                 "temperature" => "0.4",
                 "top_p" => "0.9",
                 "max_completion_tokens" => "128"
               })

      put_console_config(settings_impl: __MODULE__.SettingsLoadFailureStub)

      {:ok, view, _html} = live(conn, "/console/settings")
      card_html = view |> element("#settings-inference-defaults-card") |> render()

      assert card_html =~ "Inference defaults unavailable."
      assert card_html =~ "Saved defaults were not loaded, so saving is disabled."
      assert has_element?(view, "#settings-default-model[disabled]")
      assert has_element?(view, "#settings-temperature[disabled]")
      assert has_element?(view, "#settings-top-p[disabled]")
      assert has_element?(view, "#settings-max-completion-tokens[disabled]")
      assert has_element?(view, "#settings-save-inference-defaults[disabled]")

      render_submit(view, "save_inference_defaults", %{
        "settings_inference_defaults" => %{
          "default_model" => "",
          "temperature" => "",
          "top_p" => "",
          "max_completion_tokens" => ""
        }
      })

      assert %{
               default_model: "saved-model",
               temperature: 0.4,
               top_p: 0.9,
               max_completion_tokens: 128
             } = ConsoleSettings.get_playground_defaults()
    end
  end

  defmodule LicensingValidStub do
    def inspect_local do
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: "/tmp/current.json",
        expires_at: ~U[2027-04-15 00:00:00Z],
        licensee: "Settings Orchard Lab",
        metadata: %{program: "settings", reference: "settings-001"}
      }
    end
  end

  defmodule LicensingMissingStub do
    def inspect_local do
      %Orchard.Licensing{
        state: :missing_bundle,
        message: "No local license bundle is installed.",
        bundle_path: "/tmp/current.json"
      }
    end
  end

  defmodule LicensingProbeFailureStub do
    def inspect_local, do: raise("probe failed")
  end

  defmodule RuntimeStub do
    def snapshot do
      :persistent_term.put(
        {OrchardConsole.SettingsLiveTest, :runtime_count},
        :persistent_term.get({OrchardConsole.SettingsLiveTest, :runtime_count}, 0) + 1
      )

      case :persistent_term.get({OrchardConsole.SettingsLiveTest, :runtime_mode}, {:ok, :initial}) do
        {:ok, label} ->
          {:ok, OrchardConsole.SettingsLiveTest.runtime_snapshot(label)}

        {:block, label} ->
          if test_pid =
               :persistent_term.get({OrchardConsole.SettingsLiveTest, :runtime_test_pid}, nil) do
            send(test_pid, {:runtime_snapshot_started, self()})
          end

          receive do
            :release_runtime_snapshot ->
              {:ok, OrchardConsole.SettingsLiveTest.runtime_snapshot(label)}
          after
            5_000 -> {:error, %{status: :timeout, message: "node status request timed out"}}
          end

        :raise ->
          raise "runtime probe failed"

        :exit ->
          exit(:runtime_probe_failed)

        {:error, message} ->
          {:error, %{status: :error, message: message}}
      end
    end
  end

  defmodule PlaygroundStub do
    def list_models do
      case :persistent_term.get({OrchardConsole.SettingsLiveTest, :models}, []) do
        :error ->
          {:error,
           %{
             status: :error,
             code: "models_unavailable",
             message: "Active model list unavailable."
           }}

        :exit ->
          exit(:models_unavailable)

        :throw ->
          throw(:models_unavailable)

        models when is_list(models) ->
          {:ok, models}
      end
    end
  end

  defmodule SettingsLoadFailureStub do
    def get_playground_defaults, do: raise("settings load failed")
    def save_playground_defaults(_params), do: raise("save should not be called")
  end

  defmodule SettingsSaveFailureStub do
    def get_playground_defaults, do: Orchard.ConsoleSettings.get_playground_defaults()

    def save_playground_defaults(_params) do
      case :persistent_term.get({OrchardConsole.SettingsLiveTest, :settings_save_failure_mode}) do
        :error -> {:error, :settings_save_failed}
        :raise -> raise "settings save failed"
        :exit -> exit(:settings_save_failed)
        :throw -> throw(:settings_save_failed)
      end
    end
  end

  def runtime_snapshot(label) do
    suffix = Atom.to_string(label)

    %{
      worker_state: if(label == :refreshed, do: :busy, else: :idle),
      loaded_models: runtime_loaded_models(label),
      active_request_count: if(label == :refreshed, do: 7, else: 2),
      node_metadata: %{
        node_id: "node-#{suffix}",
        display_name: "settings-node-#{suffix}",
        hostname: "settings-#{suffix}.local",
        listen_host: "127.0.0.1",
        listen_port: 50_071,
        agent_version: "0.1.0",
        worker_backend: "mlx"
      },
      runtime_health: %{
        ready: label != :refreshed,
        health_code: if(label == :refreshed, do: "warning", else: nil),
        health_message: if(label == :refreshed, do: "warning", else: nil),
        affected_model: nil
      }
    }
  end

  defp runtime_loaded_models(:refreshed) do
    [
      %{model_id: "model-a", version: "v1"},
      %{model_id: "model-b", version: "v1"}
    ]
  end

  defp runtime_loaded_models(_label), do: [%{model_id: "model-a", version: "v1"}]

  defp stub_models(data) do
    :persistent_term.put({__MODULE__, :models}, data)
  end

  defp stub_runtime(mode) do
    :persistent_term.put({__MODULE__, :runtime_mode}, mode)
    :persistent_term.put({__MODULE__, :runtime_test_pid}, self())
  end

  defp runtime_count do
    :persistent_term.get({__MODULE__, :runtime_count}, 0)
  end

  defp render_until(view, expected, attempts \\ 50) do
    case do_render_until(view, expected, attempts) do
      {:ok, html} -> html
      :timeout -> flunk("timed out waiting for #{inspect(expected)}")
    end
  end

  defp do_render_until(view, expected, attempts) do
    Enum.reduce_while(1..attempts, :timeout, fn _attempt, _last_result ->
      html = render(view)

      if html =~ expected do
        {:halt, {:ok, html}}
      else
        Process.sleep(20)
        {:cont, :timeout}
      end
    end)
  end

  defp put_console_config(overrides) do
    current = Application.get_env(:orchard_controller, :console, [])
    Application.put_env(:orchard_controller, :console, Keyword.merge(current, overrides))
  end
end
