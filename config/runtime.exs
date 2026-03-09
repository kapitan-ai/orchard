import Config

if config_env() == :prod do
  case System.get_env("RELEASE_NAME") || System.get_env("MIX_RELEASE_NAME") do
    "orchard_controller" ->
      database_url =
        System.get_env("DATABASE_URL") ||
          raise "environment variable DATABASE_URL is missing for Orchard controller releases"

      secret_key_base =
        System.get_env("SECRET_KEY_BASE") ||
          raise "environment variable SECRET_KEY_BASE is missing for Orchard controller releases"

      host = System.get_env("PHX_HOST") || "localhost"
      port = String.to_integer(System.get_env("PORT") || "4000")

      config :orchard_controller, Orchard.Repo,
        url: database_url,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
        socket_options: if(System.get_env("ECTO_IPV6") in ["true", "1"], do: [:inet6], else: [])

      config :orchard_controller, Orchard.API.Endpoint,
        server: true,
        http: [ip: {0, 0, 0, 0}, port: port],
        url: [host: host, port: 443, scheme: "https"],
        secret_key_base: secret_key_base

    _other_release ->
      :ok
  end
end
