import Config

config :illume, Illume.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  live_view: [signing_salt: "fevUVS6uXAT6q/QW0CNYb4IftXgEK5zG"],
  pubsub_server: Illume.PubSub,
  server: false
