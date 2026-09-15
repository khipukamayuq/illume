import Config

config :illume, Illume.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  # secret_key_base is set in config/runtime.exs — random per boot, not
  # committed (see DECISIONS.md entry 73/74).
  live_view: [signing_salt: "fevUVS6uXAT6q/QW0CNYb4IftXgEK5zG"],
  pubsub_server: Illume.PubSub,
  server: false
